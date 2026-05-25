# Implement macOS Workspaces for Terminal Tabs

## Summary

Add a macOS-only workspace concept to Ghostty. A workspace is a named group of tabs. The UI should show a left sidebar with workspaces, and the existing tabs should be scoped to the selected workspace.

Example:

```text
Window
  Workspace: Project A
    Tab 1
    Tab 2
  Workspace: Project B
    Tab 1
    Tab 2
    Tab 3
```

When the user selects `Project A`, only Project A's tabs are visible/selectable. When the user selects `Project B`, only Project B's tabs are visible/selectable.

For now, this only needs to support macOS.

## Current macOS architecture

Ghostty's macOS tab implementation uses native AppKit tabs:

- Each tab is a separate `TerminalController` and `NSWindow`.
- Tabs are grouped by AppKit via `NSWindowTabGroup`.
- A tab contains a `SplitTree<Ghostty.SurfaceView>` managed by `BaseTerminalController`.

Important files:

- `macos/Sources/Features/Terminal/TerminalController.swift`
  - Tab/window creation, close, move, goto, tab restoration integration.
  - Main APIs include:
    - `TerminalController.newWindow(...)`
    - `TerminalController.newTab(...)`
    - `closeTabImmediately(...)`
    - `relabelTabs()`
    - `onGotoTab`, `onMoveTab`, `onCloseTab`, etc.
- `macos/Sources/Features/Terminal/BaseTerminalController.swift`
  - Owns the current tab's split/surface tree.
- `macos/Sources/Features/Terminal/TerminalView.swift`
  - SwiftUI content for terminal/split rendering.
- `macos/Sources/Features/Terminal/TerminalViewContainer.swift`
  - AppKit container for the SwiftUI terminal view.
- `macos/Sources/Features/Terminal/TerminalRestorable.swift`
  - Window/tab restoration.
- `macos/Sources/Features/Terminal/TerminalRestorableState+InteralState.swift`
  - Codable state for restored tabs.
- `macos/Sources/Ghostty/Ghostty.App.swift`
  - Maps core keybind/actions to macOS notifications.
- `macos/Sources/Ghostty/GhosttyPackage.swift`
  - Notification names.
- `macos/Sources/App/macOS/AppDelegate.swift`
  - Receives Ghostty new-tab/new-window notifications and calls `TerminalController` APIs.

## Proposed model

Add a macOS-local workspace layer over the current native tabs.

A workspace should contain:

```swift
struct Workspace: Identifiable, Codable {
    let id: UUID
    var name: String
    var tabWindowIDs: [UUID] // or controller/window references at runtime
    var activeTabWindowID: UUID?
}
```

Each `TerminalController` should have a workspace assignment:

```swift
var workspaceID: UUID
```

The active workspace determines which tabs are visible in the native AppKit tab group.

## MVP behavior

- Show a left sidebar in terminal windows.
- Sidebar lists workspaces.
- User can create a new workspace.
- User can switch between workspaces.
- New tabs are created in the active workspace.
- Existing tab commands are scoped to the active workspace because only the active workspace's tabs are attached/visible.
- Closing a tab only affects the active workspace's visible tabs.
- `goto_tab:N`, `previous_tab`, `next_tab`, `last_tab`, etc. should naturally operate on the active workspace if inactive workspace tabs are detached/hidden.

## Suggested implementation plan

### 1. Add workspace files

Create a new directory:

```text
macos/Sources/Features/Workspaces/
```

Suggested files:

```text
Workspace.swift
WorkspaceStore.swift
WorkspaceSidebarView.swift
```

`WorkspaceStore` should be an `ObservableObject` responsible for:

- List of workspaces.
- Active workspace id.
- Mapping tab windows/controllers to workspace ids.
- Creating/deleting/renaming workspaces.
- Activating a workspace.

It can initially be a singleton or owned by `AppDelegate` and injected into views.

### 2. Add workspace id to `TerminalController`

In `macos/Sources/Features/Terminal/TerminalController.swift`, add a workspace id property.

New windows/tabs should join the active workspace by default. New tabs should inherit the workspace id from their parent controller.

Important method to update:

```swift
static func newTab(
    _ ghostty: Ghostty.App,
    from parent: NSWindow? = nil,
    withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil
) -> TerminalController?
```

When `parent.windowController as? TerminalController` exists, the created controller should get `parentController.workspaceID`.

### 3. Add sidebar UI to terminal content

In `macos/Sources/Features/Terminal/TerminalView.swift`, wrap the terminal split tree in a horizontal layout:

```swift
HStack(spacing: 0) {
    WorkspaceSidebarView(...)
    TerminalSplitTreeView(...)
}
```

The sidebar should be narrow and left-aligned. It should show workspace names and indicate the active workspace.

This can be hidden behind an experimental/static flag initially if needed.

### 4. Workspace switching mechanics

The main technical challenge is AppKit native tabs.

Current tabs are separate windows in a native `NSWindowTabGroup`. To scope tabs by workspace, inactive workspace tabs should be detached from the visible tab group and hidden, while active workspace tabs should be attached and shown.

Likely APIs/helpers involved:

- `window.tabGroup`
- `tabGroup.windows`
- `tabGroup.removeWindow(window)`
- `parent.addTabbedWindowSafely(window, ordered: .above)`
- `window.orderOut(nil)`
- `window.makeKeyAndOrderFront(nil)`

There is existing tab-group manipulation logic in `TerminalController.newTab(...)` that should be reused as a reference.

Workspace activation should roughly:

1. Determine the currently active controller/window.
2. Save the current workspace's active tab.
3. Get all currently visible tab group windows belonging to the old workspace.
4. Detach/order-out old workspace windows.
5. Get target workspace windows.
6. Attach target workspace windows into a native tab group.
7. Show/focus the target workspace's active tab.
8. Call `relabelTabs()` so tab keyboard labels match the visible scoped tabs.

Pseudo-code:

```swift
func activateWorkspace(_ workspaceID: UUID, from controller: TerminalController) {
    let currentWorkspaceID = activeWorkspaceID
    saveActiveTab(for: currentWorkspaceID, window: controller.window)

    let oldWindows = windows(for: currentWorkspaceID)
    for window in oldWindows {
        window.tabGroup?.removeWindow(window)
        window.orderOut(nil)
    }

    let targetWindows = windows(for: workspaceID)
    if targetWindows.isEmpty {
        TerminalController.newTab(... or newWindow ...)
        return
    }

    let anchor = targetWindows.first!
    anchor.makeKeyAndOrderFront(nil)

    for window in targetWindows.dropFirst() {
        anchor.addTabbedWindowSafely(window, ordered: .above)
    }

    activeWorkspaceID = workspaceID
    (anchor.windowController as? TerminalController)?.relabelTabs()
}
```

This may need adjustment because AppKit tab-group behavior can be fragile.

## Risks / caveats

### AppKit native tabs may fight this model

Because Ghostty currently relies on native `NSWindowTabGroup`, workspaces are not a first-class concept in AppKit. Moving windows between groups and hiding inactive ones may expose edge cases.

Potential issues:

- AppKit may auto-create tab groups in unexpected ways.
- Hidden/detached tab windows may still interact with restoration or window ordering.
- Native tab bar geometry and keyboard shortcut labels may need relabeling after every workspace switch.
- Dragging tabs between windows/workspaces needs explicit behavior later.
- Fullscreen native tabs may require special handling.

### Long-term alternative

The cleaner long-term architecture would be to stop representing each tab as an `NSWindow`. Instead, one real `NSWindowController` would own custom tab/session controllers and render custom tabs. That is a larger refactor and should not be the first attempt.

For MVP, keep native AppKit tabs and layer workspaces on top.

## Persistence

Persistence can be deferred for the MVP.

When implemented, extend:

- `macos/Sources/Features/Terminal/TerminalRestorable.swift`
- `macos/Sources/Features/Terminal/TerminalRestorableState+InteralState.swift`

Add fields such as:

```swift
let workspaceID: UUID?
let workspaceName: String?
```

Then rebuild `WorkspaceStore` during window restoration.

Need to be careful with `TerminalRestorableState.version` and migration. Current version is `7` with minimum version `5`.

## Later additions

Once the basic UI/model works:

- Rename workspace.
- Delete workspace.
- Move current tab to another workspace.
- Keyboard actions:
  - `new_workspace`
  - `close_workspace`
  - `goto_workspace:N`
  - `next_workspace`
  - `previous_workspace`
  - `move_tab_to_workspace:N`
- Persist workspace order/names.
- Optional config:
  - `macos-workspaces = true`
  - `macos-workspace-sidebar = always|auto|never`
  - `macos-workspace-sidebar-width = <px>`

## Acceptance criteria for MVP

- A left sidebar appears in macOS terminal windows.
- At least one default workspace exists.
- User can create a second workspace.
- User can switch between workspaces.
- Each workspace can have one or more tabs.
- Tabs shown in the native tab bar are scoped to the selected workspace.
- New tabs open in the selected workspace.
- Switching workspaces restores the previously selected tab in that workspace.
- Existing tab shortcuts operate only on visible/scoped tabs.

## Local rebuild/run command

For this local Xcode/CLT setup, rebuild and launch with:

```fish
env DEVELOPER_DIR=/Library/Developer/CommandLineTools zig build run -Dxcframework-target=native
```
