# Oppi client architecture

The Apple clients render and control server-owned and terminal-owned Pi sessions: they send commands and render the server's projection, never execute Pi sessions or mutate server read models. Workspace navigation is HTTP-first; WebSockets carry only live streams. iOS paints with UIKit over HTTPS/WSS; Mac paints with AppKit and existing SwiftUI over the owner Unix socket, on the same `ChatSessionManager` and reducers ([Mac adapter path](architecture-client/blocks.md#mac-adapter-path)). Server: [Server architecture](architecture-server.md); routes: [Networking](networking.md).

## Detail map

| Page | Covers |
| --- | --- |
| [Client blocks and shared core](architecture-client/blocks.md) | Block owners, stores, focused session, extension UI, tool inspection, Mac adapter path |
| [Media, files, and sharing](architecture-client/media-files.md) | Content access, current-file routes, file editing, Quick Session intake |
| [Renderer change map](architecture-client/change-map.md) | Adding a document renderer; cleanup targets |
| [Where to look in code](architecture-client/code-map.md) | File pointers by area |
| [Durable conversation stream](architecture-server/durable-conversation-stream.md#apple-client) | The client replica of a durable conversation |

`ServerConnection` is the facade and cross-store workflow owner; each state machine inside it has its own owner:

- `PairingApprovalList`: one server's pending pairing approvals, fencing stale list reads; `PairingApprovalController` presents them across connections.
- `SessionUsageMetricsReporter`: sends `AppSessionUsage` once per changed session snapshot; forgets a session with its stream.
- `ExtensionDialogQueue`: each session's sheet-backed extension dialogs (the first is `activeExtensionDialog`); `extensionToast` stays on the connection.
- `AppEventListRepair`: one app-event window's list-repair slot, epoch fence, and single follow-up budget; `ServerConnection+Refresh` runs what it decides.
- `ServerRouteController` (`connection.route`): candidates, LAN promotion and demotion, Tailnet rebuilds, transport generations, recovery; the connection installs what it commits through `ServerRouteHost`.
- `FocusedSessionStreamBinder`: the focused-session stream binding (endpoint, parked frames, external-open claim, recovery owner, deferred playback disconnects).

## UIKit and SwiftUI ownership

UIKit owns every iOS view and all app structure; `scripts/uikit-structure-guard.ts` enforces that ownership and the rules below ([Structure guard](#structure-guard)).

### Rules (iOS, `clients/apple/Oppi`)

1. **Every iOS view is UIKit.** Read `@Observable` stores in `updateProperties()`. Lists and settings use `UICollectionView` list layout with content configurations; bars use `navigationItem` items (`visibilityPriority`, `axisBehavior` where the Duo's vertical bars matter); sheets `UISheetPresentationController`; custom glass `UIGlassEffect`.
2. **SwiftUI is a framework leaf, never a screen:** a file that has to draw Swift Charts, a `RealityView`, or a tip keeps its SwiftUI values and their one UIKit host in that same file, and no other file hosts SwiftUI.
3. **One router presents and pushes.** `AppNavigation` drives the window, split view, stacks, and every sheet, cover, popover, and side panel through `Oppi/App/Router.swift`. Screens use `Router.present`/`Router.push` (theme and app-root trait come from the presenter) or a `RouterModalPresenter` slot set in `updateProperties()`; `ModalPresentation` picks the style. An iPad side panel is a `TrailingColumnController` column in regular width and a router sheet in compact. A modal root that mirrors presenter state uses `RouterScreen.liveController(_:update:)`.
4. **Reuse the [shared building blocks](#shared-uikit-building-blocks)** before writing one.
5. **A list cell that changes its own layout re-measures:** session lists set `selfSizingInvalidation = .enabledIncludingConstraints` and a rearranging row invalidates its intrinsic size, or lines overlap.
6. **SwiftUI only where Apple requires it:** widgets, control widgets, Live Activities (`OppiControlWidget`, `OppiActivityExtension`), App Intents UI.
7. **A file imports SwiftUI only if the guard's `swiftUIImporters` names it, with a reason** ([the SwiftUI allow-list](#the-swiftui-allow-list)); `import Charts`, `import TipKit`, and `import struct SwiftUI.X` count too, and a new entry needs Chen's approval.
8. **Observe notifications with a block on the main queue:** a `@MainActor` type uses `addObserver(forName:object:queue: .main)`, keeps the token, and removes it in `isolated deinit` or when it leaves; selector observers trap when the poster is off the main thread (`bd3b2b5d4`, `415f62e75`).

### Shared UIKit building blocks

- `EntityIcon` (`Core/Views/EntityIcon.swift`) is the one owner of entity artwork (Agent, Pi, workspace with sandbox mark, provider, model, server); `UIAction.choice(title, entity, selected:, assets:)` is the menu row carrying it. Loaded artwork (Genmoji) posts `.oppiEntityIconDidLoad`: rows key on `EntityIcon.loadGeneration` and menus build rows when they open (`UIDeferredMenuElement`), so an arrival never rebuilds an open menu. The guard counts entity artwork built elsewhere (`providerLogoAssetName(`, `providerMonogram(`, `resolvedBadgeIcon.symbolName`, entity-named `UIAction(title:)`).
- One helper each: `UIFont.scaled`/`scaledMonospaced`/`UIImage.scaledSymbol` (Dynamic Type), `WorkingSpinnerUIView` (every spinner), `JumpToBottomButton`, `InsetLabel` (pills and badges), `PlainRowButton`/`ChangedFileRow`, `TerminalMirrorIndicatorUIView`, `IconChoiceUIView`, `IconPickerViewController` (state in `IconPickerModel`), `FloatingProgressPanel`, `WorkspaceQuickActionLauncher`.
- `HostSwitcherModel` owns the server list, connection retry, and switching; `ServerSwitchMenu` (`Features/Servers/HostSwitcher.swift`) owns every menu that lists servers (`UIAction.choice(.server)` rows read when the menu opens; a gated server shows its lock and a choice passes `ScopedLockService.gate` before activation). Catalog lists reuse it (`ServerCatalogServerRowCell`, `ServerCatalogServerMenu`).
- `ChangedRows` (`SettingsStyle.swift`) reconfigures only rows whose inputs changed, so an open menu survives an unrelated pass.
- Settings kit: [Settings pages](#settings-pages). `ListScreen` keeps the row builders (`buttonRow`, `staticRow`, `stateRow`, `background`, `setBarItems`); `SettingsSelectionRowCell`, `SettingsTextViewRowCell`, and `Workspace*Cell` are kit rows. `ServerResourceDetailScreenController` (`Features/Skills`) is the shared Skill/extension page; its detail answer outranks the catalog row until a mutation settles.
- `ThemeGalleryViewController` draws `ThemeID.palette`: built-ins are contrast-resolved (`ThemeContrast.resolve`); a custom theme keeps its JSON colours.
- `SessionListCollection` and `SessionListBottomBar` are both session lists' collection, rows, swipes, menus, search, and bottom bar; `SessionRowView` is the one row view. Lists build launch-tree threads with `SessionListEntries`, group with `SessionInboxGrouping`, and configure rows with `SessionListEntryConfiguration`; there is no thread screen or route.
- `FullScreenCodeViewController` is the one full-screen document reader and owns its chrome. Each `FullScreenCodeContent` case answers what to show in `Core/Views/Reader/FullScreenCodeContent+Reader.swift` and each body answers through `ReaderBody`, so the controller has no per-kind `switch`; a new kind or body adds its answers there, one file per body in `Core/Views/Reader/` (the Markdown body stays in `FullScreenCodeBodies.swift`).
- `ReaderTrace` is the one live-trace type: the reader holds one observation per installed body (`ReaderBodyContext.follow`), never the body, and rebuilds the body once the trace outgrows it.
- `ReviewCommentStashFloatingButton` is the one staged-comment button; `ReaderChunkStackLayout` the one layout of virtualized chunk bodies.
- `McpSignInPresenter` presents `McpSignInOwner`'s sheet from whichever MCP screen is in the window, so one sheet is up and it closes with the owner.

### Alerts and confirmations

`Oppi/Core/Views` owns every error alert and confirmation; the guard counts `UIAlertController(` elsewhere.

- `ErrorAlertPresenter` (`UIViewController.errorAlerts`, one per screen): `show` for an event, `sync(title:message:clear:)` from `updateProperties()` for state, `dismiss(onlyWithPrefix:)`. A newer error replaces the shown one, never stacks. An error shows only while its screen is in front (a search controller, alert, or popover over it does not count); otherwise one is held until the screen is uncovered, with no expiry. A screen with nothing to fail (connecting, locked) drops errors. `clear` receives the message read; the owner clears only if its error still equals it.
- `Confirmation` (`ConfirmationSheet.swift`) presents from `Router.topPresenter` with a required `anchor` (the row, or nil); an anchor outside a window centres the popover, so an iPad sheet always has a source. Choice sheets anchor through `AlertAnchor.present`; `TextPrompt` is the one text-field alert.

### Navigation bar

`Oppi/App/Router.swift` alone decides whether a stack's bar is hidden. A screen that draws its own Back and actions conforms to `NavigationBarHiding`; the stack delegates (`ShellNavigationController`, `RouterNavigationController`) call `applyNavigationBar(forIncoming:animated:)` per incoming screen, which also restores state after a cancelled back swipe. A screen whose answer changes while in front calls `navigationController?.updateNavigationBar(for:animated:)` (acts only on the top screen). An embedding screen does not conform; the policy asks its children. The guard disallows `setNavigationBarHidden(` except in `FullScreenCodeViewController` (its private navigation controller).

### Load states

`Oppi/Core/Views/LoadStateContent.swift` owns every state a screen shows instead of content; the guard counts `UIContentUnavailableConfiguration.empty(`/`.loading(`/`.search(` elsewhere (empty baseline).

- A screen holds a `LoadState` (`connecting`, `loading`, `empty`, `noResults`, `failed(retry:)`) and paints it with `UIContentUnavailableConfiguration.loadState(_:palette:background:)` (a region: `UIContentUnavailableView(loadState:)`). `failed` with `retry` shows one "Retry" button (`OfflinePairedServerE2ETests` taps it); `retry: nil` shows none.
- A content-unavailable button cannot carry an identifier: put scoped ids on the view, query Retry inside it, and carry the state kind in `accessibilityValue`. A controller's own `contentUnavailableConfiguration` has no view a test can hold, so a screen with an agent-facing failure hosts its own `UIContentUnavailableView`.
- A list states itself in a row (`ListSection.state`/`ListStateRow`, `SettingsStateRowCell`). A `ListScreenController` page never writes its own loading, failed, or empty row: it names `stateSection()` and `emptyState()` and the base picks; a store-backed page uses `stateRow(hasContent:isLoading:failure:)`. A page with no rows is its state (`wholeScreenState()`), never both.

### The SwiftUI allow-list

- `swiftUIImporters` names exactly five files the app target compiles, the whole of SwiftUI in the iOS app. The framework leaves are `UsageCharts.swift` and `USDZRealityCanvas.swift`: values only, no `@Environment` or app service, and `UsageChartLeafHost` and `USDZRealityCanvasHost` are the only `UIHostingController`s in the app. `FeatureEducationTips.swift` holds the TipKit tips, whose `Text`/`Image` need SwiftUI while their display is UIKit. `Shared/Theme/ModelColorHelpers.swift` holds the shared `StatsDailyChart`, the model colors, and the contrast rules its labels use: a model color is a `ThemeColor` too, and a SwiftUI leaf draws one with `viewColor(_:)`. `Shared/Activity/LiveActivityPresentation.swift` is the Live Activity surface, shared with the widget extension. `Shared/Theme/ModelStatsValues.swift` (model identity, aggregations, provider labels) imports neither SwiftUI nor Charts.
- `sharedMacOnlySwiftUI` names the Mac-only `ThinkingOrbAcknowledgmentsView.swift` and `Shared/Renderers/Orbs/OrbView.swift` (the orb's SwiftUI wrapper; excluded from `Oppi` in `project.yml`; the two lists move together). `OrbMetalView.swift` is a UIKit/AppKit view on both platforms.

### App services

`OppiApp` publishes services as one `AppRootEnvironment` window trait (`window.traitOverrides.appRootEnvironment`, found with `AppRootEnvironment.near(_:)`); a controller embedding one server's page sets the trait on itself. The app has no SwiftUI environment value for it; never hand-write an environment list around a leaf: pass values. The App Lock cover (`AppLockCoverViewController`) paints before the root exists, so it reads only `ThemeRuntimeState` and `AppLockService`.

### Presentation gotchas

- A modal that edits presenter state uses `.overFullScreen`: a `.fullScreen` cover stops the presenter rendering.
- A `RouterModalPresenter` presents a run-loop turn late and only while its anchor is in the window; its owner clears state in `clear:` (runs after every dismissal, swipe-down included), not `onDismiss`.
- Search bars outlive their modal unless ended: `Router.endSearch` runs on `finish()`, swipe-down, and trailing-column removal. A screen that searches installs `ScreenSearchController` on its own navigation item.
- A preview nothing launches is deleted, not converted; a root preview uses `PreviewHost.screenStack`. `scripts/screenshot-screen-guard.ts` fails when a test launches a screen no preview case serves.

### Structure guard

`scripts/uikit-structure-guard.ts` scans `Oppi`, `OppiDebugHarness`, `OppiCore`, and `Shared` with comments and strings stripped. SwiftUI navigation and presentation constructs and `UIHostingController` are disallowed outside its commented `allowed` list (the two leaf hosts); another exception needs Chen's approval. The Debug-only harness is UIKit too: a harness or preview is a controller that `DebugHarnessLaunch` routes. The other ratchets (settings theming and writes, alerts, load states, entity artwork, page loads) count per file against `scripts/uikit-structure-baseline.json`: new files start at 0, decreases pass, a settings page that moves onto the kit commits the lowered baseline from `--update`, a rename keeps its count, and ordinary runs never write it.

**Mac (`clients/apple/OppiMac`):** new views are AppKit; existing SwiftUI stays until a separate decision.

## The shell

- `SceneDelegate` owns the window. Every open (URLs, notifications, Siri and controls, links) is one `AppOpenRequest` to the window's `AppOpener`, which waits for App Lock, launch, a scoped lock, and the target server before driving `AppNavigation`.
- `AppRootViewController` applies the theme, shows launch backdrop, onboarding, or the shell, and keeps routes through AVKit fullscreen (`WorkspaceMediaOverlayObserver`). App-wide modals are router slots (`AppRootModals`). The extension-dialog slot's id names the connection, so a server switch closes another server's dialog without answering it; `ExtensionDialogFallbackViewController` cannot be swiped away (Cancel answers). What's New covers the root full-screen and closes itself with `Router.finish`.
- `WorkspaceCreationIntake` handles shell-started creation (`oppi://workspace`, the guided first workspace), re-running per active server and cancelling the previous run. `PairingApprovalPresentation` presents from `AppRootViewController.updateProperties()`; `approve`/`deny` take the presented request's id and never sign an expired request.
- `AppNavigation` is the single source of truth for every stack; its route metadata carries `serverId`, so stack/split transitions never request the wrong server. `WorkspaceShellController` converts routes for a fold or resize, then mounts the new layout. `ShellNavigationController` (`ShellRouter.swift`) shows exactly the routes it is given and reports user pops. `ShellRouteScreens` builds screens with an exhaustive `switch` over `ShellRoute` and updates them without rebuilding.
- A screen opens a route through `AppNavigation`. A page that exists only above its opener (fork, host file, agent detail, SSH terminal) uses `Router.push`; a push during a pop animation waits. A pushed page whose presenter must react to its closing reports that itself. `finish()` at the split detail root shows the column's list.
- `PinnedServerRouteViewController` pins a page to one server (`ServerSelection.resolveVisible`). Server Settings' store, model, and closures never follow a switch: a switch closes only pages that page pushed, never a routed screen above, and a late response settles into the old page. The route tracks the selection itself because a hidden view's `updateProperties()` does not run.
- View-driven refreshes target the selected server, so an unavailable inactive server cannot delay the inbox. Sidebar workspace counts come only from server state for live sessions: stopped sessions never count, and opening a session on the device changes nothing and reads no Pi JSONL file.
- Incognito: `ChatViewController` deletes the session once `AppNavigation.routeContainsSession` no longer finds it (`IncognitoSessionEnd`); UIKit's moving flags miss shell route swaps and count the lock cover as a removal.
- Quick Session (`QuickSessionViewController`, `QuickSessionModel`) mounts above content while `AppNavigation.showQuickSession` is set and makes the content inert. `ModelPickerViewController` is the one model picker.

## Chat composer

`ComposerBarController` is the bar and `ComposerPolicy` its decisions. Screens embed it through `ChatComposerOwner` (bar, dictation notice, busy tip, inline voice, focus, expanded composer), fed a `ChatComposerSource` read in `updateProperties()`: the chat, Quick Session, and `GuidedControlComposerController`. The SSH terminal embeds `ComposerBarController` directly. The Ask card (`AskCardViewController`) keeps Send/Ignore in its footer and clips the question so every option stays visible. Suggestions arrive ranked (`FileSuggestionRanker`, `ComposerAutocomplete.slashSuggestions`); the view does not re-rank.

**Guided control sessions** (`GuidedControlComposerController`, `GuidedControlSessionViewController`): opening, reading, and typing create nothing. Send posts one idempotent control-session creation whose request and comment snapshots are frozen for its key; retries resend those exact fields; success clears only comments byte-identical to the sent snapshot and takes a fresh key; a preflight failure keeps text and comments. Skill drafts key by opaque Skill id. Workspace Settings never shows the composer under the lock cover, and a send in flight when the lock engages opens nothing.

## Live Voice calls

- `LiveVoiceCallCenter` (`Features/LiveVoice/`, `AppRootEnvironment.liveVoiceCalls`) owns at most one `LiveVoiceCallController`, keyed by server and session. A call belongs to the app, not a chat: only End, the server, or a dead link end it, and removing a server ends its call. `callStart(serverId:sessionId:)` is the one new-call policy and `startCall` the one start (a second start is refused); `placeCall` never takes over a live call.
- The call's WebSocket (`ServerConnection.makeLiveVoiceWebSocketClient`) is untracked by the connection, so focus changes and server switches leave it alone.
- A live or starting call owns the microphone app-wide (`ownsMicrophone`): no dictation, composer mic, or read-aloud.
- `LiveVoiceSystemCall` owns the one `CXProvider`. CallKit gets only the session title ("Live Voice" under a scoped lock), and a refused CallKit never fails the call. Audio runs only while CallKit has the session active; the app never calls `setActive`.
- Barge-in is local first (`LiveVoiceBargeInDetector`); server side: [Barge-in](architecture-server.md#barge-in).
- `WorkspaceShellController` owns the one call strip; `LiveVoiceCallStripContent.make` decides its content.

## AI sharing consent

`AISharingConsent` (`Shared/AIConsent`, also in the Share extension) is the one owner of this device's permission to send content through a server to an AI service (App Review 5.1.2(i)). Every send path asks `decide(_:serverId:canAsk:)` first, never a second store; Siri/Shortcuts and the Share extension pass `canAsk: false`, and removing a server drops its grants.

## Document editing

`DocumentEditOwner` (`Oppi/Features/DocumentEditing`) is the one owner of a document's edit entry, read, and editor. A reader hands it a `DocumentEditSubject` and shows its `barItems`; a reader never builds, presents, or dismisses an edit control.

- **Pencil** only when the subject resolves to an edit identity (never a host or session origin), the server advertises that owner's editing (`ServerInfo.workspaceFileEditing`, `skillFileEditing`, `piFileEditing`) or a record's route answers, and the read is tagged exact UTF-8 within `maxBytes`. A surviving edit session is also enough (a deleted file's draft). Edit with Session lives in the "…" menu.
- `read()` is the only tagged read, so the editor's base is exactly what the reader shows. `begin()` bumps a generation a stale read checks after each await. `begin()` and `finishEditing()` hand the buffer back before the page goes, or the session reads a freed text view.
- Saves go through `WorkspaceFileEditSession` and the `WorkspaceFileWriteOutcome` contract; other documents plug in a `WorkspaceFileEditTransport` (prompts: `PromptEditTransports.swift`, record `version` as the tag, `PATCH ?expectedVersion=`). Native forms send their `version` and show `RecordVersionConflict.message` on 409.
- A creatable missing file (`X-Oppi-Creatable: 1`) gets a `.absent` base seeded with `creatableSeedText`; its first save sends `If-None-Match: *`, so another writer's file is a conflict, never overwritten. Untouched seed text is not an edit.
- **Auto-Save is one setting** (`CodeEditorPreferences.autoSaves`, `SettingsCatalog.autoSave`) for every document; no origin has its own policy. Every write passes `WorkspaceFileEditSession.send(bytes:generation:condition:origin:)`: `.automatic` runs only with Auto-Save on, `.confirmed` always. With it off, `hasUnconfirmedChanges` gates Done with a `Confirmation`. Settings writes post `.codeEditorAutoSaveDidChange`, because a stored write redraws no screen.
- `ServerSkillFilePresentation.editable` decides whether a Skill file is editable (never a package Skill or symlink); `SkillFileViewController` resolves its Skill by path, never name. A Skill's file list comes from the loaded detail (`ServerResourceStore.skillDetail`), never a catalog rebuild. An extension is editable only as a single user-owned file (`ServerExtensionListPresentation.editablePath`).
- `WorkspaceFileEditPath` maps a session-reported path to the workspace path, refusing a session worktree's absolute paths and anything outside the mount. `ChatReaderViewController` owns a tool row's edit entry, re-applies `barItems` once after its read, and closes the editor through `endEditing()`; a row opened while its output streams has no pencil.
- `scripts/document-edit-guard.ts` fails editing types, capability reads, and pencil symbols outside `Features/DocumentEditing/` unless an allowlist entry gives a reason; it runs with the architecture check and in the pre-push Apple lane.

## Chat bar

- `ChatBarItems` (`ChatViewController+Bars.swift`) owns the chat bar in both shapes (horizontal bar, Duo rail). `ChatTopBarLayout` comes from `AppPreferences.ChatTopBar`; only the Top Bar page writes a stored layout, so a stored layout is a person's choice and is kept; an action missing from it is appended to `order`, not shown.
- `ChatBarItems.runTopBarAction` is the one owner of what a button does (bar, rail, menu, and accessibility take the same path). `bar(available:)`/`menu(available:)` drop what cannot be offered instead of shifting another button into its place. The "…" menu is built once and resolves through `UIDeferredMenuElement.uncached`, so a bar pass never re-attaches a menu its owner holds.
- An open panel's button shows a selection platter and selected trait: glass draws control content in one colour, so a tint alone is invisible.
- `GitPanelViewController` is the chat's one review surface; Files only browses. `ContextBarScoping` decides scope; touched files with no Git change cannot be selected because quick actions send paths the server checks against Git. `GitStatusStore` owns which checkout a status is for: every Git read (chat, workspace panel, file browser) goes through `status(workspaceId:worktreeId:)`, so another checkout's status never shows, and `isAwaitingStatus` is the one "still loading" rule.

## SSH terminal

- Terminal entries end at `SSHTerminalFolderEntry.open`; `prepare(session:profile:target:)` is the one place a target and profile become a placement. A new multiplexer is one `SSHTerminalMultiplexerKind` case plus one `SSHTerminalMultiplexer` type, never a second flow. Nothing is typed into a running program: `.hostTerminal` runs only CLI calls over the side channel.
- `SSHTerminalRegistry` keys terminals by `SSHTerminalIdentity` (profile, folder; a Rex pane adds its session, never the pane). Editing or deleting a host ends all its terminals.
- **Remote commands:** the folder is never shell code. `SSHTerminalRemoteShell` owns every generated command (its comments say why values travel octal-encoded); a missing folder exits non-zero instead of opening a shell elsewhere.
- **Bar:** `SSHTerminalBarOffer` (`SSHTerminalBarPlacement.swift`) owns what the bar offers (`BarLayout` is shared with Chat). Tap, VoiceOver, and the menu all run `SSHTerminalViewController.perform(_:)`. Nothing branches on an agent name beyond `SSHTerminalAgentDetection.agents`. `SSHTerminalBarContext` hides actions as presentation only (a Herdr terminal's Rex monitor keeps polling).
- **Experiments:** Herdr and Rex are off by default; `AppPreferences.Experiments` is the one answer, read per decision through `SSHTerminalExperimentAccess`. Off hides the buttons, stops polls, and ends Rex terminals (`SSHTerminalRegistry.closeRexTerminals`); toggling needs no relaunch (`AppPreferences.Experiments.didChangeNotification`). Testing: [Gotchas](testing/apple.md#gotchas).
- **Overviews:** Herdr and Rex share `SSHTerminalOverview.swift` (`SSHTerminalOverviewSource` → `SSHTerminalOverviewViewController`); a new overview is one source, one bar action, and one case in `overview(_:)`, never a second sheet.
- **Colours:** `SSHTerminalColorLoader` reads the host's Ghostty config through bounded side commands, parsing only colour keys on device; choices live in `SSHTerminalColorStore` by host id, outside `SSHTerminalProfile`, so a colour change never closes a terminal.

### Rex

- `RexMonitor` subscribes with `session.attach_all` (`RexRemote.swift` says why); one `session.view` runs per session at a time, dropping replies older than the applied revision. Rex has no replay, so catch-up is a full resync.
- Rex's WebSockets are framed client-side (`RexPipeSocket`/`RexWebSocketCodec`) over the SSH bridge (`RexBridge`) or TLS over Tailscale (`RexTLSStream`). `RexRoutePlan` (`RexDirect.swift`) tries direct first and falls back to the bridge; every monitor shares its `RexDirectHost`, so all take one route.
- `RexSessionConnection`: one control connection plus one data connection per live pane (`maximumLivePanes`). `session.attach` and `session.own_block` stay sequential because Rex does not order one connection's requests; switching never calls a focus method. A new pane becomes the shown pane in the same lock as the first view that lists it, so it never opens as an untaken neighbour.
- Ownership: a pane is marked owned before its take is sent; take-back happens only while the page shows with the app active, at most `maximumReclaims` times between user actions, so two clients cannot trade a pane forever.
- `SSHTerminalChannel` keeps one engine per pane; the grid's `presentShownPane` alone sets `presented`, so screen and typing cannot drift apart. Snapshot restore order (READY, FINISH, width) belongs to `RexTerminalStream` and `SSHTerminalEngine`.
- `SSHTerminalRexFollower` owns one Rex host's monitor, sign-in, and background end (`sync(active:)` from `updateProperties()`). `RexMonitor.onFinding` is the one source of what `SSHTerminalRexHostStore` remembers; management never edits the snapshot (events do). A tab follower signs in automatically only when `connectsWithoutPrompt`, reading the store in `viewWillAppear` before `appeared()`, so an edited or deleted host is never signed in from a stale copy.
- Tailnet Rex (`RexTailnet*.swift`) has no sign-in and no side commands (`sideCommandsUnavailable`); discovery rules live in `RexTailnetDiscovery.swift`.

## Settings pages

A UIKit settings page subclasses `ListScreenController` (`Oppi/Features/Settings`), which pins the list at the readable form width and paints it in the theme. The guard counts a hand-built `.insetGrouped` layout in a file that paints the theme's background itself (outside the base and `settingsThemingExceptions`). A page that edits text in place passes `endsAtKeyboard: true` and `dismissesKeyboardOnDrag: true`.

**A page never owns a load task.** It declares `loadPolicy` (`.none`, `.eachAppearance`, `.onceUntilSubjectChanges`), `loadSubject()`, and `load()`, and asks with `setNeedsLoad()`. The base compares the subject every pass; a change cancels the running load, calls `subjectDidChange()`, and reloads, even while covered. A cancelled load is not a failure; `loadTrigger` tells `.appearance` from `.ask`; a page still checks `Task.isCancelled` after its own `await`; a store-owned fetch makes `load()` call the store. The guard counts `override func viewIsAppearing` and `isLoadCancellation` in base subclasses (baseline 0).

### The pieces

- `ListScreenController<Section, Item>`: `listIdentifier` is `<feature>.<page>.list` (`settings.<page>.list` in Settings); `sections()` runs inside `updateProperties()`; a reorder stays in its section (`ListSlot`, `pageItem`); an empty section (no rows, state, header, or footer) is not drawn.
- `ScheduleListViewController` (`Features/Schedules`) uses the kit's cards (`rowStyle` `.card`) with its state row first in the card section, so a failed reload keeps the cards it has.
- A section that is not a list of rows (theme gallery cards, icon picker symbols) is laid out by the page through `layoutSection(for:environment:)`, declaring its boundary header item; the kit still fills the heading from `ListSection.header`.
- `inputs(of:)`: the default key differs every pass, so an unkeyed row cannot go stale. Key rows that hold selectable text, an open `UIMenu`, a switch in flight, or a text field; the theme is in the key.
- Colours come from `SettingsStyle` roles, painted through the base's cell provider (keeping the pressed look); a title is never `.label` or a one-off colour.
- One-control cells (index, menu, action, state) paint their own labels under an overlay `SettingsRowButton`, the only accessibility element, carrying the identifier: XCUITest types a `contentConfiguration` cell as a Cell, so `app.buttons[id]` would miss it.
- Row kinds: Navigate `SettingsIndexRowCell`; Choice `settingChoiceRow`/`SettingsMenuRowCell`; Toggle `settingToggleRow` (else `toggleRow`, which the write guard counts); Action `SettingsActionRowCell`; State `SettingsStateRowCell` ("Retry" is the one retry label); Info `content(.info)`. `SettingsSegmentedRowCell` only where the choice reshapes a live preview on the page.
- `.settingsToggle(reusing:)` keeps one `UISwitch` per cell, so a rollback never leaves a replaced switch on screen.

### Scope and saving

Every page declares its default scope; only a section whose scope differs gets its `SettingsScope` sentence (`SettingsScope.footer`, needs `footers: true`). No badges; always "this device".

A single control saves immediately. Save/Cancel drafts only for fields that validate together or heavy saves, and a draft shows why a save was refused. A server save shows the new value disabled in flight, reverts with the reason on failure, and reloads on 409.

### The catalog and the store

- One place declares a setting: anything shared by more than one page or device is a `SettingDeclaration` in `OppiCore/Settings/SettingsCatalog.swift`; `SettingsCatalogTests` keeps ids and storage unique, and a server-backed declaration must match `protocol/settings.json` (`SettingsCatalogContractTests`).
- `SettingStorage` picks the adapter and scope; only `.device` and `.server` have adapters (others read as unavailable). Scope comes from `storage.scope(serverName:workspaceName:)`, never built by hand. A device declaration reuses the existing `AppPreferenceStore` key and default.
- `SettingsStore` alone validates, saves, rolls back, and reloads. A store has one context for life: the device store (`ConnectionCoordinator.deviceSettings`) or one per server (`ConnectionCoordinator.settings(for:)`, made on first use, dropped on removal), so a result lands only in its server's store; the wrong store is an `assertionFailure`. Use the settled value `set`/`reload` return rather than re-reading after an `await`. Side effects live in `afterWrite` (`liveDevice`, `live`, `liveServerAfterWrite`, which also runs after a conflict reload), never in a page. A `revision_conflict` reloads and says so once; an older document is ignored; writes to one route run in order.
- Adapters reach routes through `SettingsServerTransport` (`APIClient+SettingsTransport.swift`), sending only the changed field with `baseRevision`. A page never calls an `APIClient` settings route or writes a settings key.
- The settings-write guard counts `AppPreferences.*.set…(`, `UserDefaults.standard.set(`, `FontPreferences.set…(`, `settingsApiWrites` calls, `toggleRow(`, and `.settingsToggle(` in `Features/**`. It sees calls by name only: review a new wrapper as a write and add a new settings route's method to `settingsApiWrites`.

### Identifiers and words

New rows use `settings|server|workspace.<page>.<row>` on the row button or control, never the cell; pinned ids and naming rules: [Identifier naming](testing/ios-accessibility-testability.md#identifier-naming).

| Thing | Use | Not |
|---|---|---|
| Paired Oppi server | server | host; computer outside setup |
| Machine before pairing | computer (Set Up a Computer) | |
| SSH saved target | host (SSH only) | |
| Network allow-list | Allowed Hosts | host pattern |
| Oppi folder thing | workspace | project (except Pi project settings, Project Trust) |
| This phone or iPad | this device | this iPhone |
| Pi | only for Pi's own files, versions, settings | a synonym for session or agent |
| Model actor, run | agent, session | |
| Skills, Extensions, MCP Servers | those names | Tools list |
| Dictation phrases | Dictation Dictionary | Dictionary |
| Terminal feature | Terminal | SSH Terminal, SSH Hosts |
| Device key | This Device's Key | This Device's SSH Identity |
| Verbs | Remove = unpair; Delete = destroy; Revoke = end a device's access; Forget = drop local trust | Forget This Workspace for a server delete |

## Timeline

- Readers open through `ChatViewController+Timeline.openTimelineReader` as a `.chatReader` route; a locked origin replaces the page with the lock cover. UIKit configures no off-screen cell, so live readers are fed by `ChatTimelineReaderTraces`, one weakly held trace per open reader; rows own no streams, and a row that leaves the timeline settles its reader.
- Replaying the event ring over a busy session: the replayed `agent_start` marks the running tool interrupted and the replayed `tool_start` revives it; canonically finished calls stay finished.

## Client boundary rules current code

`server/scripts/check-architecture-boundaries.ts` enforces these in server checks (`--scope all`), the iOS build phase (`--scope ios`), and the Mac pre-push gate (`--scope mac`):

- `OppiCore/**` must not import UIKit, AppKit, SwiftUI, ActivityKit, UserNotifications, Speech, AVFoundation, WebKit, or MetricKit; `TimelineReducer.swift` and `DeltaCoalescer.swift` stay platform-neutral.
- `OppiMac/**` must not import UIKit. `project.yml` is the Mac target membership authority: OppiMac compiles `OppiMac/**`, `OppiCore/**`, `Shared/**`, and only the listed `Oppi/**` adapter files.
- `Oppi/Core/Views/**` and `Oppi/Features/Chat/Timeline/**` must not reference `APIClient`, `WebSocketClient`, `ServerConnection`, `ConnectionCoordinator`, `apiClient`, `wsClient`, `SessionStore`, or `WorkspaceStore` (`view-layer-connection-boundary`); they take explicit values (`SessionContentAccess`, icon cache, `openDestination`, `loadOlderPage`) and typed actions, and no forwarding object re-exposes a connection, transport, or store.
- Only `ComposerShared.swift` calls `.stopRecording(`/`.cancelRecording(` (`ios-voice-lifecycle-owner`); it owns keyboard restore, draft rollback, and capture ownership.
- `TimelineReducer.swift` may carry one `cyclomatic_complexity` disable; `ToolPresentationBuilder.swift` and `ToolTimelineRowContent.swift` none (`ios-cyclomatic-disable-budget`).
- `AppleOnDeviceVoiceProvider.swift` calls `setContext(` before `start(inputSequence:` because `SpeechAnalyzer` ignores hints set after analysis starts (`ios-speech-context-before-start`).
- iOS test targets never open files through `#filePath`/`#file`: sim-pool's prefix-mapped cache compiles them to `/^src/...`. Bundle a resource or read `OPPI_SOURCE_ROOT` (`ios-test-no-source-paths`).
- List views read `SessionStore.listProjectionSessions`, never full `SessionStore.sessions` (hot timeline updates change it without changing row data).
- `SessionStore`, `WorkspaceStore`, `ServerResourceStore`, and `OppiCore/Stores/**` must not depend on each other; cross-store work belongs in `ServerConnection` or a small service.
- iOS opens go through `AppOpener` (no NotificationCenter open bus). Only the opener waits for App Lock, launch, and server, applies the browser preference, and system-opens URLs; only it and Tailnet authentication present `InAppBrowserPresenter`. Timeline `UITextViewDelegate` conformances implement `primaryActionFor` in the same file.
- Generic extension UI must not branch on tool, extension, status, widget, or display names (including `ExtensionSurfacePanel.swift`, `MacExtensionSurfacePanel.swift`); add protocol metadata at the producer.
- SwiftUI styling uses the environment-resolved `.theme*` `ShapeStyle`; `Color.theme*` is a snapshot for APIs that need a concrete `Color`. Both ship in `OppiMac` only, where no guard scans them: on iOS a theme token is `ThemeColor` (`UIColor`), so no theme file imports SwiftUI. Persistent list and panel modifiers read `theme`/`themeID` from the environment, or mounted content does not repaint after a theme switch.
- UIKit reads colours from its palette (`palette.ui.*`, `ThemeUIKitPalette` in `Core/Theme/ThemeCatalog.swift`) where it applies its theme, never into a constant; palettes are immutable, so views that re-read in `updateProperties()` repaint on a theme switch. A palette token is already a `UIColor` (`ThemeColor`), so a UIKit call site converts nothing. A translucent colour of its own is `withAlphaComponent`; `multiplyingAlpha` is for a token derived from another token and keeps that token's own alpha.
- Production sources under `Oppi`, `OppiCore`, and `Shared` stay at or under 1,500 lines; bigger files are frozen at their size in `scripts/file-line-budget-baseline.json`, and budgets only go down (`file-line-budget`; tests and the debug harness are reported, not enforced).
- The [structure guard](#structure-guard) and `scripts/screenshot-screen-guard.ts` (every launched `SCREENSHOT_SCREEN` has a preview case) run with this check.
