#if os(macOS)
import AppKit
import Combine

@MainActor
final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()

    @Published private(set) var groups: [UUID: WorkspaceGroup] = [:]
    @Published private(set) var renameRequest: WorkspaceRenameRequest?

    private var controllersByTabWindowID: [UUID: Weak<TerminalController>] = [:]
    private var frameSyncInProgress = false

    private init() {}

    @discardableResult
    func ensureWorkspace(_ workspaceID: UUID?, in groupID: UUID) -> UUID {
        if var group = groups[groupID] {
            if let workspaceID {
                if !group.workspaces.contains(where: { $0.id == workspaceID }) {
                    group.workspaces.append(Workspace(
                        id: workspaceID,
                        name: defaultWorkspaceName(at: group.workspaces.count)))
                    groups[groupID] = group
                }

                return workspaceID
            }

            return group.activeWorkspaceID
        }

        let resolvedWorkspaceID = workspaceID ?? UUID()
        groups[groupID] = WorkspaceGroup(
            id: groupID,
            workspaces: [Workspace(id: resolvedWorkspaceID, name: defaultWorkspaceName(at: 0))],
            activeWorkspaceID: resolvedWorkspaceID)
        return resolvedWorkspaceID
    }

    func register(_ controller: TerminalController) {
        let groupID = controller.workspaceGroupID
        let workspaceID = ensureWorkspace(controller.workspaceID, in: groupID)
        controller.workspaceID = workspaceID
        controllersByTabWindowID[controller.workspaceTabID] = Weak(controller)

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
        group.workspaces.append(Workspace(
            id: workspaceID,
            name: name ?? defaultWorkspaceName(at: group.workspaces.count)))
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
        let orderedTabWindowIDs = controllers
            .filter { $0.workspaceGroupID == groupID && $0.workspaceID == workspaceID }
            .map { $0.workspaceTabID }

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
        if index == 0 { return "Default" }
        return "Workspace \(index + 1)"
    }
}
#endif
