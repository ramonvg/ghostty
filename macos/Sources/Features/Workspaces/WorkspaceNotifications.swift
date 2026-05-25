#if os(macOS)
import Foundation

extension Notification.Name {
    static let ghosttyWorkspaceModifierFlagsChanged = Notification.Name(
        "com.mitchellh.ghostty.workspaceModifierFlagsChanged")
}
#endif
