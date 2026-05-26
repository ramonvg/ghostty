#if os(macOS)
import AppKit
import Combine

private struct GitBranchCacheEntry {
    let branch: String
    let createdAt: Date
}

private struct PersistedWorkspaceSession: Codable {
    let version: Int
    let savedAt: Date
    let groups: [PersistedWorkspaceGroup]
}

private struct PersistedWorkspaceGroup: Codable {
    let id: UUID
    let workspaces: [PersistedWorkspace]
    let activeWorkspaceID: UUID
}

private struct PersistedWorkspace: Codable {
    let id: UUID
    let name: String?
    let tabs: [PersistedWorkspaceTab]
    let activeTabWindowID: UUID?
}

private struct PersistedWorkspaceTab: Codable {
    let id: UUID
    let workingDirectory: String?
    let terminalState: TerminalRestorableState.InternalState<Ghostty.SurfaceView>?
}

enum WorkspaceAgentStatus: Equatable {
    case working(Character)
    case attention
    case none
}

@MainActor
final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()

    @Published private(set) var groups: [UUID: WorkspaceGroup] = [:]
    @Published private(set) var renameRequest: WorkspaceRenameRequest?
    @Published private(set) var metadataRevision: Int = 0

    private var controllersByTabWindowID: [UUID: Weak<TerminalController>] = [:]
    private var controllerCancellables: [UUID: Set<AnyCancellable>] = [:]
    private var surfacePwdCancellables: [UUID: Set<AnyCancellable>] = [:]
    private var controllerHadWorkingAgent: Set<UUID> = []
    private var controllerNeedsAgentAttention: Set<UUID> = []
    private var suppressedRestoredAgentTitles: [UUID: Set<String>] = [:]
    private var gitBranchCache: [String: GitBranchCacheEntry] = [:]
    private var gitBranchLookupsInFlight: Set<String> = []
    private var agentBridgeCancellable: AnyCancellable?
    private var frameSyncInProgress = false

    private static let loadingSpinnerFrames: Set<Character> = [
        "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
    ]

    private let gitBranchCacheLifetime: TimeInterval = 5

    private static let persistedSessionDefaultsKey = "WorkspacePersistedSession"

    private init() {
        agentBridgeCancellable = AgentBridgeStore.shared.$statesBySessionID
            .sink { [weak self] _ in
                self?.refreshWorkspaceMetadata()
            }
    }

    @discardableResult
    func ensureWorkspace(_ workspaceID: UUID?, in groupID: UUID) -> UUID {
        if var group = groups[groupID] {
            if let workspaceID {
                if !group.workspaces.contains(where: { $0.id == workspaceID }) {
                    group.workspaces.append(Workspace(id: workspaceID))
                    groups[groupID] = group
                }

                return workspaceID
            }

            return group.activeWorkspaceID
        }

        let resolvedWorkspaceID = workspaceID ?? UUID()
        groups[groupID] = WorkspaceGroup(
            id: groupID,
            workspaces: [Workspace(id: resolvedWorkspaceID)],
            activeWorkspaceID: resolvedWorkspaceID)
        return resolvedWorkspaceID
    }

    func register(_ controller: TerminalController) {
        let groupID = controller.workspaceGroupID
        let workspaceID = ensureWorkspace(controller.workspaceID, in: groupID)
        controller.workspaceID = workspaceID
        controllersByTabWindowID[controller.workspaceTabID] = Weak(controller)
        setupControllerSubscriptions(for: controller)

        guard var group = groups[groupID],
              let workspaceIndex = group.workspaces.firstIndex(where: { $0.id == workspaceID })
        else { return }

        if !group.workspaces[workspaceIndex].tabWindowIDs.contains(controller.workspaceTabID) {
            group.workspaces[workspaceIndex].tabWindowIDs.append(controller.workspaceTabID)
        }

        if group.workspaces[workspaceIndex].activeTabWindowID == nil {
            group.workspaces[workspaceIndex].activeTabWindowID = controller.workspaceTabID
        }

        groups[groupID] = group
    }

    func unregister(_ controller: TerminalController) {
        controllersByTabWindowID[controller.workspaceTabID] = nil
        controllerCancellables[controller.workspaceTabID] = nil
        surfacePwdCancellables[controller.workspaceTabID] = nil
        controllerHadWorkingAgent.remove(controller.workspaceTabID)
        controllerNeedsAgentAttention.remove(controller.workspaceTabID)
        suppressedRestoredAgentTitles[controller.workspaceTabID] = nil

        guard var group = groups[controller.workspaceGroupID] else { return }
        for workspaceIndex in group.workspaces.indices {
            group.workspaces[workspaceIndex].tabWindowIDs.removeAll { $0 == controller.workspaceTabID }
            if group.workspaces[workspaceIndex].activeTabWindowID == controller.workspaceTabID {
                group.workspaces[workspaceIndex].activeTabWindowID = group.workspaces[workspaceIndex].tabWindowIDs.first
            }
        }

        group.workspaces.removeAll { $0.tabWindowIDs.isEmpty }

        if group.workspaces.isEmpty {
            groups[controller.workspaceGroupID] = nil
            return
        }

        if !group.workspaces.contains(where: { $0.id == group.activeWorkspaceID }) {
            group.activeWorkspaceID = group.workspaces[0].id
        }

        groups[controller.workspaceGroupID] = group
    }

    @discardableResult
    func createWorkspace(in groupID: UUID, named name: String? = nil) -> UUID {
        ensureWorkspace(nil, in: groupID)
        guard var group = groups[groupID] else { return UUID() }

        let workspaceID = UUID()
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        group.workspaces.append(Workspace(
            id: workspaceID,
            name: trimmedName?.isEmpty == false ? trimmedName : nil))
        groups[groupID] = group
        return workspaceID
    }

    func requestRenameWorkspace(_ workspaceID: UUID, in groupID: UUID) {
        renameRequest = WorkspaceRenameRequest(
            groupID: groupID,
            workspaceID: workspaceID,
            token: UUID())
    }

    func renameWorkspace(_ workspaceID: UUID, in groupID: UUID, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        guard var group = groups[groupID] else { return }
        guard let workspaceIndex = group.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }

        group.workspaces[workspaceIndex].name = trimmedName
        groups[groupID] = group
    }

    func moveWorkspace(_ workspaceID: UUID, in groupID: UUID, to destinationIndex: Int) {
        guard var group = groups[groupID] else { return }
        guard let sourceIndex = group.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        guard group.workspaces.indices.contains(destinationIndex) else { return }
        guard sourceIndex != destinationIndex else { return }

        let workspace = group.workspaces.remove(at: sourceIndex)
        let insertionIndex = min(destinationIndex, group.workspaces.count)
        group.workspaces.insert(workspace, at: insertionIndex)
        groups[groupID] = group
    }

    func deleteEmptyWorkspace(_ workspaceID: UUID, in groupID: UUID) {
        guard var group = groups[groupID] else { return }
        guard let workspaceIndex = group.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        guard group.workspaces[workspaceIndex].tabWindowIDs.isEmpty else { return }

        group.workspaces.remove(at: workspaceIndex)
        if group.workspaces.isEmpty {
            groups[groupID] = nil
            return
        }

        if group.activeWorkspaceID == workspaceID {
            group.activeWorkspaceID = group.workspaces[0].id
        }

        groups[groupID] = group
    }

    func workspaces(in groupID: UUID) -> [Workspace] {
        groups[groupID]?.workspaces ?? []
    }

    func activeWorkspaceID(in groupID: UUID) -> UUID? {
        groups[groupID]?.activeWorkspaceID
    }

    func workspaceDisplayName(in groupID: UUID, workspaceID: UUID) -> String {
        guard let group = groups[groupID],
              let workspaceIndex = group.workspaces.firstIndex(where: { $0.id == workspaceID })
        else { return defaultWorkspaceName(at: 0) }

        if let name = group.workspaces[workspaceIndex].name, !name.isEmpty {
            return name
        }

        if let projectName = workspaceProjectName(in: groupID, workspaceID: workspaceID) {
            return projectName
        }

        return defaultWorkspaceName(at: workspaceIndex)
    }

    func workspaceSubtitle(in groupID: UUID, workspaceID: UUID) -> String? {
        guard let pwd = sharedPWD(in: groupID, workspaceID: workspaceID) else { return nil }
        guard let branch = workspaceGitBranch(for: pwd) else { return nil }
        return branch
    }

    func acknowledgeAgentAttention(for controller: TerminalController, focusedSurface: Ghostty.SurfaceView?) {
        controllerHadWorkingAgent.remove(controller.workspaceTabID)
        controllerNeedsAgentAttention.remove(controller.workspaceTabID)
        suppressAgentTitles(for: controller)

        if let surfaceID = focusedSurface?.id.uuidString {
            AgentBridgeStore.shared.acknowledgeAttention(forSurfaceID: surfaceID)
        }

        metadataRevision += 1
    }

    func workspaceAgentStatus(in groupID: UUID, workspaceID: UUID) -> WorkspaceAgentStatus {
        var foundAttention = false
        let workspaceControllers = controllers(in: groupID, workspaceID: workspaceID)

        switch workspaceStatus(from: agentBridgeStatus(for: workspaceControllers)) {
        case .working(let spinner):
            return .working(spinner)
        case .attention:
            foundAttention = true
        case .none:
            break
        }

        for controller in workspaceControllers {
            if controllerNeedsAgentAttention.contains(controller.workspaceTabID) {
                foundAttention = true
            }

            if let windowTitle = controller.window?.title,
               !shouldSuppressRestoredAgentTitle(windowTitle, for: controller) {
                switch Self.agentStatus(in: windowTitle) {
                case .working(let spinner):
                    return .working(spinner)
                case .attention:
                    foundAttention = true
                case .none:
                    break
                }
            }

            for surface in controller.surfaceTree {
                guard !shouldSuppressRestoredAgentTitle(surface.title, for: controller) else { continue }

                switch Self.agentStatus(in: surface.title) {
                case .working(let spinner):
                    return .working(spinner)
                case .attention:
                    foundAttention = true
                case .none:
                    break
                }
            }
        }

        return foundAttention ? .attention : .none
    }

    private func suppressRestoredAgentTitles(for controller: TerminalController) {
        suppressAgentTitles(for: controller)
    }

    private func suppressAgentTitles(for controller: TerminalController) {
        let candidateTitles = [controller.window?.title, controller.titleOverride].compactMap { $0 } + controller.surfaceTree.map(\.title)
        let agentTitles = Set(candidateTitles.filter { title in
            switch Self.agentStatus(in: title) {
            case .working, .attention:
                return true
            case .none:
                return false
            }
        })

        controllerHadWorkingAgent.remove(controller.workspaceTabID)
        controllerNeedsAgentAttention.remove(controller.workspaceTabID)
        guard !agentTitles.isEmpty else { return }
        var suppressedTitles = suppressedRestoredAgentTitles[controller.workspaceTabID] ?? []
        suppressedTitles.formUnion(agentTitles)
        suppressedRestoredAgentTitles[controller.workspaceTabID] = suppressedTitles
    }

    private func shouldSuppressRestoredAgentTitle(_ title: String, for controller: TerminalController) -> Bool {
        suppressedRestoredAgentTitles[controller.workspaceTabID]?.contains(title) == true
    }

    private static func agentStatus(in title: String) -> WorkspaceAgentStatus {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.contains("π") else { return .none }

        if let firstCharacter = trimmedTitle.first, loadingSpinnerFrames.contains(firstCharacter) {
            return .working(firstCharacter)
        }

        let bellPrefix = "🔔"
        if trimmedTitle.hasPrefix(bellPrefix) {
            let titleWithoutBell = trimmedTitle
                .dropFirst(bellPrefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let firstCharacter = titleWithoutBell.first, loadingSpinnerFrames.contains(firstCharacter) {
                return .working(firstCharacter)
            }
        }

        if let spinner = trimmedTitle.first(where: { loadingSpinnerFrames.contains($0) }) {
            return .working(spinner)
        }

        if trimmedTitle.hasPrefix(bellPrefix) || trimmedTitle.contains("💤") {
            return .attention
        }

        return .none
    }

    private func agentBridgeStatus(for controller: TerminalController) -> AgentBridgeWorkspaceStatus {
        AgentBridgeStore.shared.workspaceStatus(forSurfaceIDs: controller.surfaceTree.map { $0.id.uuidString })
    }

    private func agentBridgeStatus(for controllers: [TerminalController]) -> AgentBridgeWorkspaceStatus {
        AgentBridgeStore.shared.workspaceStatus(forSurfaceIDs: controllers.flatMap { controller in
            controller.surfaceTree.map { $0.id.uuidString }
        })
    }

    private func workspaceStatus(from bridgeStatus: AgentBridgeWorkspaceStatus) -> WorkspaceAgentStatus {
        switch bridgeStatus {
        case .working(let spinner):
            return .working(spinner)
        case .attention:
            return .attention
        case .none:
            return .none
        }
    }

    func controllers(in groupID: UUID) -> [TerminalController] {
        guard let group = groups[groupID] else { return [] }
        return group.workspaces.flatMap { workspace in
            workspace.tabWindowIDs.compactMap { controllersByTabWindowID[$0]?.value }
        }
    }

    func controllers(in groupID: UUID, workspaceID: UUID) -> [TerminalController] {
        guard let workspace = groups[groupID]?.workspaces.first(where: { $0.id == workspaceID }) else {
            return []
        }

        return workspace.tabWindowIDs.compactMap { controllersByTabWindowID[$0]?.value }
    }

    func isControllerVisibleInActiveWorkspace(_ controller: TerminalController) -> Bool {
        guard let activeWorkspaceID = activeWorkspaceID(in: controller.workspaceGroupID) else { return true }
        return controller.workspaceID == activeWorkspaceID && (controller.window?.isVisible ?? false)
    }

    func shouldCloseAsWorkspaceTab(_ controller: TerminalController) -> Bool {
        controllers(in: controller.workspaceGroupID).contains { $0 !== controller }
    }

    func replacementWorkspaceID(afterClosing controller: TerminalController) -> UUID? {
        guard let group = groups[controller.workspaceGroupID] else { return nil }

        if let workspace = group.workspaces.first(where: { $0.id == controller.workspaceID }) {
            let remainingTabsInWorkspace = workspace.tabWindowIDs.filter { $0 != controller.workspaceTabID }
            if !remainingTabsInWorkspace.isEmpty {
                return workspace.id
            }
        }

        return group.workspaces.first { workspace in
            workspace.id != controller.workspaceID && !workspace.tabWindowIDs.isEmpty
        }?.id
    }

    func recordActiveTab(_ controller: TerminalController) {
        guard var group = groups[controller.workspaceGroupID],
              let workspaceIndex = group.workspaces.firstIndex(where: { $0.id == controller.workspaceID })
        else { return }

        group.activeWorkspaceID = controller.workspaceID
        group.workspaces[workspaceIndex].activeTabWindowID = controller.workspaceTabID
        groups[controller.workspaceGroupID] = group
    }

    func moveController(_ controller: TerminalController, to targetWorkspaceID: UUID) {
        let groupID = controller.workspaceGroupID
        let sourceWorkspaceID = controller.workspaceID
        guard sourceWorkspaceID != targetWorkspaceID else { return }
        guard var group = groups[groupID] else { return }
        guard let sourceWorkspaceIndex = group.workspaces.firstIndex(where: { $0.id == sourceWorkspaceID }),
              let targetWorkspaceIndex = group.workspaces.firstIndex(where: { $0.id == targetWorkspaceID }),
              let sourceTabIndex = group.workspaces[sourceWorkspaceIndex].tabWindowIDs.firstIndex(of: controller.workspaceTabID)
        else { return }

        let sourceWasActive = group.activeWorkspaceID == sourceWorkspaceID
        let replacementTabWindowID = replacementTabWindowID(
            afterRemovingTabAt: sourceTabIndex,
            from: group.workspaces[sourceWorkspaceIndex].tabWindowIDs)
        let replacementController = replacementTabWindowID.flatMap { controllersByTabWindowID[$0]?.value }

        group.workspaces[sourceWorkspaceIndex].tabWindowIDs.remove(at: sourceTabIndex)
        if group.workspaces[sourceWorkspaceIndex].activeTabWindowID == controller.workspaceTabID {
            group.workspaces[sourceWorkspaceIndex].activeTabWindowID = replacementTabWindowID
        }

        group.workspaces[targetWorkspaceIndex].tabWindowIDs.append(controller.workspaceTabID)
        group.workspaces[targetWorkspaceIndex].activeTabWindowID = controller.workspaceTabID
        controller.workspaceID = targetWorkspaceID

        if group.workspaces[sourceWorkspaceIndex].tabWindowIDs.isEmpty {
            group.workspaces.remove(at: sourceWorkspaceIndex)
            if group.activeWorkspaceID == sourceWorkspaceID {
                group.activeWorkspaceID = targetWorkspaceID
            }
        }

        groups[groupID] = group

        guard sourceWasActive else {
            if group.activeWorkspaceID == targetWorkspaceID {
                activateWorkspace(targetWorkspaceID, in: groupID, from: controller)
            }
            return
        }

        if let replacementController, let replacementWindow = replacementController.window {
            if let movedWindow = controller.window {
                if let tabGroup = movedWindow.tabGroup, tabGroup.windows.count > 1 {
                    tabGroup.removeWindow(movedWindow)
                }
                movedWindow.orderOut(nil)
            }

            replacementWindow.makeKeyAndOrderFront(nil)
            replacementController.relabelTabs()
            return
        }

        activateWorkspace(targetWorkspaceID, in: groupID, from: controller)
    }

    private func replacementTabWindowID(afterRemovingTabAt removedIndex: Int, from tabWindowIDs: [UUID]) -> UUID? {
        if tabWindowIDs.indices.contains(removedIndex + 1) {
            return tabWindowIDs[removedIndex + 1]
        }

        if tabWindowIDs.indices.contains(removedIndex - 1) {
            return tabWindowIDs[removedIndex - 1]
        }

        return nil
    }

    private func setupControllerSubscriptions(for controller: TerminalController) {
        var cancellables: Set<AnyCancellable> = []
        controller.$surfaceTree
            .sink { [weak self, weak controller] _ in
                DispatchQueue.main.async {
                    guard let self, let controller else { return }
                    self.setupSurfaceMetadataSubscriptions(for: controller)
                    self.refreshWorkspaceMetadata()
                }
            }
            .store(in: &cancellables)

        controller.window?.publisher(for: \.title)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.refreshWorkspaceMetadata()
                }
            }
            .store(in: &cancellables)

        controller.$bell
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.refreshWorkspaceMetadata()
                }
            }
            .store(in: &cancellables)

        controllerCancellables[controller.workspaceTabID] = cancellables
        setupSurfaceMetadataSubscriptions(for: controller)
    }

    private func setupSurfaceMetadataSubscriptions(for controller: TerminalController) {
        var cancellables: Set<AnyCancellable> = []
        for surface in controller.surfaceTree {
            surface.$pwd
                .sink { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.refreshWorkspaceMetadata()
                    }
                }
                .store(in: &cancellables)

            surface.$title
                .sink { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.refreshWorkspaceMetadata()
                    }
                }
                .store(in: &cancellables)

            surface.$bell
                .sink { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.refreshWorkspaceMetadata()
                    }
                }
                .store(in: &cancellables)
        }
        surfacePwdCancellables[controller.workspaceTabID] = cancellables
    }

    private func refreshWorkspaceMetadata() {
        updateControllerAgentStates()
        metadataRevision += 1
    }

    private func updateControllerAgentStates() {
        for (tabWindowID, weakController) in controllersByTabWindowID {
            guard let controller = weakController.value else {
                controllerHadWorkingAgent.remove(tabWindowID)
                controllerNeedsAgentAttention.remove(tabWindowID)
                continue
            }

            switch agentBridgeStatus(for: controller) {
            case .working:
                controllerHadWorkingAgent.insert(tabWindowID)
                controllerNeedsAgentAttention.remove(tabWindowID)
                continue

            case .attention:
                controllerHadWorkingAgent.remove(tabWindowID)
                if isControllerFocusedForAgentAttention(controller) {
                    if let surfaceID = controller.focusedSurface?.id.uuidString {
                        AgentBridgeStore.shared.acknowledgeAttention(forSurfaceID: surfaceID)
                    }
                    suppressAgentTitles(for: controller)
                } else {
                    controllerNeedsAgentAttention.insert(tabWindowID)
                }
                continue

            case .none:
                break
            }

            let snapshot = agentSnapshot(for: controller)
            if snapshot.hasWorking {
                controllerHadWorkingAgent.insert(tabWindowID)
                controllerNeedsAgentAttention.remove(tabWindowID)
            } else if snapshot.hasAttention || (controllerHadWorkingAgent.contains(tabWindowID) && snapshot.hasPiTitle) {
                controllerHadWorkingAgent.remove(tabWindowID)
                if isControllerFocusedForAgentAttention(controller) {
                    suppressAgentTitles(for: controller)
                } else {
                    controllerNeedsAgentAttention.insert(tabWindowID)
                }
            } else if !snapshot.hasPiTitle {
                controllerHadWorkingAgent.remove(tabWindowID)
                controllerNeedsAgentAttention.remove(tabWindowID)
            }
        }
    }

    private func isControllerFocusedForAgentAttention(_ controller: TerminalController) -> Bool {
        guard let window = controller.window else { return false }
        guard isControllerVisibleInActiveWorkspace(controller) else { return false }

        if window.isKeyWindow || window.isMainWindow {
            return true
        }

        guard let selectedWindow = window.tabGroup?.selectedWindow else { return false }
        return selectedWindow == window && (NSApp.keyWindow == window || NSApp.mainWindow == window)
    }

    private func agentSnapshot(for controller: TerminalController) -> (
        hasWorking: Bool,
        hasAttention: Bool,
        hasPiTitle: Bool
    ) {
        var hasWorking = false
        var hasAttention = false
        var hasPiTitle = false

        func record(title: String) {
            guard !shouldSuppressRestoredAgentTitle(title, for: controller) else { return }

            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedTitle.contains("π") else { return }
            hasPiTitle = true

            switch Self.agentStatus(in: trimmedTitle) {
            case .working:
                hasWorking = true
            case .attention:
                hasAttention = true
            case .none:
                break
            }
        }

        if let windowTitle = controller.window?.title {
            record(title: windowTitle)
        }

        for surface in controller.surfaceTree {
            record(title: surface.title)
        }

        if hasPiTitle && controller.bell {
            hasAttention = true
        }

        if hasPiTitle && controller.surfaceTree.contains(where: { $0.bell }) {
            hasAttention = true
        }

        return (hasWorking, hasAttention, hasPiTitle)
    }

    private func workspaceProjectName(in groupID: UUID, workspaceID: UUID) -> String? {
        guard let pwd = sharedPWD(in: groupID, workspaceID: workspaceID) else { return nil }
        let folderName = URL(fileURLWithPath: pwd).lastPathComponent
        return folderName.isEmpty ? pwd : folderName
    }

    private func workspaceGitBranch(for pwd: String) -> String? {
        scheduleGitBranchLookupIfNeeded(for: pwd)
        guard let branch = gitBranchCache[pwd]?.branch, !branch.isEmpty else { return nil }
        return branch
    }

    private func sharedPWD(in groupID: UUID, workspaceID: UUID) -> String? {
        let surfaces = controllers(in: groupID, workspaceID: workspaceID).flatMap { controller in
            Array(controller.surfaceTree)
        }
        guard !surfaces.isEmpty else { return nil }

        let pwdValues = surfaces.compactMap { surface -> String? in
            guard let pwd = surface.pwd, !pwd.isEmpty else { return nil }
            return URL(fileURLWithPath: pwd).standardizedFileURL.path
        }
        guard pwdValues.count == surfaces.count else { return nil }
        guard let firstPWD = pwdValues.first else { return nil }
        guard pwdValues.allSatisfy({ $0 == firstPWD }) else { return nil }
        return firstPWD
    }

    private func scheduleGitBranchLookupIfNeeded(for pwd: String) {
        if let entry = gitBranchCache[pwd],
           Date().timeIntervalSince(entry.createdAt) < gitBranchCacheLifetime {
            return
        }
        guard !gitBranchLookupsInFlight.contains(pwd) else { return }

        gitBranchLookupsInFlight.insert(pwd)
        Task.detached(priority: .utility) {
            let branch = Self.gitBranch(at: pwd) ?? ""
            await WorkspaceStore.shared.finishGitBranchLookup(pwd: pwd, branch: branch)
        }
    }

    private func finishGitBranchLookup(pwd: String, branch: String) {
        gitBranchCache[pwd] = GitBranchCacheEntry(branch: branch, createdAt: Date())
        gitBranchLookupsInFlight.remove(pwd)
        refreshWorkspaceMetadata()
    }

    nonisolated private static func gitBranch(at pwd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", pwd, "branch", "--show-current"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let branch = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let branch, !branch.isEmpty else { return nil }
        return branch
    }

    func syncWindowFrame(from source: TerminalController) {
        guard !frameSyncInProgress else { return }
        guard let sourceWindow = source.window, sourceWindow.isVisible else { return }

        frameSyncInProgress = true
        defer { frameSyncInProgress = false }

        let frame = sourceWindow.frame
        for controller in controllers(in: source.workspaceGroupID) where controller !== source {
            guard let window = controller.window else { continue }
            guard window.frame != frame else { continue }
            window.setFrame(frame, display: false)
        }
    }

    func syncTabOrder(from windows: [NSWindow]) {
        let controllers = windows.compactMap { $0.windowController as? TerminalController }
        guard let firstController = controllers.first else { return }

        let groupID = firstController.workspaceGroupID
        let workspaceID = firstController.workspaceID
        guard controllers.allSatisfy({ controller in
            controller.workspaceGroupID == groupID && controller.workspaceID == workspaceID
        }) else { return }

        let orderedTabWindowIDs = controllers.map { $0.workspaceTabID }
        guard !orderedTabWindowIDs.isEmpty else { return }
        guard var group = groups[groupID],
              let workspaceIndex = group.workspaces.firstIndex(where: { $0.id == workspaceID })
        else { return }

        let orderedSet = Set(orderedTabWindowIDs)
        let remainingTabWindowIDs = group.workspaces[workspaceIndex].tabWindowIDs.filter {
            !orderedSet.contains($0)
        }
        let newTabWindowIDs = orderedTabWindowIDs + remainingTabWindowIDs
        guard group.workspaces[workspaceIndex].tabWindowIDs != newTabWindowIDs else { return }

        group.workspaces[workspaceIndex].tabWindowIDs = newTabWindowIDs
        groups[groupID] = group
    }

    func restoreSessionIfAvailable(ghostty: Ghostty.App) -> Bool {
        guard TerminalController.all.isEmpty else { return false }
        guard let session = loadPersistedSession() else { return false }
        guard let persistedGroup = session.groups.first else { return false }
        guard persistedGroup.workspaces.flatMap(\.tabs).first != nil else {
            groups[persistedGroup.id] = WorkspaceGroup(
                id: persistedGroup.id,
                workspaces: persistedGroup.workspaces.enumerated().map { index, workspace in
                    Workspace(id: workspace.id, name: normalizedPersistedWorkspaceName(workspace.name, at: index))
                },
                activeWorkspaceID: persistedGroup.activeWorkspaceID)
            return true
        }

        var firstController: TerminalController?
        for persistedWorkspace in persistedGroup.workspaces {
            for persistedTab in persistedWorkspace.tabs {
                let restoredController: TerminalController
                if let terminalState = persistedTab.terminalState {
                    restoredController = TerminalController.restoreWorkspaceTab(
                        ghostty,
                        from: firstController?.window,
                        withTerminalState: terminalState,
                        workspaceGroupID: persistedGroup.id,
                        workspaceID: persistedWorkspace.id,
                        workspaceTabID: persistedTab.id)
                    suppressRestoredAgentTitles(for: restoredController)
                } else {
                    var config = Ghostty.SurfaceConfiguration()
                    if let workingDirectory = usableWorkingDirectory(persistedTab.workingDirectory) {
                        config.workingDirectory = workingDirectory
                    }

                    if firstController == nil {
                        restoredController = TerminalController.newWindow(
                            ghostty,
                            withBaseConfig: config,
                            workspaceGroupID: persistedGroup.id,
                            workspaceID: persistedWorkspace.id,
                            workspaceTabID: persistedTab.id)
                    } else {
                        restoredController = TerminalController.newTab(
                            ghostty,
                            from: firstController?.window,
                            withBaseConfig: config,
                            workspaceID: persistedWorkspace.id,
                            workspaceTabID: persistedTab.id) ?? firstController!
                    }
                }

                if firstController == nil {
                    firstController = restoredController
                }
            }
        }

        DispatchQueue.main.async {
            self.applyPersistedMetadata(persistedGroup)
            if let firstController {
                self.activateWorkspace(persistedGroup.activeWorkspaceID, in: persistedGroup.id, from: firstController)
            }
        }
        return true
    }

    func saveCurrentSession() {
        guard !groups.isEmpty || !TerminalController.all.isEmpty else { return }

        let persistedGroups = groups.values
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { group in
                PersistedWorkspaceGroup(
                    id: group.id,
                    workspaces: group.workspaces.map { workspace in
                        PersistedWorkspace(
                            id: workspace.id,
                            name: workspace.name,
                            tabs: workspace.tabWindowIDs.map { tabWindowID in
                                PersistedWorkspaceTab(
                                    id: tabWindowID,
                                    workingDirectory: controllersByTabWindowID[tabWindowID]?.value.flatMap { controller in
                                        currentWorkingDirectory(for: controller)
                                    },
                                    terminalState: controllersByTabWindowID[tabWindowID]?.value.map { controller in
                                        TerminalRestorableState.InternalState(from: controller)
                                    })
                            },
                            activeTabWindowID: workspace.activeTabWindowID)
                    },
                    activeWorkspaceID: group.activeWorkspaceID)
            }
        let session = PersistedWorkspaceSession(version: 2, savedAt: Date(), groups: persistedGroups)
        guard let data = try? JSONEncoder().encode(session) else { return }
        UserDefaults.ghostty.set(data, forKey: Self.persistedSessionDefaultsKey)
    }

    private func loadPersistedSession() -> PersistedWorkspaceSession? {
        guard let data = UserDefaults.ghostty.data(forKey: Self.persistedSessionDefaultsKey) else { return nil }
        guard let session = try? JSONDecoder().decode(PersistedWorkspaceSession.self, from: data) else { return nil }
        guard session.version == 1 || session.version == 2 else { return nil }
        return session
    }

    private func applyPersistedMetadata(_ persistedGroup: PersistedWorkspaceGroup) {
        let restoredWorkspaces = persistedGroup.workspaces.enumerated().map { index, persistedWorkspace in
            Workspace(
                id: persistedWorkspace.id,
                name: normalizedPersistedWorkspaceName(persistedWorkspace.name, at: index),
                tabWindowIDs: persistedWorkspace.tabs.map(\.id),
                activeTabWindowID: persistedWorkspace.activeTabWindowID)
        }
        groups[persistedGroup.id] = WorkspaceGroup(
            id: persistedGroup.id,
            workspaces: restoredWorkspaces,
            activeWorkspaceID: persistedGroup.activeWorkspaceID)
    }

    private func normalizedPersistedWorkspaceName(_ name: String?, at index: Int) -> String? {
        guard let name else { return nil }
        if name == "Default" || name == defaultWorkspaceName(at: index) { return nil }
        return name
    }

    private func currentWorkingDirectory(for controller: TerminalController) -> String? {
        if let pwd = controller.focusedSurface?.pwd, !pwd.isEmpty {
            return pwd
        }

        return controller.surfaceTree.first { surface in
            guard let pwd = surface.pwd else { return false }
            return !pwd.isEmpty
        }?.pwd
    }

    private func usableWorkingDirectory(_ workingDirectory: String?) -> String? {
        guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else { return nil }
        return workingDirectory
    }

    func activateWorkspace(_ workspaceID: UUID, in groupID: UUID, from source: TerminalController?) {
        guard var group = groups[groupID] else { return }
        guard group.workspaces.contains(where: { $0.id == workspaceID }) else { return }

        let previousWorkspaceID = group.activeWorkspaceID
        let sourceWindow = selectedController(in: groupID, fallback: source)?.window ?? source?.window
        if let selectedController = selectedController(in: groupID, fallback: source),
           selectedController.workspaceID == previousWorkspaceID,
           let previousWorkspaceIndex = group.workspaces.firstIndex(where: { $0.id == previousWorkspaceID }) {
            group.workspaces[previousWorkspaceIndex].activeTabWindowID = selectedController.workspaceTabID
        }
        groups[groupID] = group

        let targetControllers = controllers(in: groupID, workspaceID: workspaceID)
        guard !targetControllers.isEmpty else { return }

        let targetWindows = targetControllers.compactMap { $0.window }
        guard let anchorWindow = targetWindows.first else { return }

        let targetWindowIDs = Set(targetControllers.map { $0.workspaceTabID })
        let activeTabWindowID = groups[groupID]?.workspaces
            .first(where: { $0.id == workspaceID })?
            .activeTabWindowID
        let activeController = activeTabWindowID.flatMap { tabWindowID in
            targetControllers.first { $0.workspaceTabID == tabWindowID }
        } ?? targetControllers[0]
        let activeWindow = activeController.window ?? anchorWindow

        let previousWindows = controllers(in: groupID, workspaceID: previousWorkspaceID)
            .compactMap { $0.window }
            .filter { !targetWindows.contains($0) }

        let switchingWindows = uniqueWindows(previousWindows + targetWindows + [sourceWindow].compactMap { $0 })
        withoutWindowAnimations(switchingWindows) {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0

            if let sourceFrame = sourceWindow?.frame {
                for window in targetWindows where window.frame != sourceFrame {
                    window.setFrame(sourceFrame, display: false)
                }
            }

            for window in previousWindows {
                if let tabGroup = window.tabGroup, tabGroup.windows.count > 1 {
                    tabGroup.removeWindow(window)
                }
                window.orderOut(nil)
            }

            for window in targetWindows {
                guard let tabGroup = window.tabGroup else { continue }
                for groupedWindow in tabGroup.windows where groupedWindow !== window {
                    guard let groupedController = groupedWindow.windowController as? TerminalController else { continue }
                    guard groupedController.workspaceGroupID == groupID else { continue }
                    if !targetWindowIDs.contains(groupedController.workspaceTabID) {
                        tabGroup.removeWindow(groupedWindow)
                        groupedWindow.orderOut(nil)
                    }
                }
            }

            for window in targetWindows where window !== anchorWindow {
                if let tabGroup = window.tabGroup, tabGroup.windows.count > 1 {
                    tabGroup.removeWindow(window)
                }
            }

            if anchorWindow.isMiniaturized {
                anchorWindow.deminiaturize(nil)
            }
            anchorWindow.makeKeyAndOrderFront(nil)

            for window in targetWindows where window !== anchorWindow {
                anchorWindow.addTabbedWindowSafely(window, ordered: .above)
            }

            activeWindow.makeKeyAndOrderFront(nil)
            NSAnimationContext.endGrouping()
        }

        guard var updatedGroup = groups[groupID],
              let workspaceIndex = updatedGroup.workspaces.firstIndex(where: { $0.id == workspaceID })
        else { return }

        updatedGroup.activeWorkspaceID = workspaceID
        updatedGroup.workspaces[workspaceIndex].activeTabWindowID = activeController.workspaceTabID
        groups[groupID] = updatedGroup

        activeController.relabelTabs()
    }

    private func withoutWindowAnimations(_ windows: [NSWindow], _ body: () -> Void) {
        let originalAnimationBehaviors = windows.map { window in
            (window, window.animationBehavior)
        }

        for window in windows {
            window.animationBehavior = .none
        }

        body()

        for (window, animationBehavior) in originalAnimationBehaviors {
            window.animationBehavior = animationBehavior
        }
    }

    private func uniqueWindows(_ windows: [NSWindow]) -> [NSWindow] {
        var seen: Set<ObjectIdentifier> = []
        var result: [NSWindow] = []

        for window in windows {
            let id = ObjectIdentifier(window)
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            result.append(window)
        }

        return result
    }

    private func selectedController(in groupID: UUID, fallback: TerminalController?) -> TerminalController? {
        if let selectedWindow = fallback?.window?.tabGroup?.selectedWindow,
           let selectedController = selectedWindow.windowController as? TerminalController,
           selectedController.workspaceGroupID == groupID {
            return selectedController
        }

        if let keyWindow = NSApp.keyWindow,
           let keyController = keyWindow.windowController as? TerminalController,
           keyController.workspaceGroupID == groupID {
            return keyController
        }

        guard fallback?.workspaceGroupID == groupID else { return nil }
        return fallback
    }

    private func defaultWorkspaceName(at index: Int) -> String {
        return "Workspace \(index + 1)"
    }
}
#endif
