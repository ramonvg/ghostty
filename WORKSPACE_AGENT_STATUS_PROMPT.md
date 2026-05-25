# Prompt: Workspace agent status integration

We are working on Ramon's Ghostty Workspaces branch. The goal is to make the workspace sidebar reflect the status of Pi coding agents running inside terminal tabs/surfaces.

## User intent

A Ghostty workspace can contain multiple terminal tabs, and each tab may run a Pi agent. Ramon wants the workspace row in the left sidebar to summarize agent activity across all tabs in that workspace.

Desired priority behavior:

1. If **at least one Pi agent in the workspace is actively working**, show the active loading spinner on the workspace row.
   - Example: `⠋ Default`
   - Spinner state should win over all other states.

2. Else, if **at least one Pi agent in the workspace has finished and needs attention**, show a notification/bell indicator.
   - Example: `🔔 Default`
   - This represents “there is a completed agent / notification here.”

3. Else, show the normal workspace name.
   - Example: `Default`

The purpose is to make it easy to glance at the workspace list and know where agents are still working or waiting for review.

## Current implementation context

There is already a commit that added basic spinner mirroring:

- Commit: `5baaeabf3 feat(workspaces): show loading spinner in sidebar`
- Files touched:
  - `macos/Sources/Features/Workspaces/WorkspaceStore.swift`
  - `macos/Sources/Features/Workspaces/WorkspaceSidebarView.swift`

Current behavior parses Pi’s terminal/window title for braille spinner frames like:

```text
⠋ π · ghostty
```

and prefixes the workspace name with that frame. It also observes window title and surface title changes to refresh workspace metadata.

This works for the active spinner, but it does not yet expose Pi’s finished/idle state. After Pi finishes, Ramon's Pi extension updates the terminal/tab title to something like:

```text
🔔 π · ghostty · 💤 0s ago
```

The native Ghostty tab shows this correctly, but the workspace sidebar currently does not show the bell/idle status.

## Pi extension context

The relevant Pi extension is:

```text
~/.pi/agent/extensions/bell.ts
```

It currently does:

- On `agent_start`: animates a braille spinner in the terminal title.
- On `agent_end`: stops the spinner, writes BEL, and sets an idle title like `π · session · cwd · 💤 0s ago`.
- It may show a bell indicator in the tab/title because of Ghostty bell behavior and/or the title string.

Ramon is considering whether Ghostty should continue inspecting the human-facing title, or whether the Pi extension should emit a structured terminal-native status signal.

## Design discussion / preferred direction

Short-term simple approach:

- Extend the existing Ghostty title parsing logic.
- Replace `workspaceLoadingSpinner(...)` with a more general `workspaceAgentStatus(...)` / `workspaceStatusPrefix(...)`.
- Parse all relevant titles for:
  - active spinner frames: `⠋`, `⠙`, `⠹`, `⠸`, `⠼`, `⠴`, `⠦`, `⠧`, `⠇`, `⠏`
  - done/attention marker: `🔔` and/or `💤` in titles containing `π`
- Return statuses by priority:
  - working(spinnerFrame)
  - attention
  - none
- Sidebar uses the status prefix before the workspace name.

Better long-term approach:

- Update the Pi extension to emit a custom terminal escape sequence / OSC status message that Ghostty Workspaces can parse structurally.
- Example conceptual protocol:

```text
ESC ] 777 ; ghostty-workspace-agent ; working ; <agent-id> BEL
ESC ] 777 ; ghostty-workspace-agent ; done ; <agent-id> BEL
ESC ] 777 ; ghostty-workspace-agent ; idle ; <agent-id> BEL
```

or another appropriate Ghostty-supported/custom OSC.

Advantages:

- Ghostty no longer has to infer state from human-facing window titles.
- Status is received by the correct terminal surface automatically because the escape sequence is written to that terminal.
- Multiple agents per workspace can be tracked more accurately.
- Title parsing can remain as a fallback for old Pi extensions.

Avoid external IPC unless necessary. A socket/file/server would make it harder to map Pi process → Ghostty terminal surface, while terminal escape sequences naturally preserve that mapping.

## What to implement next

A good next step is probably one of:

### Option A: Quick fix via title parsing

Implement the status priority logic in Ghostty using existing title parsing:

```swift
if any title has active Pi spinner:
    show spinner frame
else if any title has Pi bell/idle marker:
    show "🔔"
else:
    show no prefix
```

Keep the code structured with a status enum so it can later be backed by structured OSC instead of title parsing.

### Option B: Structured OSC prototype

1. Add a structured status field to Ghostty terminal surfaces.
2. Parse a custom OSC emitted by terminal applications.
3. Update `~/.pi/agent/extensions/bell.ts` to emit status events on `agent_start`, `agent_end`, idle cleared, and session shutdown.
4. Aggregate statuses in `WorkspaceStore` using priority:
   - working > attention > none
5. Keep title parsing fallback.

## Important UX detail

When a workspace contains multiple agents:

- One working + one done => show spinner.
- None working + one or more done => show bell.
- None working/done => show normal name.

The workspace row should summarize the highest-priority state, not list every agent.
