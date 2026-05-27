#if os(macOS)
import SwiftUI

private struct TodoItem: Identifiable {
    let id: String
    let title: String
    let tags: [String]
    let status: String
    let createdAt: String?
    let assignedToSession: String?
    let fileURL: URL

    var displayID: String {
        "TODO-\(id)"
    }

    var isOpen: Bool {
        let normalizedStatus = status.lowercased()
        return normalizedStatus != "closed" && normalizedStatus != "done"
    }

    var isAssigned: Bool {
        guard let assignedToSession else { return false }
        return !assignedToSession.isEmpty
    }
}

private struct TodoMetadata: Decodable {
    let id: String?
    let title: String?
    let tags: [String]?
    let status: String?
    let createdAt: String?
    let assignedToSession: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case tags
        case status
        case createdAt = "created_at"
        case assignedToSession = "assigned_to_session"
    }
}

private final class TodoSidebarModel: ObservableObject {
    @Published private(set) var cwdURL: URL?
    @Published private(set) var todos: [TodoItem] = []

    func reload(for cwdURL: URL?) {
        self.cwdURL = cwdURL

        guard let cwdURL else {
            todos = []
            return
        }

        let todoDirectoryURL = cwdURL.appendingPathComponent(".pi/todos", isDirectory: true)
        guard FileManager.default.fileExists(atPath: todoDirectoryURL.path) else {
            todos = []
            return
        }

        let todoFileURLs = (try? FileManager.default.contentsOfDirectory(
            at: todoDirectoryURL,
            includingPropertiesForKeys: nil)) ?? []

        todos = todoFileURLs
            .filter { $0.pathExtension == "md" }
            .compactMap(Self.todoItem)
            .sorted { leftTodo, rightTodo in
                switch (leftTodo.createdAt, rightTodo.createdAt) {
                case let (leftTodoCreatedAt?, rightTodoCreatedAt?) where leftTodoCreatedAt != rightTodoCreatedAt:
                    return leftTodoCreatedAt < rightTodoCreatedAt
                default:
                    return leftTodo.title.localizedCaseInsensitiveCompare(rightTodo.title) == .orderedAscending
                }
            }
    }

    func close(todo: TodoItem) {
        guard let data = try? Data(contentsOf: todo.fileURL),
              let jsonData = Self.leadingJSONObjectData(in: data),
              var metadata = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return
        }

        metadata["status"] = "closed"
        metadata.removeValue(forKey: "assigned_to_session")

        guard let updatedJSONData = try? JSONSerialization.data(
            withJSONObject: metadata,
            options: [.prettyPrinted, .sortedKeys]
        ),
            let updatedJSONString = String(data: updatedJSONData, encoding: .utf8),
            let fileContents = String(data: data, encoding: .utf8),
            let originalJSONString = String(data: jsonData, encoding: .utf8),
            let jsonRange = fileContents.range(of: originalJSONString) else {
            return
        }

        let updatedContents = fileContents.replacingCharacters(in: jsonRange, with: updatedJSONString)
        try? updatedContents.write(to: todo.fileURL, atomically: true, encoding: .utf8)
        reload(for: cwdURL)
    }

    private static func todoItem(from fileURL: URL) -> TodoItem? {
        guard let data = try? Data(contentsOf: fileURL),
              let jsonData = leadingJSONObjectData(in: data),
              let metadata = try? JSONDecoder().decode(TodoMetadata.self, from: jsonData) else {
            return nil
        }

        let fallbackID = fileURL.deletingPathExtension().lastPathComponent
        let id: String
        if let metadataID = metadata.id, !metadataID.isEmpty {
            id = metadataID
        } else {
            id = fallbackID
        }

        let title: String
        if let metadataTitle = metadata.title, !metadataTitle.isEmpty {
            title = metadataTitle
        } else {
            title = id
        }

        return TodoItem(
            id: id,
            title: title,
            tags: metadata.tags ?? [],
            status: metadata.status ?? "open",
            createdAt: metadata.createdAt,
            assignedToSession: metadata.assignedToSession,
            fileURL: fileURL)
    }

    private static func leadingJSONObjectData(in data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var depth = 0
        var isInsideString = false
        var isEscaped = false
        var objectStartIndex: String.Index?

        for index in text.indices {
            let character = text[index]

            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
                continue
            }

            if character == "\"" {
                isInsideString = true
            } else if character == "{" {
                if objectStartIndex == nil {
                    objectStartIndex = index
                }
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0, let objectStartIndex {
                    let endIndex = text.index(after: index)
                    return String(text[objectStartIndex..<endIndex]).data(using: .utf8)
                }
            }
        }

        return nil
    }
}

struct TodoSidebarView: View {
    @ObservedObject var ghostty: Ghostty.App

    let cwdURL: URL?
    let focusedSurface: Ghostty.SurfaceView?
    let toggleVisibility: () -> Void

    static let defaultWidth: CGFloat = 220
    private static let minWidth: CGFloat = 160
    private static let maxWidth: CGFloat = 420

    @AppStorage("TodoSidebarWidth") private var storedWidth: Double = 220
    @StateObject private var model = TodoSidebarModel()
    @ObservedObject private var agentBridgeStore = AgentBridgeStore.shared
    @State private var resizeStartWidth: CGFloat?
    @State private var workingSpinnerFrameIndex = 0

    private static let workingSpinnerFrames: [String] = [
        "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
    ]

    private let todoRefreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private let workingSpinnerTimer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    private var width: CGFloat {
        Self.clampedWidth(CGFloat(storedWidth))
    }

    private var assignedOpenTodos: [TodoItem] {
        model.todos.filter { $0.isOpen && $0.isAssigned }
    }

    private var unassignedOpenTodos: [TodoItem] {
        model.todos.filter { $0.isOpen && !$0.isAssigned }
    }

    private var visibleTodos: [TodoItem] {
        model.todos.filter(\.isOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Todos")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: toggleVisibility) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Hide Todos")
                .accessibilityLabel("Hide Todos")
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            if visibleTodos.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(assignedOpenTodos) { todo in
                            todoRow(todo)
                        }

                        ForEach(unassignedOpenTodos) { todo in
                            todoRow(todo)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(width: width)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(alignment: .leading) {
            resizeHandle
        }
        .onAppear { model.reload(for: cwdURL) }
        .onChange(of: cwdURL) { newValue in
            model.reload(for: newValue)
        }
        .onReceive(todoRefreshTimer) { _ in
            model.reload(for: cwdURL)
        }
        .onReceive(workingSpinnerTimer) { _ in
            guard visibleTodos.contains(where: { todo in
                bridgeState(for: todo)?.status == "working"
            }) else { return }
            workingSpinnerFrameIndex = (workingSpinnerFrameIndex + 1) % Self.workingSpinnerFrames.count
        }
    }

    private var resizeHandle: some View {
        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())

            Rectangle()
                .fill(Color(NSColor.separatorColor))
                .frame(width: 1)
        }
        .backport.pointerStyle(.resizeLeftRight)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let startWidth = resizeStartWidth ?? width
                    resizeStartWidth = startWidth
                    storedWidth = Double(Self.clampedWidth(startWidth - value.translation.width))
                }
                .onEnded { _ in
                    resizeStartWidth = nil
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Todo sidebar divider")
        .accessibilityValue("\(Int(width)) pixels")
        .accessibilityHint("Drag to resize the todo sidebar")
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { direction in
            let adjustment: CGFloat = 16
            switch direction {
            case .increment:
                storedWidth = Double(Self.clampedWidth(width + adjustment))
            case .decrement:
                storedWidth = Double(Self.clampedWidth(width - adjustment))
            @unknown default:
                break
            }
        }
    }

    private static func clampedWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minWidth), maxWidth)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No todos")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Text("Focused cwd has no .pi/todos files.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
    }

    private func todoRow(_ todo: TodoItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Button {
                    model.close(todo: todo)
                } label: {
                    Image(systemName: "circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Mark todo done")

                Text(todo.displayID)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                if let bridgeState = bridgeState(for: todo),
                   let statusIcon = bridgeStatusIcon(bridgeState) {
                    Text(statusIcon)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(bridgeState.status == "working" ? Color.green : Color.secondary)
                        .lineLimit(1)
                }
            }

            Text(todo.title)
                .font(.system(size: 12))
                .foregroundStyle(todo.isOpen ? Color.primary : Color.secondary)
                .lineLimit(2)

            HStack(spacing: 6) {
                todoActionButton("Work") {
                    sendPrompt("work on todo \(todo.displayID) \"\(todo.title)\"")
                }

                todoActionButton("Refine") {
                    sendPrompt(refinePrompt(for: todo))
                }

                todoActionButton("Open") {
                    openTodoInNewTab(todo)
                }

                Spacer(minLength: 0)

                if bridgeState(for: todo) != nil {
                    todoActionButton("Focus") {
                        focusSession(for: todo)
                    }
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(todo.isAssigned && todo.isOpen ? Color.accentColor.opacity(0.13) : Color.secondary.opacity(0.08))
        }
        .overlay(alignment: .trailing) {
            if isFocusedSessionTodo(todo) {
                Rectangle()
                    .fill(Color.green)
                    .frame(width: 3)
                    .padding(.vertical, 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help("\(todo.displayID) — \(todo.fileURL.path)")
    }

    private func todoActionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderless)
            .font(.caption2.weight(.medium))
            .controlSize(.mini)
    }

    private func sendPrompt(_ prompt: String) {
        focusedSurface?.surfaceModel?.sendText(prompt)
        focusedSurface?.window?.makeFirstResponder(focusedSurface)
    }

    private func bridgeState(for todo: TodoItem) -> AgentBridgeState? {
        if let state = agentBridgeStore.state(forSessionID: todo.assignedToSession) {
            return state
        }

        return agentBridgeStore.state(forTodoID: todo.id)
    }

    private func bridgeStatusIcon(_ state: AgentBridgeState) -> String? {
        switch state.status {
        case "working":
            return Self.workingSpinnerFrames[workingSpinnerFrameIndex]
        case "done":
            if isFocusedBridgeState(state) || agentBridgeStore.isAttentionAcknowledged(state) {
                return nil
            }
            return "🔔"
        case "waiting":
            return "…"
        default:
            return nil
        }
    }

    private func isFocusedBridgeState(_ state: AgentBridgeState) -> Bool {
        guard let focusedSurface,
              let ghosttySurfaceID = state.ghosttySurfaceID else { return false }

        return focusedSurface.id.uuidString == ghosttySurfaceID
    }

    private func isFocusedSessionTodo(_ todo: TodoItem) -> Bool {
        guard let bridgeState = bridgeState(for: todo) else { return false }

        return isFocusedBridgeState(bridgeState)
    }

    private func focusSession(for todo: TodoItem) {
        guard let state = bridgeState(for: todo) else { return }
        let sessionPrefix = String(state.sessionID.prefix(8))
        let todoID = todo.displayID
        let terminalControllers = TerminalController.all

        if let ghosttySurfaceID = state.ghosttySurfaceID,
           focusFirstSurface(in: terminalControllers, where: { surface in
               surface.id.uuidString == ghosttySurfaceID
           }) {
            return
        }

        if focusFirstSurface(in: terminalControllers, where: { surface in
            surface.title.contains(sessionPrefix) || surface.title.contains(todoID)
        }) {
            return
        }

        if focusFirstSurface(in: terminalControllers, where: { surface in
            surface.pwd == state.cwd && surface.title.contains("π")
        }) {
            return
        }

        _ = focusFirstSurface(in: terminalControllers, where: { surface in
            surface.pwd == state.cwd
        })
    }

    private func focusFirstSurface(
        in terminalControllers: [TerminalController],
        where matchesSurface: (Ghostty.SurfaceView) -> Bool
    ) -> Bool {
        let sourceController = focusedSurface?.window?.windowController as? TerminalController

        for controller in terminalControllers {
            for surface in controller.surfaceTree where matchesSurface(surface) {
                if WorkspaceStore.shared.present(surface: surface, from: sourceController ?? controller) {
                    return true
                }

                guard let window = controller.window else { return false }
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(surface)
                return true
            }
        }

        return false
    }

    private func refinePrompt(for todo: TodoItem) -> String {
        "let's refine task \(todo.displayID) \"\(todo.title)\": Ask me for the missing details needed to refine the todo together. Do not rewrite the todo yet and do not make assumptions. Ask clear, concrete questions and wait for my answers before drafting any structured description.\n\n"
    }

    private func openTodoInNewTab(_ todo: TodoItem) {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = cwdURL?.path ?? todo.fileURL.deletingLastPathComponent().path
        config.initialInput = "if test -n \"$EDITOR\"; $EDITOR \(shellQuoted(todo.fileURL.path)); else; vi \(shellQuoted(todo.fileURL.path)); end\n"

        _ = TerminalController.newTab(
            ghostty,
            from: focusedSurface?.window ?? NSApp.keyWindow,
            withBaseConfig: config)
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
#endif
