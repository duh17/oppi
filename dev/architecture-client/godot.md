# Godot pane

The Godot pane plays a Godot project from a paired server beside the chat (experiment `godotPane`, off by default; off on the Mac through `PlatformCapabilities.godotPane`).

## Owners

- `GodotEngineHost` (`Oppi/Features/Godot/`, `AppRootEnvironment.godot`) owns the app's one engine, its display link, pauses, audio and log.
- One game runs at a time; the engine stops and starts again in the process (patch 0005). `GodotPackPolicy` (OppiCore) decides how each build applies.
- `GodotPanePhase.resolve` (OppiCore) is the one answer to what a pane shows.
- One pane at a time holds the one `GodotSurfaceView`, which moves between panes and is never rebuilt. A publish never takes it from the pane being played.
- Each Godot pane reads its project over HTTP and attaches as a player on the project's link (`GodotPlayerLink`, `protocol/godot.json`; the connection makes it, with the `StreamAuthRenewer` every stream uses): releases and controllers' commands arrive there, and the pane reports its state, the game's log and command results. Commands act on the running game from whichever pane receives them, and never move its view.
- `GodotChatHandoff` hands a game to a chat as an unsent composer draft (`ChatViewController.stageInComposer`).
- `GodotEngineRuntime` is the surface the host drives. `GodotRuntime` wraps `engine/godot`'s C API (`OppiGodot.h`) and compiles only when `canImport(OppiGodot)`.

## The engine artifact

- The engine binary is never committed. `engine/godot/build.sh` builds the pinned Godot tag, `patches/` and the `oppigodot` module with the app's pinned Xcode into a local cache keyed by those inputs (`--print-id`).
- `clients/apple/scripts/install-oppi-godot.sh`, run by `ensure-prebuilt-frameworks.sh`, installs a matching build into `Vendor/OppiGodot/` and writes the xcconfig `Base.xcconfig` includes. Without one, the app builds with no engine and offers no Godot pane (`PlatformCapabilities.godotPane`); CI and Xcode Cloud build that way. A TestFlight archive includes the engine only with `testflight.ts --with-godot`, and records its BUILD_ID.

## Packs and the sandbox

- Packs come only from the paired server. `GodotPackCache` checks each against its release's SHA-256 and size; `GodotPackIndex` reads its file table, and a pack with native code is refused before the engine sees it.
- The `oppigodot` module confines a game's files to its `user://`, its engine cache and read-only pack and font folders, compared by real path (a game makes no links); refuses sockets and DNS; forces the microphone off. Patch 0003 takes away URL opening and the pasteboard.

## Tests

- `OppiTests/Godot/`: packs, their cache, and the host with a fake runtime.
- `GodotPaneUITests` (`ipad`): the launcher's Godot choice over the chat-routes fixture server (`ChatRoutesGodot`), with `OppiTests/Fixtures/godot-sample.pck` exported from `engine/godot/sample`.
