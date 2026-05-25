#if os(macOS)
import AppKit
import SwiftUI

struct WorkspaceSidebarView: View {
    @ObservedObject var store: WorkspaceStore

    let groupID: UUID
    let activateWorkspace: (UUID) -> Void
    let createWorkspace: () -> Void
    let closeWorkspace: (UUID) -> Void

    static let defaultWidth: CGFloat = 168
    private static let minWidth: CGFloat = 120
    private static let maxWidth: CGFloat = 320

    @AppStorage("WorkspaceSidebarWidth") private var storedWidth: Double = 168
    @State private var resizeStartWidth: CGFloat?
    @State private var editingWorkspaceID: UUID?
    @State private var renameDraft: String = ""
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
                ForEach(store.workspaces(in: groupID)) { workspace in
                    workspaceButton(workspace)
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
    private func workspaceButton(_ workspace: Workspace) -> some View {
        let isActive = workspace.id == store.activeWorkspaceID(in: groupID)

        if editingWorkspaceID == workspace.id {
            workspaceRowContent(workspace, isActive: isActive)
                .contextMenu { workspaceContextMenu(workspace) }
                .help(workspace.name)
        } else {
            Button {
                activateWorkspace(workspace.id)
            } label: {
                workspaceRowContent(workspace, isActive: isActive)
            }
            .buttonStyle(.plain)
            .contextMenu { workspaceContextMenu(workspace) }
            .help(workspace.name)
        }
    }

    private func workspaceRowContent(_ workspace: Workspace, isActive: Bool) -> some View {
        HStack(spacing: 8) {
            if editingWorkspaceID == workspace.id {
                TextField("Workspace name", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .focused($focusedRenameWorkspaceID, equals: workspace.id)
                    .onSubmit { commitRename() }
                    .onAppear { focusedRenameWorkspaceID = workspace.id }
            } else {
                Text(workspace.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            if !workspace.tabWindowIDs.isEmpty {
                Text("\(workspace.tabWindowIDs.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.16) : Color.clear)
        }
    }

    @ViewBuilder
    private func workspaceContextMenu(_ workspace: Workspace) -> some View {
        Button("Rename") {
            beginRename(workspace)
        }

        Button("Close Workspace", role: .destructive) {
            if editingWorkspaceID == workspace.id {
                cancelRename()
            }
            closeWorkspace(workspace.id)
        }
    }

    private func beginRename(_ workspace: Workspace) {
        editingWorkspaceID = workspace.id
        renameDraft = workspace.name
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
#endif
