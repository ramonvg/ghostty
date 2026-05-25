#if os(macOS)
import Foundation

struct Workspace: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var tabWindowIDs: [UUID]
    var activeTabWindowID: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        tabWindowIDs: [UUID] = [],
        activeTabWindowID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.tabWindowIDs = tabWindowIDs
        self.activeTabWindowID = activeTabWindowID
    }
}

struct WorkspaceGroup: Identifiable, Codable, Equatable {
    let id: UUID
    var workspaces: [Workspace]
    var activeWorkspaceID: UUID
}
#endif
