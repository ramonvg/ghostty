import Foundation

enum SidebarVisibilityStorage {
    static let workspaceSidebarVisibleKey = "WorkspaceSidebarVisible"
    static let todoSidebarVisibleKey = "TodoSidebarVisible"

    static var isWorkspaceSidebarVisible: Bool {
        get { bool(forKey: workspaceSidebarVisibleKey, defaultValue: true) }
        set { UserDefaults.standard.set(newValue, forKey: workspaceSidebarVisibleKey) }
    }

    static var isTodoSidebarVisible: Bool {
        get { bool(forKey: todoSidebarVisibleKey, defaultValue: true) }
        set { UserDefaults.standard.set(newValue, forKey: todoSidebarVisibleKey) }
    }

    static func toggleWorkspaceSidebar() {
        isWorkspaceSidebarVisible.toggle()
    }

    static func toggleTodoSidebar() {
        isTodoSidebarVisible.toggle()
    }

    private static func bool(forKey key: String, defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }
}
