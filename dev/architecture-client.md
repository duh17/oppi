# Oppi client architecture

> **What belongs here:** owners (which type or module owns what), boundaries (what may depend on what), invariants and rules (with the crash or bug that taught them, in one clause), and the entry points an agent needs to find code. Feature behaviour, UI details, step-by-step flows, and history belong in code comments at the owner and in tests. Standard and budgets: [`dev/README.md`](README.md#what-belongs-in-dev).

The Apple clients render and control server-owned and terminal-owned Pi sessions. Workspace navigation is HTTP-first; WebSockets carry only live streams. iOS paints with UIKit over authenticated HTTPS/WSS; Mac paints with AppKit and existing SwiftUI over the owner Unix socket, on the same `ChatSessionManager` and reducer core ([Mac adapter path](architecture-client/blocks.md#mac-adapter-path)). The client never executes Pi sessions or mutates server read models: it sends commands and renders the server's projection. Server details: [Server architecture](architecture-server.md); route selection: [Networking](networking.md).

## Detail map

| Page | Covers |
| --- | --- |
| [Client blocks and shared core](architecture-client/blocks.md) | Block owners, `OppiCore`, tool inspection, Mac adapter path |
| [Transport and UI flows](architecture-client/flows.md) | Transport lanes, session lists, focused session and durable stream, store updates, extension UI |
| [Media, files, and sharing](architecture-client/media-files.md) | Content access, current-file routes, file editing, Quick Session intake |
| [Renderer change map](architecture-client/change-map.md) | Adding a document renderer; cleanup targets |
| [Where to look in code](architecture-client/code-map.md) | File pointers by area |

`ServerConnection` is the facade and cross-store workflow owner; each state machine inside it has its own owner:

- `PairingApprovalList` holds one server's pending pairing approvals and fences stale list reads; `PairingApprovalController` presents them across connections.
- `SessionUsageMetricsReporter` sends `AppSessionUsage` once per changed session snapshot and forgets a session with its stream.
- `ExtensionDialogQueue` holds each session's sheet-backed extension dialogs, the first being `activeExtensionDialog`; `extensionToast` is an app notice and stays on the connection.
- `AppEventListRepair` holds one app-event window's list-repair owner slot, epoch fence, and single follow-up budget; `ServerConnection+Refresh` runs the refreshes it decides.

## UIKit and SwiftUI ownership

UIKit owns every iOS view and all app structure (decided 2026-10-15). `scripts/uikit-structure-guard.ts` holds the ratchet (see [Structure guard](#structure-guard)).

### Rules (iOS, `clients/apple/Oppi`)

1. **New screens and views are UIKit.** Read `@Observable` stores in `updateProperties()`. Lists and settings use `UICollectionView` list layout with content configurations; bars use `navigationItem` items (set `visibilityPriority` and `axisBehavior` where the Duo's vertical bars matter); sheets use `UISheetPresentationController`; custom glass uses `UIGlassEffect`.
2. **Touched SwiftUI converts whole.** Work that changes a SwiftUI screen moves the whole screen to UIKit in the same work item, with behaviour and accessibility-identifier parity, and the commit says so. Never put a UIKit view inside a SwiftUI screen; a SwiftUI leaf hosted in a UIKit screen converts on its own.
3. **One router presents and pushes.** `AppNavigation` drives the window, split view, stacks, and every sheet, cover, popover, and side panel through `Oppi/App/Router.swift`. Screens use `Router.present`/`Router.push` (they take the theme and app-root trait from the presenter) or a `RouterModalPresenter` slot set in `updateProperties()`. `ModalPresentation` picks and refines the style. An iPad side panel is a `TrailingColumnController` column in regular width and a router sheet in compact width. A modal root that mirrors presenter state uses `RouterScreen.liveController(_:update:)`.
4. **Reuse the [shared building blocks](#shared-uikit-building-blocks)** before writing a new one.
5. **A list cell that changes its own layout must re-measure.** Session lists set `selfSizingInvalidation = .enabledIncludingConstraints` and a row that rearranges invalidates its intrinsic size; otherwise the collection view keeps the old height and lines overlap.
6. **SwiftUI only where Apple requires it:** widgets, control widgets, Live Activities (`OppiControlWidget`, `OppiActivityExtension`), and App Intents UI.
7. **A file may import SwiftUI only if the guard's `swiftUIImporters` names it, with a reason.** The guard also counts `import Charts`, `import TipKit`, and `import struct SwiftUI.X` (both frameworks re-export SwiftUI).
8. **Observe notifications with a block on the main queue.** A `@MainActor` type uses `addObserver(forName:object:queue: .main)`, keeps the token, and removes it in `isolated deinit` or when it leaves. Selector observers trap when the poster is off the main thread (crashes `bd3b2b5d4`, `415f62e75`).

### Shared UIKit building blocks

- `EntityIcon` (`Core/Views/EntityIcon.swift`) is the one owner of entity artwork (Agent, Pi, workspace with sandbox mark, provider, model, server); `UIAction.choice(title, entity, selected:, assets:)` is the menu row that carries it. Artwork that loads (Genmoji) posts `.oppiEntityIconDidLoad`: rows put `EntityIcon.loadGeneration` in their key and menus build rows when they open (`UIDeferredMenuElement`), so an arrival never rebuilds an open menu. The guard counts `providerLogoAssetName(`, `providerMonogram(`, `resolvedBadgeIcon.symbolName`, and entity-named `UIAction(title:)` outside it (a heuristic ratchet).
- One helper each: `UIFont.scaled`/`scaledMonospaced`/`UIImage.scaledSymbol` (Dynamic Type), `WorkingSpinnerUIView` (every spinner), `JumpToBottomButton` (chat and SSH terminal), `InsetLabel` (pills and badges), `PlainRowButton`/`ChangedFileRow`, `TerminalMirrorIndicatorUIView`, `IconChoiceUIView`, `IconPickerViewController` (Agent and workspace icons; state in `IconPickerModel`), `FloatingProgressPanel`, `WorkspaceQuickActionLauncher`.
- `HostSwitcherModel` owns the server list, connection retry, and switching. `ServerSwitchMenu` (`Features/Servers/HostSwitcher.swift`) owns every menu that lists servers: rows are `UIAction.choice(.server)`, a gated server shows its lock, a choice passes `ScopedLockService.gate` before the caller's activation, and rows are read when the menu opens. `ServerCatalogServerRowCell`/`ServerCatalogServerMenu` reuse it for catalog lists.
- `ChangedRows` (`SettingsStyle.swift`) reconfigures only rows whose inputs changed, so an open menu survives an unrelated pass; the base keys every page's rows with it.
- The settings kit: see [Settings pages](#settings-pages). `ListScreen` keeps the row builders (`buttonRow`, `staticRow`, `stateRow`, `background`, `setBarItems`) that the base and the lists off it draw their rows with; `SettingsSelectionRowCell`, `SettingsTextViewRowCell`, and the `Workspace*Cell` rows are kit rows. `ServerResourceDetailScreenController` (`Features/Skills`) is the shared Skill/extension page (server switch, detail load, default save, whole-screen state); its detail answer outranks the catalog row until a mutation settles.
- `ThemeGalleryViewController` draws from `ThemeID.palette`: built-ins are contrast-resolved by `ThemeContrast.resolve`; a custom theme keeps its JSON colours (`CustomThemeStore.palette(name:)` does not adjust them).
- `SessionListCollection` and `SessionListBottomBar` are both session lists' collection, rows, swipes, menus, search, and bottom bar; `SessionRowView` is the one row view (the Session Rows settings preview uses it too).
- `FullScreenCodeViewController` is the one full-screen document reader and owns its chrome (Back, Copy, Share, Source, Viewing Options, Annotate and Pick). Each `FullScreenCodeContent` case answers what to show in `Core/Views/Reader/FullScreenCodeContent+Reader.swift`, and a body answers the controller through `ReaderBody`, so the controller keeps no per-kind `switch`; a new kind or body adds its answers there. Each body has its own file in `Core/Views/Reader/`, except the Markdown body, which stays in `FullScreenCodeBodies.swift` under its line budget.
- `ReaderTrace` is the one live-trace type. The reader holds its one observation per installed body (`ReaderBodyContext.follow`), never the body, and rebuilds the body from its content once the trace outgrows it.
- `ReviewCommentStashFloatingButton` is the one staged-comment button (pop, badge, rail count, sheet) for the reader and every host showing content without one; `ReaderChunkStackLayout` is the one layout of virtualized chunk bodies.
- `McpSignInPresenter` presents `McpSignInOwner`'s sheet from whichever MCP screen is in the window, so one sheet is up and it closes with the owner.

### Alerts and confirmations

`Oppi/Core/Views` owns every error alert and confirmation; the guard counts `UIAlertController(` elsewhere as a ratchet.

- `ErrorAlertPresenter` (`UIViewController.errorAlerts`, one per screen): `show` for an event, `sync(title:message:clear:)` from `updateProperties()` for state, `dismiss(onlyWithPrefix:)`. A newer error replaces the one on screen (never stacked or queued). An error shows only while its screen is in front (a search controller, alert, or popover over it does not count); otherwise it is held, one deep, until the screen is uncovered, and never expires. A screen with no content to fail (connecting, locked) drops errors. `sync`'s `clear` receives the message the person read; the owner clears only if its error still equals it.
- `Confirmation` (`ConfirmationSheet.swift`) presents from `Router.topPresenter`; `anchor` is required (the row, or nil), and an anchor outside a window centres the popover so an iPad sheet always has a source. Choice sheets anchor through `AlertAnchor.present`. `TextPrompt` (same file) is the one text-field alert.

### Navigation bar

`Oppi/App/Router.swift` alone decides whether a stack's bar is hidden. A screen that draws its own Back and actions conforms to `NavigationBarHiding`; the stack delegates (`ShellNavigationController`, `RouterNavigationController`) call `applyNavigationBar(forIncoming:animated:)` per incoming screen, which also restores state after a cancelled back swipe. A screen whose answer changes while in front calls `navigationController?.updateNavigationBar(for:animated:)` (acts only on the top screen). An embedding screen does not conform; the policy asks its children. The guard disallows `setNavigationBarHidden(` except in `FullScreenCodeViewController`, which hides its private navigation controller's bar.

### Load states

`Oppi/Core/Views/LoadStateContent.swift` owns every state a screen shows instead of content; the guard counts `UIContentUnavailableConfiguration.empty(`/`.loading(`/`.search(` elsewhere against an empty baseline.

- A screen holds a `LoadState` (`connecting`, `loading`, `empty`, `noResults`, `failed(retry:)`) and paints it with `UIContentUnavailableConfiguration.loadState(_:palette:background:)` (a region: `UIContentUnavailableView(loadState:)`). A failure with `retry` shows one button titled "Retry" (`OfflinePairedServerE2ETests` taps it); `retry: nil` shows none. Onboarding's pairing failure says "Retry" too.
- A button on a content-unavailable configuration cannot carry an identifier: put scoped ids on the view, query Retry inside the state view, and carry a distinguishable state kind in `accessibilityValue`. A controller's own `contentUnavailableConfiguration` has no view a test can hold, so a screen with an agent-facing failure hosts its own `UIContentUnavailableView`.
- A list states itself in a row (`ListSection.state`/`ListStateRow`, drawn by `SettingsStateRowCell`). A `ListScreenController` page never writes its own loading, failed, or empty row: it names `stateSection()` and `emptyState()` and the base picks the row; a store-backed page builds it with `stateRow(hasContent:isLoading:failure:)`. A page with no rows at all is its state (`wholeScreenState()`); rows mean a state row, never both.

### Remaining SwiftUI

- `clients/apple/OppiDebugHarness` (Debug-only) is the one SwiftUI host besides the leaves (`HarnessSwiftUIHost`, `harnessEnvironment(_:)`). Keep `harnessEnvironment` whole: trimming it broke `UIHangHarnessUITests/testExpandedExtensionTextScrollOwnership` (a 183 pt offset flip).
- Framework leaves: the Usage charts (`UsageCharts.swift`, Swift Charts) and the USDZ canvas (`USDZRealityCanvas`, RealityKit). Each takes values only and reads no `@Environment` or app service; `UsageChartLeafHost` and `USDZRealityCanvasHost` are the only `UIHostingController`s in the app.
- `Shared/Theme/ModelColorHelpers.swift` (`StatsDailyChart`, shared palette and provider helpers), `Shared/Renderers/Orbs/OrbMetalView.swift` (SwiftUI only under `#if os(macOS)`), and `ThinkingOrbAcknowledgmentsView.swift` (Mac-only, excluded from `Oppi` in `project.yml`; the guard's `sharedMacOnlySwiftUI` names it and the two lists move together).

### App services

`OppiApp` publishes services as one `AppRootEnvironment`, set as a window trait (`window.traitOverrides.appRootEnvironment`) and found with `AppRootEnvironment.near(_:)`; a controller that embeds one server's page sets the trait on itself. There is no SwiftUI environment value for it in the app; the harness declares its own. The App Lock cover (`AppLockCoverViewController`, per window) paints before the root exists, so it reads only `ThemeRuntimeState` and `AppLockService`. Never hand-write a SwiftUI environment list around a leaf: pass values.

### Presentation gotchas

- A modal that edits presenter state uses `.overFullScreen`: a `.fullScreen` cover stops the presenter rendering.
- A `RouterModalPresenter` presents a run-loop turn late and only while its anchor is in the window; its owner clears state in `clear:` (runs after every dismissal, swipe-down included), not `onDismiss`.
- Search bars outlive their modal unless ended: `Router.endSearch` runs on `finish()`, swipe-down, and trailing-column removal. A screen that searches installs `ScreenSearchController` on its own navigation item.
- A preview nothing launches is deleted, not converted; a root preview uses `PreviewHost.screenStack`. `scripts/screenshot-screen-guard.ts` fails when a test launches a screen no preview case serves.

### Structure guard

`scripts/uikit-structure-guard.ts` scans `clients/apple/Oppi`, `OppiDebugHarness`, `OppiCore`, and `Shared` after stripping comments and strings. SwiftUI navigation and presentation constructs and `UIHostingController` are disallowed everywhere except the guard's commented `allowed` list (the two leaf hosts and `HarnessSwiftUIHost`); another exception needs Chen's approval. `import SwiftUI` is an allow-list (`swiftUIImporters`). The other ratchets (palette bridges, settings theming, settings writes, alerts, load states, entity artwork, page loads) count per file against `scripts/uikit-structure-baseline.json`: new files start at 0, decreases pass, a migration commits the lowered baseline from `--update`, a rename keeps its count, and ordinary runs never write the baseline.

**Mac (`clients/apple/OppiMac`):** new views are AppKit; existing SwiftUI stays until a separate decision; a feature touches Mac only when the request names it. **OppiCore** stays UI-framework-free.

## The shell

- `SceneDelegate` owns the window. Every open (URLs, notifications, Siri and controls, links) is one `AppOpenRequest` to the window's `AppOpener`, which waits for App Lock, launch, a scoped lock, and the target server before it drives `AppNavigation`.
- `AppRootViewController` applies the theme, shows launch backdrop, onboarding, or the shell, and keeps routes through AVKit fullscreen (`WorkspaceMediaOverlayObserver`). App-wide modals are router slots (`AppRootModals`). The extension-dialog slot's id names the connection, so a server switch closes another server's dialog without answering it; `ExtensionDialogFallbackViewController` cannot be swiped away (Cancel answers). What's New covers the root full-screen, so it closes itself with `Router.finish`.
- `WorkspaceCreationIntake` handles shell-started creation (`oppi://workspace`, the guided first workspace), re-running per active server and cancelling the previous run. `PairingApprovalPresentation` presents from `AppRootViewController.updateProperties()`; `PairingApprovalController.approve`/`deny` take the presented request's id and never sign an expired request.
- `AppNavigation` is the single source of truth for every stack. `WorkspaceShellController` converts routes for a fold or resize, then mounts the new layout from them. `ShellNavigationController` (`Oppi/App/ShellRouter.swift`) shows exactly the routes it is given and reports user pops back. `ShellRouteScreens` builds each screen with an exhaustive `switch` over `ShellRoute` and refreshes it through `ShellRouteScreens.update` without rebuilding.
- A screen opens a route through `AppNavigation`. A page that exists only above its opener (a fork, a host file, an agent detail, the SSH terminal) uses `Router.push`; a push during a pop animation waits. A pushed page whose presenter must react to its closing reports that itself. `finish()` at the split detail root shows the column's list.
- `PinnedServerRouteViewController` pins a page to one server (`ServerSelection.resolveVisible`). Server Settings' store, model, and closures belong to that server and never follow a switch: a switch closes only pages that page pushed, never a routed screen above, and a late response settles into the old page. The route tracks the selection itself because a hidden view's `updateProperties()` does not run.
- Quick Session (`QuickSessionViewController`, `QuickSessionModel`) mounts above content while `AppNavigation.showQuickSession` is set and makes the content inert. `ModelPickerViewController` is the one model picker.
- `PushDiscovery` (`Oppi/Core/Push`) keeps one stage per server in `UserDefaults`; the inbox card shows only while that server's stage is `ready`, a relay exists, the build can register, and push is off.

## Chat composer

The composer is UIKit. `ComposerBarController` is the bar and `ComposerPolicy` its decisions. Every screen embeds it through `ChatComposerOwner` (a child controller owning the bar, dictation notice, busy tip, inline voice, focus, and expanded composer) and feeds it a `ChatComposerSource` read in `updateProperties()`: the chat, Quick Session, and `GuidedControlComposerController`. The SSH terminal embeds `ComposerBarController` directly. Presentations from the composer go through the router. The Ask card (`AskCardViewController`) keeps Send/Ignore in its footer and clips the question so every option stays visible whatever extension wrote it. Suggestions come ranked from `FileSuggestionRanker`/`ComposerAutocomplete.slashSuggestions`; the view does not re-rank.

## Live Voice calls

- `LiveVoiceCallCenter` (`Oppi/Features/LiveVoice/`, `AppRootEnvironment.liveVoiceCalls`) owns at most one `LiveVoiceCallController`, keyed by server and session. A call belongs to the app, not a chat: leaving the chat never ends it; only End, the server, or a dead link do. Every start goes through `startCall`, which marks the call starting before it returns (a second tap is refused), then checks mic access, runs `prepareStart`, starts the system call, and opens the server call.
- `callStart(serverId:sessionId:)` is the single policy for a new call (`.available`, `.onThisCall`, `.endsCall`); `replaceCall` ends the current call, waits, then `startCall`; `placeCall` never takes over a live call. Removing a server ends its call first.
- The call uses its own WebSocket (`ServerConnection.makeLiveVoiceWebSocketClient`) that the connection does not track, so focus changes and server switches leave it alone.
- A live or starting call owns the microphone app-wide (`ownsMicrophone`): `VoiceInputManager` refuses dictation, composers hide their mic, a start cancels a running dictation take before the system call (cancelling deactivates the audio session), and read-aloud stays quiet (`AudioPlayerService.beginProcessCaptureInterruption`).
- `LiveVoiceSystemCall` owns the one `CXProvider` behind `LiveVoiceTelephony`. CallKit gets only the session title ("Live Voice" when `ScopedLockService.hidesContentOutsideApp`); if it refuses or is absent (Simulator) the call starts without it. `CXEndCallAction` and the app's End drive each other; every `CXSetMutedCallAction` is the call's mute. A system call runs audio only between `provider(_:didActivate:)` and `didDeactivate`, never calling `setActive`, and fails if not activated within 5 s (callservicesd can hold a stale audio session id). Hold keeps the server call; `UIBackgroundModes` declares `voip`.
- Barge-in is local first (`LiveVoiceBargeInDetector`, 20 ms windows against `LiveVoiceAudioMeter.playbackDBFS`; Apple's speech-activity listener only reports while muted, so it cannot do this). On fire the controller stops playback, sends `voice_call_barge_in`, and drops inbound audio until that request's `command_result`; on refusal it drops until `LiveVoicePlaybackScheduler.replyGap` of quiet. See [Barge-in](architecture-server.md#barge-in).
- `WorkspaceShellController` owns the one call strip and sets its height as `additionalSafeAreaInsets.top`; `LiveVoiceCallStripContent.make` decides what it shows and hides it while the call's chat is on screen (`LiveVoiceCallCenter.shownChats`).

## AI sharing consent

`AISharingConsent` (`Shared/AIConsent`, also in the Share extension) is the one owner of this device's permission to send content through a server to an AI service (App Review 5.1.2(i)). `decide(_:serverId:canAsk:)` is the one gate; every send path asks it first, Siri/Shortcuts and the Share extension pass `canAsk: false`, and removing a server drops its grants. A new send path calls the same decision, never a second store.

## Document editing

`DocumentEditOwner` (`Oppi/Features/DocumentEditing`) is the one owner of a document's edit entry, read, and editor. A reader hands it a `DocumentEditSubject` and shows its `barItems`; a reader never builds, presents, or dismisses an edit control (`FullScreenCodeViewController` takes the owner's items).

- **Pencil:** only when the subject resolves to an edit identity, the server advertises that owner's editing (`ServerInfo.workspaceFileEditing`, `skillFileEditing`, `piFileEditing`) or a record's route answers, and the read is tagged exact UTF-8 within `maxBytes`. A surviving edit session is also enough (reopening a deleted file's draft). Edit with Session lives in the "…" menu.
- `read()` is the only tagged read, so the editor's base is exactly what the reader shows. `begin()` bumps a generation a stale read checks after each await. `begin()` and `finishEditing()` hand the buffer back before the page goes; otherwise the session reads a freed text view.
- Saves go through `WorkspaceFileEditSession` and the `WorkspaceFileWriteOutcome` contract; other documents plug in a `WorkspaceFileEditTransport` (prompts: `PromptEditTransports.swift`, record `version` as the tag, `PATCH ?expectedVersion=`). Native forms send their `version` and show `RecordVersionConflict.message` on 409.
- A creatable missing file (`X-Oppi-Creatable: 1`) gets a `.absent` base seeded with `creatableSeedText`; its first save sends `If-None-Match: *`, so another writer's file is a conflict, never overwritten. Untouched seed text is not an edit.
- **Auto-Save is one setting** (`CodeEditorPreferences.autoSaves`, `SettingsCatalog.autoSave`) for every document; no origin has its own policy. Every write passes `WorkspaceFileEditSession.send(bytes:generation:condition:origin:)`: `.automatic` runs only with Auto-Save on, `.confirmed` always. With it off, `hasUnconfirmedChanges` gates Done with a `Confirmation`. Settings writes post `.codeEditorAutoSaveDidChange`, because a stored write redraws no screen.
- Draft keys are namespaced by owner (`WorkspaceFileEditIdentity.storageKey`: `v1…`, `skill-v1…`, `pi-v1…`, `agent-v1…`, `schedule-v1…`), byte-identical to drafts already on disk.
- `ServerSkillFilePresentation.editable` decides whether a Skill file becomes an editable subject (never a package Skill or symlink). `SkillFileViewController` resolves its Skill by path, never by name.
- `WorkspaceFileEditPath` maps a session-reported path to the workspace path and refuses a session worktree's absolute paths and anything outside the mount. `ChatReaderViewController` owns a tool row's edit entry, re-applies `barItems` once after its read, and closes the editor through `endEditing()`; a row opened while its output streams has no pencil.
- `scripts/document-edit-guard.ts` fails editing types, capability reads, and pencil symbols outside `Features/DocumentEditing/` unless an allowlist entry gives a reason. It runs with the architecture check and in the pre-push Apple lane.

## Chat bar

- `ChatBarItems` (`ChatViewController+Bars.swift`) owns the chat bar in both shapes (horizontal bar, Duo rail). `ChatTopBarLayout` comes from `AppPreferences.ChatTopBar`; only the Top Bar page writes a stored layout, so a stored layout is a person's choice and is kept; an action missing from it is appended to `order`, not shown.
- `ChatBarItems.runTopBarAction` is the one owner of what a button does (bar, rail, menu, and accessibility take the same path). Availability is a set: `bar(available:)`/`menu(available:)` drop what cannot be offered instead of shifting another button into its place. The "…" menu is built once and resolves through `UIDeferredMenuElement.uncached`, so a bar pass never re-attaches a menu its owner holds.
- An open panel's button shows a selection platter and selected trait: glass draws control content in one colour, so a tint alone is invisible.
- `GitPanelViewController` is the chat's one review surface; Files only browses. `ContextBarScoping` decides scope; touched files with no Git change cannot be selected because quick actions send paths the server checks against Git. Every Git read goes through `ChatViewController.loadedGitStatus` → `GitStatusStore.status(workspaceId:worktreeId:)`, so another checkout's status never shows.

## SSH terminal

- Workspace and chat Terminal entries end at `SSHTerminalFolderEntry.open`; `SSHTerminalHostMatch` picks the saved host. `SSHTerminalFolderEntry.prepare(session:profile:target:)` is the one place that turns a target and profile into a placement. The multiplexer comes from the Run on Connect command's first word (`SSHTerminalMultiplexerKind.detected(in:)`); a new multiplexer is one case plus one `SSHTerminalMultiplexer` type, never a second flow. Nothing is typed into a running program: `.hostTerminal` runs only CLI calls over the side channel.
- `SSHTerminalRegistry` keys terminals by `SSHTerminalIdentity` (profile, folder; a Rex pane adds its session, never the pane). Editing or deleting a host ends all its terminals.
- **Remote commands:** the folder is never shell code. `SSHTerminalRemoteShell` owns every generated command: values are octal-encoded and rebuilt with `printf`, because the remote login shell parses the word first and fish reads `\'` inside single quotes as an escape. The folder command exits non-zero for a missing folder instead of opening a shell elsewhere. tmux sessions replace `.`/`:` and double `#`, and enter the folder themselves rather than pass `-c` (tmux expands formats in arguments).
- **Bar:** `SSHTerminalBarOffer` (`SSHTerminalBarPlacement.swift`) owns what the bar offers and `placement(layout:capacity:)` lays it out; `BarLayout` is shared with Chat's top bar. Tap, VoiceOver, and the menu all run `SSHTerminalViewController.perform(_:)`. Nothing branches on an agent name beyond `SSHTerminalAgentDetection.agents`. `SSHTerminalBarContext` owns which actions a terminal hides; hiding is presentation only (`SSHTerminalBarContext.polls` keeps a Herdr terminal's Rex monitor running).
- **Experiments:** Herdr and Rex are off by default; `AppPreferences.Experiments` is the one answer and `SSHTerminalExperimentAccess` reads it per decision. Off hides the buttons and stops polls; a Rex terminal ends (`SSHTerminalRegistry.closeRexTerminals`); toggling needs no relaunch (`AppPreferences.Experiments.didChangeNotification`). Unit tests run with both on through `OppiTests.xctestplan` launch arguments; no test stores a switch, and the off contract passes an explicit `SSHTerminalExperimentAccess`.
- **Overviews:** Herdr and Rex share `SSHTerminalOverview.swift` (`SSHTerminalOverviewSource` → `SSHTerminalOverviewViewController`). A new overview is one source, one bar action, and one case in `overview(_:)`, never a second sheet.
- **Colours:** `SSHTerminalColorLoader` reads the host's Ghostty config through bounded side commands and parses only colour keys on device. Choices live in `SSHTerminalColorStore` keyed by host id, outside `SSHTerminalProfile`, so a colour change never closes an open terminal.

### Rex

- `RexMonitor` subscribes with `session.attach_all`, not `session.attach` (which joins every session's client list). At most one `session.view` runs per session, re-runs if dirtied, and drops a reply older than the applied revision. Rex has no replay, so catch-up is a full resync. `RexAbsence` names the stop conditions (no `rex`, no usable `nc -U`, refused).
- Rex's WebSockets are always framed client-side (`RexPipeSocket`/`RexWebSocketCodec`) over a byte stream: the SSH bridge (`RexBridge.command`, `nc -U`) or TLS over Tailscale (`RexTLSStream`). `RexRoutePlan` (`RexDirect.swift`) tries direct first when `RexDirectStore` knows the URL, falls back to the bridge, and holds the host off direct for 30 s; every monitor gets its `RexDirectHost` so all take one route. `server.status` learns and confirms the URL by `host_id`.
- `RexSessionConnection`: one control connection plus one data connection per live pane (`maximumLivePanes` = 3), opened by a serial lane loop. `session.attach` and `session.own_block` stay sequential because Rex does not order one connection's requests. Neighbours stream untaken at their owner's size. Switching never calls a focus method. A new pane becomes the shown pane in the same lock as the first view that lists it, so it never opens as an untaken neighbour.
- Ownership: Rex announces owners (`block_owner_changed`); a pane is marked owned before its take is sent; take-back happens only while the page shows with the app active, at most `maximumReclaims` (2) times between user actions, which bounds two clients trading a pane.
- `SSHTerminalChannel` keeps one engine per pane; the grid's `presentShownPane` is the one owner of `presented`, so screen and typing cannot drift apart. A hidden pane's OSC 52 is dropped. The channel is made with `answersTerminalQueries: false` (Rex's host terminal already answered).
- Snapshot restore (`RexTerminalStream`, `SSHTerminalEngine.beginRestore`/`continueRestore`): records through READY restore first, later records feed the decoder only once complete (it reads synchronously; an empty read is EOF), the snapshot width holds until FINISH (Ghostty drops history pages after a width change), and output starts after FINISH.
- `SSHTerminalPaneTransition` always slides an opaque page; a pane preview's Metal surface is transparent until that pane's first frame, so another pane's picture never shows.
- `SSHTerminalRexFollower` owns one Rex host's monitor, sign-in, and background end; screens call `sync(active:)` from `updateProperties()`. `RexMonitor.onFinding` is the one source of what `SSHTerminalRexHostStore` remembers. Management goes over the monitor's control connection one at a time and never edits the snapshot (events do). A tab follower signs in automatically only when `SSHTerminalProfile.connectsWithoutPrompt`; the tab reads the store in `viewWillAppear` before `appeared()`, so an edited or deleted host is never signed in from a stale copy.
- Tailnet Rex (`RexTailnet*.swift`) has no sign-in (Rex admits by Tailscale identity) and no side commands: `sideCommandsUnavailable` makes `run`/`openStream` throw at once. Discovery probes only own-suffix online peers and treats only a 426 whose body starts `WebSocket protocol violation` as Rex.

## Settings pages

A UIKit settings page subclasses `ListScreenController` (`clients/apple/Oppi/Features/Settings`), which pins the list at the readable form width and paints it in the theme. The guard counts a hand-built `.insetGrouped` layout in a file that paints the theme's background itself, outside the base and `settingsThemingExceptions`, as a ratchet. A page that edits text in place passes `endsAtKeyboard: true` and `dismissesKeyboardOnDrag: true`.

**A page never owns a load task.** It declares `loadPolicy` (`.none`, `.eachAppearance`, `.onceUntilSubjectChanges`), `loadSubject()`, and `load()`, and asks with `setNeedsLoad()`. The base compares the subject every pass; a change cancels the running load, calls `subjectDidChange()`, and reloads, even while covered. A cancelled load is not a failure. `loadTrigger` tells `.appearance` from `.ask`. A page still guards `Task.isCancelled` after its own `await`. The guard counts `override func viewIsAppearing` and `isLoadCancellation` in base subclasses (baseline 0); a store-owned fetch makes `load()` call the store.

### The pieces

- `ListScreenController<Section, Item>`: `listIdentifier` is `<feature>.<page>.list` (`settings.<page>.list` in Settings); `sections()` runs inside `updateProperties()`; a reorder stays in its section (`ListSlot`, `pageItem`); a section with no rows, state, header, or footer is not drawn.
- `ScheduleListViewController` (`Features/Schedules`): a `ListScreenController` whose rows are the kit's cards (`rowStyle` `.card`), its state row the card section's first row, so a failed reload keeps the cards it has.
- A section that is not a list of rows (the theme gallery's cards, the icon picker's symbols) is laid out by the page through `layoutSection(for:environment:)`, which declares its boundary header item; the kit still fills the heading from `ListSection.header` and lays out every other section.
- `inputs(of:)`: the default key differs every pass, so an unkeyed row cannot go stale. Key rows that hold selectable text, an open `UIMenu`, a switch in flight, or a text field. The theme is in the key.
- `SettingsStyle`: title `fg`, value `comment`, action `blue`, destructive `red`, fixable problem `orange`, page `bg`. A dark theme's card is `bgHighlight` (the system card was 1.01 contrast on Dark) unless that is under 1.08 against `bg`. Every list paints cards through the base's cell provider, keeping the pressed look. A title is never `.label` or a one-off colour.
- One-control cells (index, menu, action, state) paint with their own labels under an overlay `SettingsRowButton` that is the only accessibility element and carries the identifier: XCUITest types a `contentConfiguration` cell as a Cell, so `app.buttons[id]` would miss it.
- Pick a row kind by what it does: Navigate `SettingsIndexRowCell`; Choice `settingChoiceRow`/`SettingsMenuRowCell`; Toggle `settingToggleRow` (else `toggleRow`, which the write guard counts); Action `SettingsActionRowCell`; State `SettingsStateRowCell` ("Retry" is the one retry label); Info `content(.info)`. `SettingsSegmentedRowCell` only where the choice reshapes a live preview on the page.
- `.settingsToggle(reusing:)` keeps one `UISwitch` per cell, so a rollback never leaves a replaced switch on screen.

### Scope and saving

`SettingsScope` sentences: `device` "Saved on this device."; `server` "Applies to every device on <server>."; `workspace` "Applies to this workspace."; `deviceOnServer` "For this device, kept on <server>." Every page declares its default scope; only a section whose scope differs gets its sentence (`SettingsScope.footer`, needs `footers: true`). No badges; always "this device".

A single control saves immediately. Save/Cancel drafts only for fields that validate together or heavy saves; a draft shows why a save was refused. A server save shows the new value disabled in flight, reverts with the reason on failure, and reloads on 409.

### The catalog and the store

- Chen's rule: one place declares a setting. Anything shared by more than one page or device is declared in `OppiCore/Settings/SettingsCatalog.swift` (`SettingDeclaration`); `SettingsCatalogTests` keeps ids and storage unique, and a server-backed declaration must match `protocol/settings.json` (`SettingsCatalogContractTests`).
- `SettingStorage` picks the adapter and scope; only `.device` and `.server` have adapters (others read as unavailable). Scope comes from `storage.scope(serverName:workspaceName:)`, never built by hand. A device declaration reuses the existing `AppPreferenceStore` key and default: no second key or default.
- `SettingsStore` is the only code that validates, saves, rolls back, and reloads. A store has one context for life: the device store (`ConnectionCoordinator.deviceSettings`) or one per server (`ConnectionCoordinator.settings(for:)`, made on first use, dropped on removal), so a result lands only in its server's store. Using the wrong store is an `assertionFailure`. `set`/`reload` return the settled value; use it rather than re-reading after an `await`. Side effects live in `afterWrite` (`liveDevice`, `live`, `liveServerAfterWrite`, which also runs after a conflict reload), never in a page. A `revision_conflict` reloads and says so once; an older document is ignored; writes to one route run in order.
- Adapters reach routes through `SettingsServerTransport` (`APIClient+SettingsTransport.swift`), sending only the changed field with `baseRevision`. A page never calls an `APIClient` settings route or writes a settings key.
- The settings-write guard counts `AppPreferences.*.set…(`, `UserDefaults.standard.set(`, `FontPreferences.set…(`, `settingsApiWrites` calls, `toggleRow(`, and `.settingsToggle(` in `Features/**`. It sees calls by name only: review a new wrapper as a write and add a new settings route's method to `settingsApiWrites`.

### Identifiers and words

Existing identifiers stay (`settings.chatStyle`, `settings.row.*` are pinned). New rows use `settings|server|workspace.<page>.<row>`, on the row button or control, never the cell; naming rules: [Identifier naming](testing/ios-accessibility-testability.md#identifier-naming).

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

- Terminal-kind tool output paints from `ToolOutputStore`; the server sends stripped text (a suffix under 8 KiB, then a throttled 16 KiB / 80-line tail). The full log comes from the sidecar.
- Readers open through `ChatViewController+Timeline.openTimelineReader` as a `.chatReader` route; a locked origin replaces the page with the lock cover. UIKit configures no off-screen cell, so live readers are fed by `ChatTimelineReaderTraces`, one weakly held trace per open reader; rows own no streams, and a row that leaves the timeline settles its reader.
- Replaying the event ring over a busy session: the replayed `agent_start` marks the running tool interrupted and the replayed `tool_start` revives it; canonically finished calls stay finished.

## Client boundary rules current code

`server/scripts/check-architecture-boundaries.ts` enforces these in server checks (`--scope all`), the iOS build phase (`--scope ios`), and the Mac pre-push gate (`--scope mac`):

- `OppiCore/**` must not import UIKit, AppKit, SwiftUI, ActivityKit, UserNotifications, Speech, AVFoundation, WebKit, or MetricKit; `TimelineReducer.swift` and `DeltaCoalescer.swift` stay platform-neutral.
- `OppiMac/**` must not import UIKit. `project.yml` is the Mac target membership authority: OppiMac compiles `OppiMac/**`, `OppiCore/**`, `Shared/**`, and only the listed `Oppi/**` adapter files.
- `Oppi/Core/Views/**` and `Oppi/Features/Chat/Timeline/**` must not reference `APIClient`, `WebSocketClient`, `ServerConnection`, `ConnectionCoordinator`, `apiClient`, `wsClient`, `SessionStore`, or `WorkspaceStore` (`view-layer-connection-boundary`); they take explicit values (`SessionContentAccess`, icon cache) and typed actions.
- Only `ComposerShared.swift` calls `.stopRecording(`/`.cancelRecording(` (`ios-voice-lifecycle-owner`); it owns keyboard restore, draft rollback, and capture ownership.
- `TimelineReducer.swift` may carry one `cyclomatic_complexity` disable; `ToolPresentationBuilder.swift` and `ToolTimelineRowContent.swift` none (`ios-cyclomatic-disable-budget`).
- `AppleOnDeviceVoiceProvider.swift` calls `setContext(` before `start(inputSequence:` because `SpeechAnalyzer` ignores hints set after analysis starts (`ios-speech-context-before-start`).
- iOS test targets never open files through `#filePath`/`#file`: sim-pool's prefix-mapped cache compiles them to `/^src/...`. Bundle a resource or read `OPPI_SOURCE_ROOT` (`ios-test-no-source-paths`).
- List views read `SessionStore.listProjectionSessions`, never full `SessionStore.sessions`.
- `SessionStore`, `WorkspaceStore`, `ServerResourceStore`, and `OppiCore/Stores/**` must not depend on each other; cross-store work belongs in `ServerConnection` or a small service.
- iOS opens go through `AppOpener` (no NotificationCenter open bus). Only the opener waits for App Lock, launch, and server, applies the browser preference, and system-opens URLs; only it and Tailnet authentication present `InAppBrowserPresenter`. Timeline `UITextViewDelegate` conformances implement `primaryActionFor` in the same file.
- Generic extension UI must not branch on tool, extension, status, widget, or display names (including `ExtensionSurfacePanel.swift`, `MacExtensionSurfacePanel.swift`); add protocol metadata at the producer.
- SwiftUI styling uses the environment-resolved `.theme*` `ShapeStyle`; `Color.theme*` is a snapshot for APIs that need a concrete `Color` (`scripts/theme-surface-guard.ts`). Persistent list and panel modifiers read `theme`/`themeID` from the environment, or mounted content does not repaint after a theme switch.
- UIKit reads colours from its palette (`palette.ui.*`, `ThemeUIKitPalette` in `Core/Theme/ThemeCatalog.swift`) where it applies its theme, never into a constant; palettes are immutable, so views that re-read in `updateProperties()` repaint on a theme switch. The guard fails a new `UIColor(palette.x)` outside `ThemeCatalog.swift`. Translucency is `palette.ui.x.withAlphaComponent(a)`: `Color.opacity` multiplies into an imported theme's own alpha.
- Production sources under `Oppi`, `OppiCore`, and `Shared` stay at or under 1,500 lines; bigger files are frozen at their size in `scripts/file-line-budget-baseline.json`, and budgets only go down (`file-line-budget`; tests and the debug harness are reported, not enforced).
- SwiftUI navigation and presentation constructs are disallowed under `clients/apple/Oppi` and `import SwiftUI` is limited to `swiftUIImporters` (`scripts/uikit-structure-guard.ts`); `scripts/screenshot-screen-guard.ts` checks every launched `SCREENSHOT_SCREEN` has a preview case.
