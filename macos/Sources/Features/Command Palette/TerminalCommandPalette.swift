import SwiftUI
import GhosttyKit

struct TerminalCommandPaletteView: View {
    /// The surface that this command palette represents.
    let surfaceView: Ghostty.SurfaceView

    /// Set this to true to show the view, this will be set to false if any actions
    /// result in the view disappearing.
    @Binding var isPresented: Bool

    /// The configuration so we can lookup keyboard shortcuts.
    @ObservedObject var ghosttyConfig: Ghostty.Config

    /// The update view model for showing update commands.
    var updateViewModel: UpdateViewModel?

    /// The callback when an action is submitted.
    var onAction: ((String) -> Void)

    var body: some View {
        ZStack {
            if isPresented {
                GeometryReader { geometry in
                    VStack {
                        Spacer().frame(height: geometry.size.height * 0.05)

                        ResponderChainInjector(responder: surfaceView)
                            .frame(width: 0, height: 0)

                        CommandPaletteView(
                            isPresented: $isPresented,
                            backgroundColor: ghosttyConfig.backgroundColor,
                            options: commandOptions
                        )
                        .zIndex(1) // Ensure it's on top

                        Spacer()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                }
            }
        }
        .onChange(of: isPresented) { newValue in
            // When the command palette disappears we need to send focus back to the
            // surface view we were overlaid on top of. There's probably a better way
            // to handle the first responder state here but I don't know it.
            if !newValue {
                // Has to be on queue because onChange happens on a user-interactive
                // thread and Xcode is mad about this call on that.
                DispatchQueue.main.async {
                    surfaceView.window?.makeFirstResponder(surfaceView)
                }
            }
        }
    }

    /// All commands available in the command palette, combining update and terminal options.
    private var commandOptions: [CommandOption] {
        var options: [CommandOption] = []
        // Updates always appear first
        options.append(contentsOf: updateOptions)

        // Sort the rest. We replace ":" with a character that sorts before space
        // so that "Foo:" sorts before "Foo Bar:". Use sortKey as a tie-breaker
        // for stable ordering when titles are equal.
        options.append(contentsOf: (workspaceOptions + jumpOptions + terminalOptions).sorted { a, b in
            let aNormalized = a.title.replacingOccurrences(of: ":", with: "\t")
            let bNormalized = b.title.replacingOccurrences(of: ":", with: "\t")
            let comparison = aNormalized.localizedCaseInsensitiveCompare(bNormalized)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            // Tie-breaker: use sortKey if both have one
            if let aSortKey = a.sortKey, let bSortKey = b.sortKey {
                return aSortKey < bSortKey
            }
            return false
        })
        return options
    }

    /// Commands for installing or canceling available updates.
    private var updateOptions: [CommandOption] {
        var options: [CommandOption] = []

        guard let updateViewModel, updateViewModel.state.isInstallable else {
            return options
        }

        // We override the update available one only because we want to properly
        // convey it'll go all the way through.
        let title: String
        if case .updateAvailable = updateViewModel.state {
            title = "Update Ghostty and Restart"
        } else {
            title = updateViewModel.text
        }

        options.append(CommandOption(
            title: title,
            description: updateViewModel.description,
            leadingIcon: updateViewModel.iconName ?? "shippingbox.fill",
            badge: updateViewModel.badge,
            emphasis: true
        ) {
            (NSApp.delegate as? AppDelegate)?.updateController.installUpdate()
        })

        options.append(CommandOption(
            title: "Cancel or Skip Update",
            description: "Dismiss the current update process"
        ) {
            updateViewModel.state.cancel()
        })

        return options
    }

    /// Workspace commands.
    private var workspaceOptions: [CommandOption] {
        guard let controller = surfaceView.window?.windowController as? TerminalController else { return [] }

        var options = [
            CommandOption(
                title: "Workspace: Create",
                description: "Create and switch to a new workspace",
                symbols: ["⌃", "N"],
                leadingIcon: "plus.rectangle.on.rectangle"
            ) {
                controller.createWorkspaceCommand()
            },
            CommandOption(
                title: "Workspace: Rename",
                description: "Rename the active workspace inline",
                leadingIcon: "pencil"
            ) {
                controller.renameActiveWorkspaceCommand()
            },
            CommandOption(
                title: "Workspace: Close",
                description: "Close the active workspace",
                symbols: ["⌃", "W"],
                leadingIcon: "xmark.rectangle"
            ) {
                controller.closeActiveWorkspaceCommand()
            },
            CommandOption(
                title: SidebarVisibilityStorage.isWorkspaceSidebarVisible ? "Workspace Sidebar: Hide" : "Workspace Sidebar: Show",
                description: "Toggle workspace sidebar visibility globally across terminal windows",
                leadingIcon: SidebarVisibilityStorage.isWorkspaceSidebarVisible ? "sidebar.left" : "sidebar.left"
            ) {
                SidebarVisibilityStorage.toggleWorkspaceSidebar()
            },
            CommandOption(
                title: SidebarVisibilityStorage.isTodoSidebarVisible ? "Todo Sidebar: Hide" : "Todo Sidebar: Show",
                description: "Toggle todo sidebar visibility globally across terminal windows",
                leadingIcon: SidebarVisibilityStorage.isTodoSidebarVisible ? "sidebar.right" : "sidebar.right"
            ) {
                SidebarVisibilityStorage.toggleTodoSidebar()
            },
        ]

        let workspaces = WorkspaceStore.shared.workspaces(in: controller.workspaceGroupID)
        options.append(contentsOf: workspaces.compactMap { workspace in
            guard workspace.id != controller.workspaceID else { return nil }
            return CommandOption(
                title: "Workspace: Move Tab to \(workspace.name)",
                description: "Move the current tab to \(workspace.name)",
                leadingIcon: "rectangle.portrait.and.arrow.right"
            ) {
                controller.moveTabToWorkspaceCommand(workspace.id)
            }
        })

        options.append(CommandOption(
            title: "Workspace: Move Tab to New Workspace",
            description: "Create a workspace and move the current tab there",
            leadingIcon: "plus.rectangle.portrait"
        ) {
            controller.moveTabToNewWorkspaceCommand()
        })

        return options
    }

    /// Custom commands from the command-palette-entry configuration.
    private var terminalOptions: [CommandOption] {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return [] }
        return appDelegate.ghostty.config.commandPaletteEntries
            .filter(\.isSupported)
            .map { c in
                let symbols = appDelegate.ghostty.config.keyboardShortcut(for: c.action)?.keyList
                return CommandOption(
                    title: c.title,
                    description: c.description,
                    symbols: symbols
                ) {
                    onAction(c.action)
                }
            }
    }

    /// Commands for jumping to other terminal surfaces.
    private var jumpOptions: [CommandOption] {
        let sourceController = surfaceView.window?.windowController as? TerminalController

        return TerminalController.all.flatMap { controller -> [CommandOption] in
            guard let window = controller.window else { return [] }

            let color = (window as? TerminalWindow)?.tabColor
            let displayColor = color != TerminalTabColor.none ? color : nil

            return controller.surfaceTree.map { surface in
                let terminalTitle = surface.title.isEmpty ? window.title : surface.title
                let displayTitle: String
                if let override = controller.titleOverride, !override.isEmpty {
                    displayTitle = override
                } else if !terminalTitle.isEmpty {
                    displayTitle = terminalTitle
                } else {
                    displayTitle = "Untitled"
                }
                let pwd = surface.pwd?.abbreviatedPath
                let subtitle: String? = if let pwd, !displayTitle.contains(pwd) {
                    pwd
                } else {
                    nil
                }

                return CommandOption(
                    title: "Focus: \(displayTitle)",
                    subtitle: subtitle,
                    leadingIcon: "rectangle.on.rectangle",
                    leadingColor: displayColor?.displayColor.map { Color($0) },
                    sortKey: AnySortKey(ObjectIdentifier(surface))
                ) {
                    if WorkspaceStore.shared.present(surface: surface, from: sourceController) {
                        return
                    }

                    NotificationCenter.default.post(
                        name: Ghostty.Notification.ghosttyPresentTerminal,
                        object: surface
                    )
                }
            }
        }
    }

}

/// This is done to ensure that the given view is in the responder chain.
private struct ResponderChainInjector: NSViewRepresentable {
    let responder: NSResponder

    func makeNSView(context: Context) -> NSView {
        let dummy = NSView()
        DispatchQueue.main.async {
            dummy.nextResponder = responder
        }
        return dummy
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
