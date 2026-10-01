# Testing Guide: Mac

Part of [Testing Guide](README.md). Mac app checks, only when the work names Mac.

## Mac

Mac is an Apple client target (`OppiMac` / `OppiMacTests`). Use this section for repository-owned Mac build, test, architecture, and visual-evidence commands. The local debug-app product loop lives in the `oppi-dev` skill; do not copy that command catalog here.

Do not use `sim-pool.sh` for Mac. Reuse `.build/mac-tests` for unit tests and `.build/mac-debug` for the debug app. Do not create a new `mac-*` or `derived-data-*` path per experiment. Local unsigned Debug builds set `CODE_SIGNING_ALLOWED=NO`.

### Architecture

```bash
cd server
bun scripts/check-architecture-boundaries.ts --scope mac
```

`--scope all` includes this lane. The Mac pre-push gate runs `--scope mac` before `OppiMac` `build-for-testing`.

### Build and unit tests

From `clients/apple/` after `xcodegen generate` when `project.yml` changed:

```bash
xcodebuild -project Oppi.xcodeproj -scheme OppiMac \
  -destination 'platform=macOS' \
  -derivedDataPath .build/mac-tests \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild -project Oppi.xcodeproj -scheme OppiMac \
  -destination 'platform=macOS' \
  -derivedDataPath .build/mac-tests \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Focused Swift Testing / XCTest filters use the same `-only-testing:OppiMacTests/...` shape as iOS. The tracked pre-push Mac lane is compile-only (`build-for-testing`); it does not run `OppiMacTests`. Run the test command above when Mac behavior changed.

`server/testing-policy.json` currently owns server and iOS-simulator Apple steps. It has no Mac platform key; do not treat those gates as Mac coverage.

### Visual evidence

In-process visual gates live in `OppiMacTests`:

- `MacComposerVisualGateTests`
- `MacSessionShellVisualGateTests`
- `MacToolMetadataVisualGateTests`

They host SwiftUI in an offscreen `NSWindow`, assert layout geometry, and keep structural `XCTAttachment` images. They prove one hosted paint of the current test binary. They do not prove a running `/Applications/Oppi.app` or debug-app identity, Liquid Glass, send/stop/reconnect, LaunchAgent attach, or release readiness. For chrome/material claims that need a live window, record commit, dirty paths, the exact `.app` path, and a running-window artifact separately.
