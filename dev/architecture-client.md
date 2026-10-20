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

UIKit owns iOS structure. Decided 2026-10-15; the structure guard below enforces it.

**iOS (`clients/apple/Oppi`)**

1. **UIKit owns app structure and every modal.** Window root, split view, navigation stacks, and every presentation (sheet, full-screen cover, popover, inspector) belong to UIKit, through one router driven by `AppNavigation`. The router is `Oppi/App/Router.swift` for UIKit and `Oppi/App/HostFactory.swift` for the SwiftUI-facing API; the shell below uses both. A SwiftUI screen presents with `routerModal(item:presentation:onDismiss:content:)` or `routerModal(isPresented:...)` instead of `.sheet`, `.fullScreenCover`, or `.popover`. `ModalPresentation` picks the style: `.sheet` (a UIKit form sheet), `.pageSheet`, `.fullScreen`, `.popover` (anchored to the declaring view), or `.largeViewer(for:)` for documents, refined with `.detents(_:grabber:selected:cornerRadius:)`, `.inNavigation(_:)`, `.arrowDirections(_:)`, and `.keepsPopoverInCompactWidth()` (SwiftUI's presentation modifiers do nothing on a UIKit-presented screen). Popovers paint the theme's popover surface. A screen moves its own sheet with `ScreenNavigator.selectSheetDetent(_:)`, the selection half of `presentationDetents(_:selection:)`. A side panel that was an `.inspector` is a `routerTrailingColumn(item:minWidth:idealWidth:content:)` (`Oppi/Features/Review/TrailingSidePanelPolicy.swift`): a UIKit-hosted screen in its own navigation controller in a full-height trailing column with a hairline divider, its bar level with the screen's and its content laid out compact, like an iPadOS inspector. It sits on the navigation controller that holds the screen while the screen is on screen, and that controller's safe area makes room for it, so the screen's bar items and content stay beside it; at compact width the caller presents the same panel with `routerModal`. The keyboard spans the window, so while the column is up the screen follows it only for its own inputs; a field in the panel (Outline search) leaves the chat's composer where it is. A UIKit screen shows a column itself: it adds a `TrailingColumnController(screen:)` as a child, calls `show(_:root:)` with a `RouterScreen`, and conforms to `TrailingColumnKeyboardScreen`, whose `followsKeyboard` the column turns off while a panel field has the keyboard (the chat). A UIKit screen presents router modals with a `RouterModalPresenter` per slot anchored to itself, setting each slot's request from its state in `updateProperties()`; the slot keeps the same `.sheet(item:)` contract. Chat's side panels (Outline, Files, Context) take the column in regular width (iPad, the Duo's open display) and are router sheets in compact width; in both places they sit at the root of a router navigation controller and push their pages through its navigator. The root of a router modal or column can be a UIKit view controller instead of hosted SwiftUI: `routerModal(item:presentation:onDismiss:screen:)` and `routerTrailingColumn(item:minWidth:idealWidth:screen:)` take a `RouterScreen` (`.hosted` content or `.controller`), and a UIKit root needs `.inNavigation()`, is built once per presentation, and owns its `navigationItem` and `UISearchController` itself. A UIKit root that mirrors presenter state uses `RouterScreen.liveController(_:update:)`: each presenter re-render runs `update` with current values, the way hosted content refreshes (the expanded composer takes the chat's or Quick Session's draft, pills, and busy state this way). Session Outline (`SessionOutlineViewController`) is one, so its search, selection, and close have a single owner. A covered presenter stops rendering, so a modal over a screen whose state it edits through bindings uses `.overFullScreen` rather than `.fullScreen` (chat's Share sheet in regular width, the expanded composer, and the composer pickers). The contract matches SwiftUI `.sheet`: the binding presents and dismisses, a new id replaces the open modal, and `onDismiss` runs after every dismissal, including swipe-down and the screen's own `finish()`. A presentation can follow size classes: when its style or navigation wrapper changes while the modal is up, the router presents the same item again without clearing the binding or running `onDismiss`, and sheet detents change in place. UIKit code presents a SwiftUI screen with `Router.present(presentation:from:content:)`. SwiftUI alerts, confirmation dialogs, and menus inside an existing SwiftUI screen may stay until that screen moves.
2. **New screens and views are UIKit.** Write view controllers and views. Read `@Observable` stores in `updateProperties()` (iOS 26 automatic observation tracking). Use `UICollectionView` list layout with content configurations for lists and settings, `navigationItem` bar items (set `visibilityPriority` and `axisBehavior` where Duo vertical bars matter), `UISheetPresentationController` for sheets, and `UIGlassEffect` for custom glass.

   **Chat composer.** The composer is UIKit, including the action-row pills and their pickers, the Ask card, and the expanded composer (`ExpandedComposerViewController`); its bar is `ComposerBarController`, and the decisions it makes (what shows, the placeholder, the primary action, Ask paging) are `ComposerPolicy`. Every screen embeds it through `ChatComposerOwner` (`Oppi/Features/Chat/Composer/ChatComposerOwner.swift`), a child controller that owns `ComposerBarController`, the dictation-failure notice, the busy-mode tip, inline voice, focus and dictation requests, and the expanded composer, and reads the screen's draft and session state from a `ChatComposerSource` in its own `updateProperties()`; the owner measures the bar itself when its height changes (focus, the Ask slot, the busy-mode tip). The chat is one source. Quick Session (`QuickSessionViewController`, its state in `QuickSessionModel`) is the second `ChatComposerSource` on the same owner. The guided control-session composer (`GuidedControlComposerController`, its state and atomic launch in `GuidedControlComposerModel`) is another `ChatComposerSource` on the same owner: Agents, Schedules, and Custom Themes pin it above the keyboard, and the guided sheet (`GuidedControlSessionViewController`) holds it. The guided sheet is what Agents, Schedules, Custom Themes, the reviewable control Markdown screen (`ReviewableControlMarkdownViewController`, which passes its staged review comments), and the chat's Context panel (Edit with Oppi on an extension) present. No SwiftUI screen embeds the composer. The SSH terminal embeds `ComposerBarController` directly in a terminal configuration; one UIKit key-strip view serves the chat bar and the raw-keyboard accessory. The Ask card (`AskCardViewController`) sits in the composer's Ask slot at its natural height, capped; its rows scroll inside the card while Send / Ignore stay in its footer. Its expanded sheet and the expanded composer are UIKit view controllers presented through the router; the extension editor dialog is the expanded composer in an editor configuration. Presentations from the composer go through the router or UIKit, never SwiftUI `.sheet`. Suggestion lists are a UIKit collection view fed by `FileSuggestionRanker` / `ComposerAutocomplete.slashSuggestions`; the view does not re-rank.
3. **Touched SwiftUI moves to UIKit.** Work that changes an existing iOS SwiftUI screen moves that screen to UIKit in the same work item, with behavior and accessibility-identifier parity; the commit says so. Convert the whole screen, not the one view the work changes: a UIKit view inside a SwiftUI screen adds a bridge, the split brain this rule removes. A SwiftUI leaf hosted inside a UIKit screen (a hosted cell, panel, or bar) converts on its own, since that removes a seam. UIKit gives the control and measurement fast surfaces need; the target is UIKit everywhere except rule 5. Untouched SwiftUI may wait for the next work that touches it.
4. **SwiftUI shown from UIKit goes through `HostFactory`.** `OppiApp` publishes the app-scoped services (`ConnectionCoordinator`, `AppNavigation`, `ServerStore`, theme, the active server's scoped stores, the saved row appearance) as one `AppRootEnvironment` (`Oppi/App/AppRootEnvironment.swift`). Every member is a store, so the root never changes and a screen that captured it when pushed stays current; a value member (the row appearance once was) went stale in pushed screens. The scene sets it as a UIKit trait on its window, so UIKit code anywhere in the window, presented controllers included, finds it with `HostFactory.root(near:)`; a preview with its own fixture root publishes that one with `publishesAppRootToWindow`. The SwiftUI value is a plain environment value; a trait-bridged value read nil inside `NavigationStack` destinations. `HostFactory.screen` hosts a screen with that root applied through `appRootEnvironment(_:)`, a `ScreenNavigator`, its `ScreenBars` (a large title, inline on the Duo's vertical rail where a large one showed nothing; the toolbar while the screen has `.bottomBar` items), and the theme's color scheme (`overrideUserInterfaceStyle`) and page background, behind content that leaves it bare. `HostFactory.content(_:root:)` hosts SwiftUI embedded in a UIKit view, and `HostFactory.leaf(_:root:)` does the same at the content's natural height for the width it gets (the chat's context bar and footer rows); both require the root, passed explicitly from the embedding representable's environment or found with `root(near:)` once the view is in a window; embedded hosts are often not child controllers, so they cannot count on inheriting it. Only the App Lock cover, which paints before the root exists, uses `HostFactory.appLockCover`. Debug harnesses and screenshot previews get the app root at the window (`OppiApp.makeRootViewController` hosts them with `HostFactory.content`). Never call `UIHostingController(` directly or hand-write an environment list at a hosting seam. Presenter-local values go on the content explicitly and override the root's, for example `withServerScopedEnvironment(connection)` for a chat's own server. Required `@Environment(Type.self)` lookups that were missing across a UIKit↔SwiftUI seam caused two crashes: build 54 on the iOS app on Mac, where SwiftUI's sheet environment bridge dropped `ConnectionCoordinator` (`0ffdb2e5b`), and the file viewer (`06d79f50c`). A sheet that reads those services uses `routerModal`, not SwiftUI `.sheet`, with the presenter-local values passed explicitly: the chat puts its server scope, API client, reducer stores, and navigation on every leaf, modal, and side panel (`ChatViewController.leafScope`), and its leaves push and present through `ScreenNavigator.forUIKitScreen(_:root:)`, and review screens forward theirs to what they push or present (`presenterScope(connection:apiClient:navigation:)`).

   **Hosted screens never navigate or present by themselves.** In a UIKit stack, a page pushed by `NavigationLink { destination }` loses the app environment and crashes on its first required service read, value links and `navigationDestination` do nothing, `.searchable` never reaches the UIKit bar, and `dismiss()` does nothing at the root of a presented navigation controller. A hosted screen reads `@Environment(\.screenNavigator)` and calls `present(_:onDismiss:content:)`, `push(bars:content:)`, `push(_ screen:)` for a UIKit view controller (the SSH terminal), or `finish()`, declares `routerModal`, and searches with `routerSearchable(text:prompt:)` (the host owns a `UISearchController` bound to the text both ways; the screen needs a navigation controller). Outcomes are the screen's own typed closures; after reporting one the screen calls `finish()`, which pops a pushed screen or dismisses the modal it is the root of. A modal dismissed under an active search left its bar on screen, still taking taps, so the router ends the search first: in `finish()`, on swipe-down, and when a trailing column’s panel goes away. Presenter-local values a modal needs go on its content explicitly; the model pickers in Edit Agent and Edit Schedule get the editor's `apiClient` and `chatState`, and the chat commit viewer gets its own `AppNavigation` so a chat opened inside it cannot take the app's pending quick-session message. Two `routerSearchable` views that swap inside one screen share its bar: the newest drives it and the bar stays until the last one leaves, since SwiftUI can still update the old view after it adds the new one.

   **Every hosted screen is its own SwiftUI graph.** SwiftUI stops updating a screen whose view left the window: covered by a push or by a `.fullScreen` modal. So a `@Binding` into the presenter's `@State` does not refresh a pushed screen, and clearing a presenter binding while the presenter is covered does nothing. `push` and `present` take a content closure that runs in the new screen's graph, so `@Observable` reads in it stay live. State that two screens edit belongs in an `@Observable` model (see `AgentNativeEditDraft`, which the UIKit Edit Agent screen and the SwiftUI selection pages it pushes share). `routerModal` content also refreshes when the presenter re-renders, which happens while the presenter stays in the window (sheets, popovers, `.overFullScreen`). A `routerModal` presents on the next main-queue turn, after the presenter's SwiftUI update: a hosting controller created inside another SwiftUI update joins that graph, and its title and bar items showed in the enclosing stack's bar while its own bar stayed empty. A `routerModal` presents only while the view that declares it is in the window, so a modal a pushed page can trigger is declared on that page too: MCP sign-in starts on a server's detail page, which covers the list, and both declare `mcpSignInModal`. A modifier applied outside the view that carries `appRootEnvironment` passes the root itself (`PairingApprovalPromptHost(root:)`). A router presentation ignores the content's SwiftUI presentation modifiers (`presentationDetents`, `presentationCompactAdaptation`); the presenter passes the presentation instead, and content several presenters show keeps it next to the content, as `ModalPresentation.iconPicker(horizontalSizeClass:verticalSizeClass:)` does for `UnifiedIconPickerView`. `interactiveDismissDisabled` already reaches UIKit, including through the router's navigation container.

   **No screen brings its own SwiftUI navigation.** A modal that needs a bar presents with `.inNavigation()`, closes with `finish()` instead of `dismiss()`, and opens every page with `navigator.push` (a `SettingsIndexActionRow` keeps the disclosure chevron). Debug previews and UI-test harnesses follow the same rules, so they exercise the app's path: `RouterPreviewStack(root:content:)` hosts a screen at the root of a router navigation controller over a preview's own app root, and `RouterPreviewNavigation` does the same over the window's root, with the theme's color scheme, which the app puts on its window and window-level chrome such as the Duo's vertical rail reads. A preview nothing launches (no `SCREENSHOT_SCREEN` case reached by a UI test, script, or doc) is deleted, not converted; `scripts/screenshot-screen-guard.ts` fails when a test launches a screen no case serves.
   **The shell.** A UIKit scene (`SceneDelegate`, `Oppi/App/AppDelegate.swift`) owns the window; `OppiApp` holds the services and the app-wide handlers (URLs, notification and Siri opens, resource and file links, scene phases, launch). `AppRootViewController` applies the theme to the window and shows the launch backdrop, onboarding, or the workspace shell, above the SwiftUI `AppRootLayer` (app-wide modals, workspace creation the shell starts). Quick Session is a UIKit controller (`QuickSessionViewController`) that `QuickSessionPresentation` mounts above the content while `AppNavigation.showQuickSession` is set: it presents `QuickSessionTrigger` requests once the shell is up, makes the content under it inert to touch and VoiceOver, and on dismissal opens the session a launch created and returns VoiceOver focus to the control that opened it. Its workspace and worktree pickers are UIKit popovers on their pills; the model picker is the shared UIKit `ModelPickerViewController` (the chat, Guided Control, and the Agent and Schedule editors present it too, with the presenter's server passed in; it owns its bar and `UISearchController`). `WorkspaceShellController` measures the window and mounts the compact stack with its workspace drawer or a `UISplitViewController`: a fold or resize first converts `AppNavigation`'s routes for the new layout, then mounts it from them, so the stacks rebuild where the user was. `AppNavigation` is the single source of truth for every stack. `ShellNavigationController` (`Oppi/App/ShellRouter.swift`) shows exactly the routes it is given, keeps the screens that stay, and reports the user's pops back (`popWorkspaceStack(toDepth:)`, `popSplitDetail(toDepth:)`). `ShellRouteScreens` (`Oppi/App/WorkspaceShellRoutes.swift`) makes each route's screen: All Sessions (`SessionInboxViewController`), the workspace sidebar (`WorkspaceSidebarViewController`, also the compact drawer), a workspace's sessions (`WorkspaceDetailViewController`), a session (`ChatRouteViewController`: its lock gate and server connection, then `ChatViewController`), Files (`FileBrowserViewController`: its lock gate and server connection, then a folder's list, or in regular width the folder tree beside the open file), a linked file (`WorkspaceLinkedFileViewController`: its lock gate and server connection, then the file viewer `FileViewerViewController`), a Skill file (`ServerSkillFileViewController`), SSH Terminal's host list (`SSHTerminalHostListViewController`), Schedules (`ScheduleListViewController`), and Agents (`AgentListViewController`) are UIKit controllers mounted directly, which take a refreshed route through `ShellRouteScreens.update` without being rebuilt; every other route is a `ShellRouteView` hosted with `HostFactory.screen`. The two session lists (All Sessions and a workspace's sessions) share their UIKit pieces (`SessionListCollection.swift`: row values, swipes and long-press menu, alerts, section headers, bar items) and host the SwiftUI session row per cell. A screen opens a route by calling `AppNavigation` (`openWorkspace`, `openWorkspaceSession`, `openWorkspaceFileBrowser`, ...). A page that exists only above the screen that opened it (a fork, a quick-action chat, a host file, an agent's or schedule's detail, the SSH terminal) pushes with `ScreenNavigator.push` and stays above that screen until a route below it changes; a push asked for while a pop animates waits for it to finish. A pushed page whose presenter must react to it closing reports that itself: the SSH terminal clears `showsTerminal` when it leaves and pops itself when the session stops showing it, and Pi's Tools page saves through the observable model it edits when it closes. `finish()` at the split detail root shows the column's list. Every route is hosted directly in its UIKit stack, with the UIKit bar and back swipe.

5. **SwiftUI only where Apple requires it.** That means widgets, control widgets, and Live Activities (`OppiControlWidget`, `OppiActivityExtension`).

**Mac (`clients/apple/OppiMac`)**

New Mac views are AppKit by default. Existing SwiftUI Mac code stays until a separate migration decision. The AGENTS.md rule still holds: a feature does not touch the Mac app unless the request names Mac, macOS, desktop, or OppiMac.

**OppiCore** stays UI-framework-free.

**Structure guard.** `scripts/uikit-structure-guard.ts` scans `clients/apple/Oppi/**/*.swift` after stripping comments and string literals. `NavigationStack`, `NavigationSplitView`, `NavigationLink`, `.navigationDestination(`, `.sheet(`, `.fullScreenCover(`, `.popover(`, `.inspector(`, `UIHostingController(`, and `UIHostingController<` (a subclass or stored type) are disallowed in every file, previews and harnesses included; the only exception is `HostFactory.swift`'s two hosting controllers (`HostedScreenController`, `HostedContentController`), a commented entry in the guard's `allowed` list, and another would need Chen's approval. `import SwiftUI` is a ratchet: a file fails when its count exceeds `scripts/uikit-structure-baseline.json`; new files have baseline 0 and decreases pass. Lowering the baseline after a migration is expected: run `bun scripts/uikit-structure-guard.ts --update` and commit the reduced baseline with the migration. Renaming or moving a file keeps its count, so `--update` after a rename is fine when the baseline diff only moves entries. Ordinary runs never write the baseline.

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
- iOS content web links use `MarkdownLinkInteractionSupport` or `.webLinkTapped`; `OppiApp` applies the browser preference. Direct system opens are limited to that owner and allowlisted non-HTTP fallbacks. Only that owner and Tailnet authentication may present `InAppBrowserPresenter` directly. Timeline `UITextViewDelegate` conformances must implement `primaryActionFor` in the same file.
- Generic extension UI rendering and routing must not branch on concrete tool names, extension names, status keys, widget keys, or display names. Add semantic protocol metadata at the producer boundary instead. This includes `ExtensionSurfacePanel.swift` and `MacExtensionSurfacePanel.swift`.
- SwiftUI foreground, fill, and stroke styling must use the environment-resolved `.theme*` `ShapeStyle` shorthand. `Color.theme*` is a runtime snapshot for APIs that require a concrete `Color` or a UIKit/AppKit bridge. Persistent list and panel modifiers must read `theme` or `themeID` from the environment so mounted content repaints after a theme switch. `scripts/theme-surface-guard.ts` enforces the shorthand boundary during the iOS architecture check.
- iOS SwiftUI navigation and presentation constructs (`NavigationStack`, `NavigationSplitView`, `NavigationLink`, `.navigationDestination(`, `.sheet(`, `.fullScreenCover(`, `.popover(`, `.inspector(`, `UIHostingController(`, `UIHostingController<`) are disallowed under `clients/apple/Oppi`, and `import SwiftUI` may not exceed the per-file counts in `scripts/uikit-structure-baseline.json` (new files start at 0). `scripts/uikit-structure-guard.ts` enforces both during the iOS architecture check, and `scripts/screenshot-screen-guard.ts` checks that every `SCREENSHOT_SCREEN` a UI or E2E test launches has a preview case; see [UIKit and SwiftUI ownership](#uikit-and-swiftui-ownership).
