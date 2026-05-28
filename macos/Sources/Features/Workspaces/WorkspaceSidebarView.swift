#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceSidebarView: View {
    @ObservedObject var store: WorkspaceStore

    let groupID: UUID
    let activateWorkspace: (UUID) -> Void
    let createWorkspace: () -> Void
    let closeWorkspace: (UUID) -> Void
    let toggleVisibility: () -> Void

    static let defaultWidth: CGFloat = 168
    private static let minWidth: CGFloat = 120
    private static let maxWidth: CGFloat = 320

    @AppStorage("WorkspaceSidebarWidth") private var storedWidth: Double = 168
    @State private var resizeStartWidth: CGFloat?
    @State private var editingWorkspaceID: UUID?
    @State private var renameDraft: String = ""
    @State private var draggingWorkspaceID: UUID?
    @State private var isControlKeyPressed = false
    @FocusState private var focusedRenameWorkspaceID: UUID?

    private var width: CGFloat {
        Self.clampedWidth(CGFloat(storedWidth))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Workspaces")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: toggleVisibility) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Hide Workspaces")
                .accessibilityLabel("Hide Workspaces")

                Button(action: createWorkspace) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("New Workspace")
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            VStack(alignment: .leading, spacing: 3) {
                let workspaces = store.workspaces(in: groupID)
                ForEach(Array(workspaces.enumerated()), id: \.element.id) { index, workspace in
                    workspaceButton(workspace, index: index)
                }
            }
            .padding(.horizontal, 6)

            Spacer(minLength: 0)
        }
        .frame(width: width)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(alignment: .trailing) {
            resizeHandle
        }
        .onChange(of: store.renameRequest) { request in
            guard let request, request.groupID == groupID else { return }
            guard let workspace = store.workspaces(in: groupID).first(where: { $0.id == request.workspaceID }) else {
                return
            }

            beginRename(workspace)
        }
        .onAppear {
            isControlKeyPressed = NSEvent.modifierFlags.contains(.control)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyWorkspaceModifierFlagsChanged)) { notification in
            guard let isControlKeyPressed = notification.object as? Bool else { return }
            self.isControlKeyPressed = isControlKeyPressed
        }
    }

    private var resizeHandle: some View {
        ZStack(alignment: .trailing) {
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
                    storedWidth = Double(Self.clampedWidth(startWidth + value.translation.width))
                }
                .onEnded { _ in
                    resizeStartWidth = nil
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workspace sidebar divider")
        .accessibilityValue("\(Int(width)) pixels")
        .accessibilityHint("Drag to resize the workspace sidebar")
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

    @ViewBuilder
    private func workspaceButton(_ workspace: Workspace, index: Int) -> some View {
        let isActive = workspace.id == store.activeWorkspaceID(in: groupID)

        if editingWorkspaceID == workspace.id {
            workspaceRowContent(workspace, index: index, isActive: isActive)
                .contextMenu { workspaceContextMenu(workspace) }
                .help(store.workspaceDisplayName(in: groupID, workspaceID: workspace.id))
        } else {
            Button {
                activateWorkspace(workspace.id)
            } label: {
                workspaceRowContent(workspace, index: index, isActive: isActive)
            }
            .buttonStyle(.plain)
            .contextMenu { workspaceContextMenu(workspace) }
            .help(store.workspaceDisplayName(in: groupID, workspaceID: workspace.id))
            .modifier(workspaceReorderModifier(workspace, index: index))
        }
    }

    private func workspaceReorderModifier(_ workspace: Workspace, index: Int) -> WorkspaceReorderModifier {
        WorkspaceReorderModifier(
            store: store,
            groupID: groupID,
            workspaceID: workspace.id,
            destinationIndex: index,
            isEnabled: editingWorkspaceID == nil,
            draggingWorkspaceID: $draggingWorkspaceID)
    }

    private func workspaceRowContent(_ workspace: Workspace, index: Int, isActive: Bool) -> some View {
        let workspaceAccentColor = accentColor(for: workspace)

        return HStack(spacing: 8) {
            Capsule(style: .continuous)
                .fill(workspaceAccentColor)
                .frame(width: 3)
                .opacity(isActive || workspace.color != .none ? 1 : 0)

            VStack(alignment: .leading, spacing: 1) {
                if editingWorkspaceID == workspace.id {
                    TextField("Workspace name", text: $renameDraft)
                        .textFieldStyle(.plain)
                        .focused($focusedRenameWorkspaceID, equals: workspace.id)
                        .onSubmit { commitRename() }
                        .onAppear { focusedRenameWorkspaceID = workspace.id }
                } else {
                    Text(workspaceDisplayName(workspace))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let subtitle = store.workspaceSubtitle(in: groupID, workspaceID: workspace.id) {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer(minLength: 4)

            if isControlKeyPressed, let shortcutLabel = workspaceShortcutLabel(for: index) {
                Text(shortcutLabel)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isActive ? workspaceAccentColor : Color.secondary)
                    .frame(minWidth: 16, minHeight: 16)
                    .background {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.secondary.opacity(isActive ? 0.18 : 0.12))
                    }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(isActive ? workspaceAccentColor : Color.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? workspaceAccentColor.opacity(0.14) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isActive ? workspaceAccentColor.opacity(0.22) : Color.clear, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func workspaceContextMenu(_ workspace: Workspace) -> some View {
        Button("Rename") {
            beginRename(workspace)
        }

        Menu("Color") {
            ForEach(TerminalTabColor.allCases, id: \.rawValue) { color in
                Button {
                    store.setWorkspaceColor(color, for: workspace.id, in: groupID)
                } label: {
                    Label {
                        Text(color.localizedName)
                    } icon: {
                        workspaceColorMenuIcon(color, isSelected: color == workspace.color)
                    }
                }
            }
        }

        Button("Close Workspace", role: .destructive) {
            if editingWorkspaceID == workspace.id {
                cancelRename()
            }
            closeWorkspace(workspace.id)
        }
    }

    @ViewBuilder
    private func workspaceColorMenuIcon(_ color: TerminalTabColor, isSelected: Bool) -> some View {
        if color == .none {
            Image(systemName: isSelected ? "checkmark.circle" : "circle.slash")
                .foregroundStyle(.secondary)
        } else if let displayColor = color.displayColor {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle.fill")
                .foregroundStyle(Color(nsColor: displayColor))
        }
    }

    private func accentColor(for workspace: Workspace) -> Color {
        Color(nsColor: workspace.color.displayColor ?? .controlAccentColor)
    }

    private func workspaceDisplayName(_ workspace: Workspace) -> String {
        let displayName = store.workspaceDisplayName(in: groupID, workspaceID: workspace.id)
        switch store.workspaceAgentStatus(in: groupID, workspaceID: workspace.id) {
        case .working(let spinner):
            return "\(spinner) \(displayName)"
        case .attention:
            return "🔔 \(displayName)"
        case .none:
            return displayName
        }
    }

    private func workspaceShortcutLabel(for index: Int) -> String? {
        switch index {
        case 0...8: return "\(index + 1)"
        case 9: return "0"
        default: return nil
        }
    }

    private func beginRename(_ workspace: Workspace) {
        editingWorkspaceID = workspace.id
        renameDraft = workspace.name ?? store.workspaceDisplayName(in: groupID, workspaceID: workspace.id)
        focusedRenameWorkspaceID = workspace.id
        DispatchQueue.main.async {
            focusedRenameWorkspaceID = workspace.id
        }
    }

    private func commitRename() {
        guard let editingWorkspaceID else { return }
        store.renameWorkspace(editingWorkspaceID, in: groupID, to: renameDraft)
        cancelRename()
    }

    private func cancelRename() {
        editingWorkspaceID = nil
        focusedRenameWorkspaceID = nil
        renameDraft = ""
    }
}

private struct WorkspaceReorderModifier: ViewModifier {
    let store: WorkspaceStore
    let groupID: UUID
    let workspaceID: UUID
    let destinationIndex: Int
    let isEnabled: Bool
    @Binding var draggingWorkspaceID: UUID?

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .opacity(draggingWorkspaceID == workspaceID ? 0.55 : 1)
                .onDrag {
                    draggingWorkspaceID = workspaceID
                    return NSItemProvider(object: workspaceID.uuidString as NSString)
                }
                .onDrop(
                    of: [.plainText],
                    delegate: WorkspaceReorderDropDelegate(
                        store: store,
                        groupID: groupID,
                        destinationWorkspaceID: workspaceID,
                        destinationIndex: destinationIndex,
                        draggingWorkspaceID: $draggingWorkspaceID))
        } else {
            content
        }
    }
}

private struct WorkspaceReorderDropDelegate: DropDelegate {
    let store: WorkspaceStore
    let groupID: UUID
    let destinationWorkspaceID: UUID
    let destinationIndex: Int
    @Binding var draggingWorkspaceID: UUID?

    func dropEntered(info: DropInfo) {
        guard let draggingWorkspaceID else { return }
        guard draggingWorkspaceID != destinationWorkspaceID else { return }
        store.moveWorkspace(draggingWorkspaceID, in: groupID, to: destinationIndex)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingWorkspaceID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if !info.hasItemsConforming(to: [.plainText]) {
            draggingWorkspaceID = nil
        }
    }
}
#endif
