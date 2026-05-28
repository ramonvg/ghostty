#if os(macOS)
import Foundation

struct Workspace: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String?
    var tabWindowIDs: [UUID]
    var activeTabWindowID: UUID?
    var color: TerminalTabColor

    init(
        id: UUID = UUID(),
        name: String? = nil,
        tabWindowIDs: [UUID] = [],
        activeTabWindowID: UUID? = nil,
        color: TerminalTabColor = .none
    ) {
        self.id = id
        self.name = name
        self.tabWindowIDs = tabWindowIDs
        self.activeTabWindowID = activeTabWindowID
        self.color = color
    }
}

struct WorkspaceGroup: Identifiable, Codable, Equatable {
    let id: UUID
    var workspaces: [Workspace]
    var activeWorkspaceID: UUID
}

struct WorkspaceRenameRequest: Equatable {
    let groupID: UUID
    let workspaceID: UUID
    let token: UUID
}
#endif
