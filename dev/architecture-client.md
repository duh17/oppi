# Oppi client architecture

The Oppi Apple clients control and render server-owned and terminal-owned Pi sessions. They keep workspace navigation HTTP-first and reserve WebSockets for live streams. iOS paints the hot chat timeline with UIKit over authenticated HTTPS/WSS. Mac paints with AppKit and existing SwiftUI over the owner Unix socket.

## Audience and scope

Read this page before changing iOS or macOS client transport code, session and workspace stores, workspace navigation, chat timeline state, extension UI rendering, dictation, or media playback.

This page covers the Apple client structure. Server route, runtime, and storage details live in [Server architecture](architecture-server.md). For end-to-end LAN and paired HTTPS route selection, see [Networking and connection routing](networking.md).

## Detail map

This page keeps the rules that always apply. Read only the detail page for the area you are changing.

| Page | Covers |
| --- | --- |
| [Client blocks and shared core](architecture-client/blocks.md) | Client blocks; Shared Apple client core; Mac adapter path |
| [Transport and UI flows](architecture-client/flows.md) | Transport lanes; Workspace navigation flow; Focused session flow; Shared store updates; Extension UI on Apple |
| [Media, files, and sharing](architecture-client/media-files.md) | Media, files, and sharing |
| [Renderer change map and cleanup targets](architecture-client/change-map.md) | Renderer-addition change map; Client cleanup targets |
| [Where to look in code](architecture-client/code-map.md) | Where to look in code |

## Client responsibilities

The Apple client owns:

- paired-server credentials and endpoint selection,
- the global sessions inbox, workspace sidebar, server-global Skills and Extensions, workspace detail navigation, and focused-session navigation,
- focused session stream setup and recovery,
- app-event stream consumption and HTTP snapshot repair,
- per-session chat timeline state and rendering,
- extension UI sheets, ask cards, status rows, widgets, and native surfaces,
- voice input, audio playback, file previews, media playback, Quick Session intake, sharing, diagnostics, and settings.

The client does not execute Pi sessions or directly mutate server read models. It sends commands and renders the server projection.

## Client topology

The diagram below is the iOS HTTPS/WSS and UIKit composition. Mac uses the same `ChatSessionManager` and reducer core with owner-socket and AppKit/SwiftUI adapters; see [Mac adapter path](architecture-client/blocks.md#mac-adapter-path).

```mermaid
graph TD
  subgraph Transport[Transport]
    API[APIClient]
    AppEventClient[AppEventStreamClient]
    SessionClient[WebSocketClient]
    AudioClient[DictationStreamClient]
  end

  subgraph Coordination[Coordination]
    Connection[ServerConnection]
    AppEventCoord[AppEventStreamCoordinator]
    StreamCoord[SessionStreamCoordinator]
    Sender[MessageSender]
    Focus[FocusedSessionStore]
    ChatManager[ChatSessionManager]
  end

  subgraph State[State]
    SessionStore[SessionStore<br/>full state + list projection]
    WorkspaceStore[WorkspaceStore<br/>workspace catalog + summaries]
    ResourceStore[ServerResourceStore<br/>server-global Skills + Extensions]
    ExtensionUIState[Extension UI state<br/>AskRequestStore + dialogs/surfaces]
    ToolOutputStore[ToolOutputStore<br/>large tool output]
  end

  subgraph WorkspaceViews[Workspace navigation]
    Sidebar[WorkspaceSidebarViewController]
    Inbox[SessionInboxViewController]
    Detail[WorkspaceDetailViewController]
    Archive[WorkspaceStoppedSessionGrouping<br/>+ archive buckets]
    Resources[Skills and Extensions<br/>list + detail flows]
    Review[Workspace review<br/>quick actions]
  end

  subgraph Timeline[Per-session timeline]
    Reducer[TimelineReducer]
    UIKit[ChatTimelineCollectionView]
  end

  API --> Connection
  AppEventClient --> Connection
  SessionClient --> Connection
  AudioClient --> Connection
  Connection --> AppEventCoord
  Connection --> StreamCoord
  Connection --> Sender
  Connection --> Focus
  Connection --> SessionStore
  Connection --> WorkspaceStore
  Connection --> ResourceStore
  Connection --> ExtensionUIState
  Connection --> ChatManager
  Sidebar --> WorkspaceStore
  Inbox --> WorkspaceStore
  Inbox --> SessionStore
  Inbox --> API
  Detail --> SessionStore
  Detail --> API
  Archive --> API
  ResourceStore --> Resources
  Resources --> API
  Review --> API
  ChatManager --> Reducer
  Reducer --> ToolOutputStore
  ToolOutputStore --> UIKit
  Reducer --> UIKit
```

## UIKit and SwiftUI ownership

UIKit owns every iOS view and all app structure (decided 2026-10-15). The target is UIKit everywhere except the surfaces Apple requires in SwiftUI; the structure guard at the end of this section holds the ratchet.

### Rules (iOS, `clients/apple/Oppi`)

1. **New screens and views are UIKit.** Read `@Observable` stores in `updateProperties()` (iOS 26 observation tracking). Use `UICollectionView` list layout with content configurations for lists and settings, `navigationItem` bar items (set `visibilityPriority` and `axisBehavior` where the Duo's vertical bars matter), `UISheetPresentationController` for sheets, and `UIGlassEffect` for custom glass.
2. **Touched SwiftUI converts whole.** Work that changes a SwiftUI screen moves that whole screen to UIKit in the same work item, with behavior and accessibility-identifier parity, and the commit says so. Never put a UIKit view inside a SwiftUI screen. A SwiftUI leaf hosted inside a UIKit screen converts on its own, because that removes a seam. Untouched SwiftUI may wait for the next work that touches it.
3. **One router presents and pushes.** UIKit owns the window, split view, navigation stacks, and every sheet, full-screen cover, popover, and side panel, driven by `AppNavigation` through `Oppi/App/Router.swift` (`Oppi/App/HostFactory.swift` is its SwiftUI-facing half). UIKit screens use `Router.present` and `Router.push`, which take the theme from the presenter's app root, or a `RouterModalPresenter` slot whose request the screen sets in `updateProperties()`. `ModalPresentation` picks the style (`.sheet`, `.pageSheet`, `.fullScreen`, `.popover`, `.largeViewer(for:)`) and refines it (`.detents`, `.inNavigation`, `.arrowDirections`, `.keepsPopoverInCompactWidth`); `Router.selectSheetDetent` moves an open sheet. An iPad side panel is a `TrailingColumnController` column in regular width and a router sheet in compact width. A UIKit modal root that mirrors presenter state uses `RouterScreen.liveController(_:update:)`.
4. **Reuse the shared UIKit pieces** listed below before writing a new one.
5. **A list cell that changes its own layout must re-measure.** A collection view keeps the height it measured for a cell. The session lists set `selfSizingInvalidation = .enabledIncludingConstraints`, and a row that rearranges during layout invalidates its intrinsic size; otherwise its lines draw on top of each other.
6. **SwiftUI only where Apple requires it:** widgets, control widgets, Live Activities (`OppiControlWidget`, `OppiActivityExtension`), and App Intents UI.
7. **The structure guard enforces this** (below): no SwiftUI navigation or presentation constructs, no direct `UIHostingController`, and `import SwiftUI` counts only go down.

### Shared UIKit building blocks

- `IconChoiceUIView`: agent, workspace, and Pi icons (Quick Session, chat title, empty chat, sidebar).
- `InsetLabel`: pills and badges with insets and an optional capsule.
- `UIFont.scaled`, `UIFont.scaledMonospaced`, `UIImage.scaledSymbol`: the one Dynamic Type font and symbol helper.
- `WorkingSpinnerUIView`: the working spinner (timeline row, jump-to-bottom hint) for every spinner style.
- `PlainRowButton`, `ChangedFileRow`: a whole-row button and a changed-file row (context bar and Git panel, commit detail).
- `TerminalMirrorIndicatorUIView`: the pi-tui mirror mark (session rows, chat title).
- `HostSwitcherModel`: the single owner of the server list, connection retry, and switching.
- `ChangedRows`: reconfigure only the rows whose inputs changed, so an open menu survives a redraw.
- `SessionListCollection`, `SessionListBottomBar`: both session lists' collection view, rows, swipes, menus, refresh, search, and bottom bar.
- `FloatingProgressPanel`: the floating progress panel (workspace list, review).
- `WorkspaceQuickActionLauncher`: start a session for a quick action and push its chat (context bar, commit detail, review file).

### Remaining SwiftUI

- **Untouched for now:** Settings and admin screens (servers, agents, schedules, MCP, skills, workspace settings), onboarding, the thread detail, the full-screen reader's content router, debug and screenshot previews, and the session lists' Message capsule (`SessionInboxCompactComposeBar`, shared with the thread detail).
- **Framework-required:** the USDZ preview, because RealityKit's `RealityView` is SwiftUI-only, and the Apple-required surfaces in rule 6.

### HostFactory: the transitional seam

`OppiApp` publishes the app services as one `AppRootEnvironment` of stores, so a screen that captured it stays current. The scene sets it as a trait on its window; UIKit finds it with `HostFactory.root(near:)`, and a preview with its own fixture root uses `publishesAppRootToWindow`. `HostFactory` hosts the SwiftUI that remains: `HostFactory.screen` (a screen with the root, a `ScreenNavigator`, its `ScreenBars`, and the theme), `HostFactory.content(_:root:)` (SwiftUI embedded in a UIKit view; pass the root), and `HostFactory.appLockCover` (paints before the root exists). Never call `UIHostingController(` directly or hand-write an environment list. Presenter-local values go on the content explicitly (`withServerScopedEnvironment(connection)`, `presenterScope(connection:apiClient:navigation:)`). Hosted screens navigate through `@Environment(\.screenNavigator)` (`push`, `finish()`), present with `routerModal`, and search with `routerSearchable`. HostFactory shrinks as screens convert; no new work should need it.

### Gotchas while hosted SwiftUI remains

- **A missing required `@Environment(Type.self)` across a hosting seam crashes** (build 54 on the iOS app on Mac, `0ffdb2e5b`; the file viewer, `06d79f50c`). Host only through `HostFactory`.
- **SwiftUI navigation does nothing in a UIKit stack.** `NavigationLink` destinations lose the app environment, `navigationDestination` and value links do nothing, `.searchable` never reaches the UIKit bar, and `dismiss()` does nothing at a presented root. Use the navigator, `routerModal`, `routerSearchable`, and `finish()`.
- **Each hosted screen is its own SwiftUI graph.** A covered screen stops updating, so a `@Binding` into the presenter's `@State` goes stale. Share state through an `@Observable` model (`AgentNativeEditDraft`).
- **A covered presenter stops rendering**, so a modal that edits presenter state uses `.overFullScreen`, not `.fullScreen` (chat's Share in regular width, the expanded composer, composer pickers).
- **`routerModal` presents a run-loop turn late** (enforced in `RouterModalPresenter`) and only while the declaring view is in the window: declare it on a pushed page too (`mcpSignInModal`). Pass a stored binding.
- **A router presentation ignores SwiftUI presentation modifiers.** Pass a `ModalPresentation` (`ModalPresentation.iconPicker`); `interactiveDismissDisabled` still reaches UIKit.
- **Search bars outlive their modal** unless ended: `Router.endSearch` runs on `finish()`, swipe-down, and trailing-column removal.
- **`ScreenNavigator.forUIKitScreen` is push-only.** `finish()` would pop the UIKit screen.
- **A preview nothing launches is deleted, not converted.** Previews use `RouterPreviewStack` or `RouterPreviewNavigation`; `scripts/screenshot-screen-guard.ts` fails when a test launches a screen no case serves.

### Chat composer

The composer is UIKit, including the action-row pills and their pickers, the Ask card, and the expanded composer (`ExpandedComposerViewController`); its bar is `ComposerBarController`, and the decisions it makes (what shows, the placeholder, the primary action, Ask paging) are `ComposerPolicy`. Every screen embeds it through `ChatComposerOwner` (`Oppi/Features/Chat/Composer/ChatComposerOwner.swift`), a child controller that owns `ComposerBarController`, the dictation-failure notice, the busy-mode tip, inline voice, focus and dictation requests, and the expanded composer, and reads the screen's draft and session state from a `ChatComposerSource` in its own `updateProperties()`; the owner measures the bar itself when its height changes (focus, the Ask slot, the busy-mode tip). The chat is one source. Quick Session (`QuickSessionViewController`, its state in `QuickSessionModel`) is the second `ChatComposerSource` on the same owner. The guided control-session composer (`GuidedControlComposerController`, its state and atomic launch in `GuidedControlComposerModel`) is another `ChatComposerSource` on the same owner: Agents, Schedules, and Custom Themes pin it above the keyboard, and the guided sheet (`GuidedControlSessionViewController`) holds it. The guided sheet is what Agents, Schedules, Custom Themes, the reviewable control Markdown screen (`ReviewableControlMarkdownViewController`, which passes its staged review comments), and the chat's Context panel (Edit with Oppi on an extension) present. No SwiftUI screen embeds the composer. The SSH terminal embeds `ComposerBarController` directly in a terminal configuration; one UIKit key-strip view serves the chat bar and the raw-keyboard accessory. The Ask card (`AskCardViewController`) sits in the composer's Ask slot at its natural height, capped; its rows scroll inside the card while Send / Ignore stay in its footer. Its expanded sheet and the expanded composer are UIKit view controllers presented through the router; the extension editor dialog is the expanded composer in an editor configuration. Presentations from the composer go through the router or UIKit, never SwiftUI `.sheet`. Suggestion lists are a UIKit collection view fed by `FileSuggestionRanker` / `ComposerAutocomplete.slashSuggestions`; the view does not re-rank.

### The shell

A UIKit scene (`SceneDelegate`, `Oppi/App/AppDelegate.swift`) owns the window; `OppiApp` holds the services, launch, and scene phases, and every open (scene URLs, notification responses, Siri and system controls, resource and file links) is one `AppOpenRequest` delivered to the window's `AppOpener`, which waits for App Lock, launch, a scoped lock, and the target server before it drives `AppNavigation`. `AppRootViewController` applies the theme to the window and shows the launch backdrop, onboarding, or the workspace shell, above the SwiftUI `AppRootLayer` (app-wide modals, workspace creation the shell starts). Quick Session is a UIKit controller (`QuickSessionViewController`) that `QuickSessionPresentation` mounts above the content while `AppNavigation.showQuickSession` is set: it hosts the Quick Session start `AppOpener` delivers once the shell is up, makes the content under it inert to touch and VoiceOver, and on dismissal opens the session a launch created and returns VoiceOver focus to the control that opened it. Its workspace and worktree pickers are UIKit popovers on their pills; the model picker is the shared UIKit `ModelPickerViewController` (the chat, Guided Control, and the Agent and Schedule editors present it too, with the presenter's server passed in; it owns its bar and `UISearchController`). `WorkspaceShellController` measures the window and mounts the compact stack with its workspace drawer or a `UISplitViewController`: a fold or resize first converts `AppNavigation`'s routes for the new layout, then mounts it from them, so the stacks rebuild where the user was. `AppNavigation` is the single source of truth for every stack. `ShellNavigationController` (`Oppi/App/ShellRouter.swift`) shows exactly the routes it is given, keeps the screens that stay, and reports the user's pops back (`popWorkspaceStack(toDepth:)`, `popSplitDetail(toDepth:)`). `ShellRouteScreens` (`Oppi/App/WorkspaceShellRoutes.swift`) makes each route's screen: All Sessions (`SessionInboxViewController`), the workspace sidebar (`WorkspaceSidebarViewController`, also the compact drawer), a workspace's sessions (`WorkspaceDetailViewController`), a session (`ChatRouteViewController`: its lock gate and server connection, then `ChatViewController`), Files (`FileBrowserViewController`: its lock gate and server connection, then a folder's list, or in regular width the folder tree beside the open file), a linked file (`WorkspaceLinkedFileViewController`: its lock gate and server connection, then the file viewer `FileViewerViewController`), a Skill file (`ServerSkillFileViewController`), SSH Terminal's host list (`SSHTerminalHostListViewController`), Schedules (`ScheduleListViewController`), and Agents (`AgentListViewController`) are UIKit controllers mounted directly, which take a refreshed route through `ShellRouteScreens.update` without being rebuilt; every other route is a `ShellRouteView` hosted with `HostFactory.screen`. The two session lists (All Sessions and a workspace's sessions) share their UIKit pieces (`SessionListCollection.swift`: the `SessionListCollection` that owns the collection view, its diffable snapshot, the cells and headers, and row taps, swipes, and the long-press menu; row values; the search bar binding; Stop, Resume, and Delete requests; alerts; bar items, the Message and Now Playing controls (`SessionListBottomBar`), and the server switcher) and draw each row as a UIKit cell (`SessionListEntryConfiguration`: `SessionRowView`, then the Thread strip or `In thread` link); the Session Rows settings page previews the same `SessionRowView`. The server switcher's rows and actions have one owner, `HostSwitcherModel`, which the lists' UIMenu and the Settings toolbars' SwiftUI `HostSwitcherMenu` both draw. The lists' Message capsule is still the hosted SwiftUI `SessionInboxCompactComposeBar`, which the SwiftUI thread detail shares. A screen opens a route by calling `AppNavigation` (`openWorkspace`, `openWorkspaceSession`, `openWorkspaceFileBrowser`, ...). A page that exists only above the screen that opened it (a fork, a quick-action chat, a host file, an agent's or schedule's detail, the SSH terminal) pushes with `ScreenNavigator.push` and stays above that screen until a route below it changes; a push asked for while a pop animates waits for it to finish. A pushed page whose presenter must react to it closing reports that itself: the SSH terminal clears `showsTerminal` when it leaves and pops itself when the session stops showing it, and Pi's Tools page saves through the observable model it edits when it closes. `finish()` at the split detail root shows the column's list. Every route is hosted directly in its UIKit stack, with the UIKit bar and back swipe.

**Mac (`clients/apple/OppiMac`)**

New Mac views are AppKit by default. Existing SwiftUI Mac code stays until a separate migration decision. The AGENTS.md rule still holds: a feature does not touch the Mac app unless the request names Mac, macOS, desktop, or OppiMac.

**OppiCore** stays UI-framework-free.

**Structure guard.** `scripts/uikit-structure-guard.ts` scans `clients/apple/Oppi/**/*.swift` after stripping comments and string literals. `NavigationStack`, `NavigationSplitView`, `NavigationLink`, `.navigationDestination(`, `.sheet(`, `.fullScreenCover(`, `.popover(`, `.inspector(`, `UIHostingController(`, and `UIHostingController<` (a subclass or stored type) are disallowed in every file, previews and harnesses included; the only exception is `HostFactory.swift`'s two hosting controllers (`HostedScreenController`, `HostedContentController`), a commented entry in the guard's `allowed` list, and another would need Chen's approval. `import SwiftUI` is a ratchet: a file fails when its count exceeds `scripts/uikit-structure-baseline.json`; new files have baseline 0 and decreases pass. Lowering the baseline after a migration is expected: run `bun scripts/uikit-structure-guard.ts --update` and commit the reduced baseline with the migration. Renaming or moving a file keeps its count, so `--update` after a rename is fine when the baseline diff only moves entries. Ordinary runs never write the baseline.

### The chat bar and the SSH terminal

`ChatBarItems` (`Oppi/Features/Chat/ChatViewController+Bars.swift`) owns the chat's bar in both shapes: Back leading; the chosen buttons and a … menu trailing on a horizontal bar, the same controls one per position on the Duo's vertical rail. The buttons and their order come from `AppPreferences.ChatTopBar` as a `ChatTopBarLayout` (`Support/ChatTopBarActions.swift`): every one of Files, Git, Outline, Context, and Terminal has a place in `order`, and the ones in `shown` are drawn in the bar while the rest are offered in the … menu, also in that order; a stored layout missing an action (one saved before Git) gets it appended to `order` and not shown, so it keeps its bar and offers the newcomer in the … menu. Git opens the chat's Git panel (`ChatGitPanelViewController`), a side panel like Outline and Context: it hosts `WorkspaceContextBarView` with `Options.isPanel` (always expanded, no collapse chevron, no glass card or outer padding, no 480 pt cap) and `Options.pushChat`, so a session started from it closes the panel and pushes onto the chat's stack, and there is no Git strip over the timeline. `ContextBarScoping` decides what the bar lists: a session in its own worktree (`worktreeId` set and not `WorkspaceWorktree.mainId`) lists the whole Git status; a main-checkout session lists its `changeStats.changedFiles` (This session) with a switch to the whole status (All changes), panel state only. The Git bar button's accessibility value and count badge (bar only, not the rail) come from the same scoping with This session. The context ring is not a fixed control: `.context` is a bar position like the others, drawn by `ContextUsageRingButton` in the bar and by its rail item on the Duo, and its … menu item carries the usage percent as a subtitle. `ChatBarItems.runTopBarAction` is the one owner of what a button does, so a bar button, a rail item, a menu item, and accessibility activation are the same path. Availability is a set, not a decision inside the bar: a chat with no workspace offers no Files, Git, or Terminal, Git also needs a workspace that may be a repository (`ChatBarItems.mayOfferGit`: not with Git status off or a loaded status that says it is none; kept while unknown), an empty timeline offers no Outline, and Terminal needs a workspace folder a shell can start in (`SSHTerminalFolderTarget.workspace(_:)`: not a sandbox workspace, not a relative mount). `ChatTopBarLayout.bar(available:)` and `menu(available:)` drop what cannot be offered instead of borrowing another button's place, so a button the user showed never leaves the bar looking like a different one. While a folder lookup runs, the Terminal control is disabled and says Opening…, so one tap cannot push two screens. Settings → Chat is `SettingsChatViewController`, a UIKit collection-view page (the SwiftUI preview cards stay in `ChatDisplayPreviewCards.swift` for the screenshot harness) whose Top Bar row pushes `SettingsChatTopBarViewController`, a UIKit list with one switch per button and reorder handles, in editing mode so the handles are always there; A switch and a drag both write through `AppPreferences.ChatTopBar.setLayout`, and the chats read the change through `AppPreferences.ChatTopBar.didChangeNotification`; the Chat page's Top Bar row observes the same notification, so its summary follows an edit made on the pushed page. The … menu is built once and resolves its hidden actions through `UIDeferredMenuElement.uncached`, so a pass that changes the bar never re-attaches the menu its owner is holding.

A workspace's bar has its own Terminal item (`workspace.terminal.open`, beside Config in both shapes) and both entry points end at `SSHTerminalFolderEntry.open`, which needs the paired server's host and a folder it can resolve (an absolute path, or the server's `~` form, expanded on the host). It matches saved hosts with `SSHTerminalHostMatch` (case-insensitive, trailing dot ignored) and takes them in this order: an exact host name, then a bare short name matched against its FQDN; within one kind, a host whose Run on Connect command starts a multiplexer comes before one with no command, then one running anything else, then the first saved. It pushes `SSHTerminalFolderViewController` to connect, or pushes the Add Host form prefilled with the server's host and nothing invented for the username, which continues into the folder terminal once saved. Where the folder opens is the host's Run on Connect command's first word, matched by name (`SSHTerminalMultiplexerKind.detected(in:)`: `herdr`, `/Users/me/.local/bin/herdr`, `herdr --attach` are Herdr; `tmux`, `tmux new -A -s main` are tmux; anything else or nothing is no multiplexer, and the folder terminal is the plain login shell it always was). Two placements cover both, so a new multiplexer is one more case in the kind and one more type conforming to `SSHTerminalMultiplexer`, never a second copy of the flow: `.hostTerminal` reuses the host's own terminal — the one its Run on Connect command opened — and drives the multiplexer over that terminal's side exec channel (`HerdrMultiplexer`: read the host's `$HOME` and the folder's physical path (`pwd -P`) and `herdr api snapshot` in one side command, focus the workspace that already has a pane whose cwd is the folder in either spelling, else `herdr workspace create --cwd … --label … --focus`, or `herdr worktree open --path … --label … --focus` for a chat's git worktree); `.folderTerminal` starts a terminal of its own for the folder, whose command is the multiplexer's attach command (`TmuxMultiplexer`: `tmux new -A -s <session> -c <folder>`, the session named after the workspace and worktree plus a stable folder hash, with `.` and `:` — tmux target syntax — replaced by `-` and `#` doubled so tmux keeps it literal; the command enters the folder itself instead of passing `-c`, because tmux expands formats in its arguments and starts in the home folder when it cannot enter the one it was given). `SSHTerminalFolderEntry.prepare(session:profile:target:)` is the one place that turns a target and a profile into those three cases, and both the folder screen and the Add Host form go through it. Nothing is typed into a running program: a `.hostTerminal` open runs only CLI calls, and its refusal shows as a terminal notice while the person stays in the host's terminal. A Herdr focus moves the Herdr session's focus, so other clients attached to that session follow it. `SSHTerminalRegistry` keys terminals by `SSHTerminalIdentity` — `(profileID, folder)` — so a tmux folder terminal and the host's own terminal (login shell or Run on Connect) coexist, and editing or deleting the host still ends every terminal of that host, and so does the background grace. A `.hostTerminal` folder therefore lands in the host's existing terminal rather than a second one. `SSHTerminalConnectSession.folder` makes the remote command `SSHTerminalFolderCommand.command(folder:)`, or `folderTerminalCommand` when the multiplexer supplies one: `sh -c` with the script as one quoted word, which changes directory, reports a missing folder and exits non-zero instead of opening a shell elsewhere, then `exec`s the remote login shell so fish, zsh, and bash all work. The folder is never shell code: the *remote login shell* parses that word first, and fish reads `\'` inside single quotes as an escaped quote, so the word contains no `'`, `\'`, or `\\`. `SSHTerminalRemoteShell` owns that rule for every command the folder flow generates — the plain shell, the tmux attach, and Herdr's create and worktree calls: `octalEncoded` turns every byte of a value into `\NNN` and the inner `sh` rebuilds it with `printf` into a variable; surrounding whitespace is trimmed the way the server resolves a mount, so a folder ending in a newline opens the trimmed folder, and a sentinel byte plus `${p%x}` keeps command substitution from eating a trailing newline a caller might pass. The `~` form becomes `"$HOME"/"$(printf …)"`, and Herdr, whose CLI takes a path, gets the absolute path built from that same `$HOME`.

## Terminal tool output

Timeline rows paint terminal-kind tool output from `ToolOutputStore`. The server sends stripped text: a suffix under 8 KiB, or a throttled 16 KiB / 80-line tail replace after that. Opening the full log still uses the sidecar. SSH terminal sessions are a separate surface.

Opening a busy session replays the server event ring over the freshly loaded trace. The replayed `agent_start` closes the running tool as inferred-interrupted; the replayed `tool_start` then revives it, because a start is authoritative evidence the call is executing. Canonically finished calls stay finished. The expanded row and full-screen reader use the stored text, and an explicit open loads the sidecar. They do not wait on a byte-log resync.

## Client boundary rules current code

These rules are enforced by `server/scripts/check-architecture-boundaries.ts` during server checks (`--scope all`), the iOS build phase (`--scope ios`), and the Mac pre-push gate (`--scope mac`):

- `clients/apple/OppiCore/Runtime/TimelineReducer.swift` and `DeltaCoalescer.swift` must stay platform-neutral under the shared-core import rule.
- `clients/apple/OppiCore/**` files must not import UIKit, AppKit, SwiftUI, ActivityKit, UserNotifications, Speech, AVFoundation, WebKit, or MetricKit. Put platform-specific code in the iOS or macOS app target.
- `clients/apple/OppiMac/**` files must not import UIKit. New Mac views are AppKit by default; existing SwiftUI Mac code stays until a separate migration decision.
- `project.yml` is the Mac target membership authority. OppiMac may compile `OppiMac/**`, `OppiCore/**`, `Shared/**`, and only the established `Oppi/**` adapter files listed there; do not add arbitrary iOS production files to the Mac target.
- `clients/apple/Oppi/Core/Views/**` and `clients/apple/Oppi/Features/Chat/Timeline/**` must not reference `APIClient` or `WebSocketClient` directly.
- `clients/apple/Oppi/Core/Views/**` and `clients/apple/Oppi/Features/Chat/Timeline/**` must not reference `ServerConnection`, `ConnectionCoordinator`, `apiClient` (member, environment key path, or binding), `wsClient`, or `SessionStore`/`WorkspaceStore` (`view-layer-connection-boundary`). They receive explicit values (`SessionContentAccess`, icon cache) and typed actions from chat composition.
- Workspace and quick-session list views must read `SessionStore.listProjectionSessions` or `listProjectionSessions(workspaceId:)`, not full `SessionStore.sessions`.
- `SessionStore`, `WorkspaceStore`, `ServerResourceStore`, and shared stores under `clients/apple/OppiCore/Stores/**` must not depend on each other. Cross-store workflows belong in `ServerConnection` or a small service.
- iOS opens go through `AppOpener` (`Oppi/App/AppOpener.swift`). Every entry point (scene URLs, notification responses, App Intents and controls, timeline and extension links, SwiftUI `openURL`) delivers one `AppOpenRequest` to the window's opener (`HostFactory.root(near:).opener`, or the root's `openURL` action); there is no NotificationCenter open bus. Only the opener waits for App Lock (`performWhenUnlocked`), launch, and the target server; applies the browser preference; and system-opens URLs. Only the opener and Tailnet authentication may present `InAppBrowserPresenter` directly. Timeline `UITextViewDelegate` conformances must implement `primaryActionFor` in the same file.
- Generic extension UI rendering and routing must not branch on concrete tool names, extension names, status keys, widget keys, or display names. Add semantic protocol metadata at the producer boundary instead. This includes `ExtensionSurfacePanel.swift` and `MacExtensionSurfacePanel.swift`.
- SwiftUI foreground, fill, and stroke styling must use the environment-resolved `.theme*` `ShapeStyle` shorthand. `Color.theme*` is a runtime snapshot for APIs that require a concrete `Color` or a UIKit/AppKit bridge. Persistent list and panel modifiers must read `theme` or `themeID` from the environment so mounted content repaints after a theme switch. `scripts/theme-surface-guard.ts` enforces the shorthand boundary during the iOS architecture check.
- iOS SwiftUI navigation and presentation constructs (`NavigationStack`, `NavigationSplitView`, `NavigationLink`, `.navigationDestination(`, `.sheet(`, `.fullScreenCover(`, `.popover(`, `.inspector(`, `UIHostingController(`, `UIHostingController<`) are disallowed under `clients/apple/Oppi`, and `import SwiftUI` may not exceed the per-file counts in `scripts/uikit-structure-baseline.json` (new files start at 0). `scripts/uikit-structure-guard.ts` enforces both during the iOS architecture check, and `scripts/screenshot-screen-guard.ts` checks that every `SCREENSHOT_SCREEN` a UI or E2E test launches has a preview case; see [UIKit and SwiftUI ownership](#uikit-and-swiftui-ownership).
