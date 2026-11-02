# Testing Guide: Mac

Part of [Testing Guide](README.md); same standard. Use only when the work names Mac (`OppiMac` / `OppiMacTests`).

- Never use `sim-pool.sh` for Mac. Reuse `.build/mac-tests` for tests and `.build/mac-debug` for the debug app; never a new `mac-*` or `derived-data-*` path per experiment. Unsigned Debug builds set `CODE_SIGNING_ALLOWED=NO`.
- Architecture: `cd server && bun scripts/check-architecture-boundaries.ts --scope mac` (`--scope all` includes it; the Mac pre-push lane runs it before `build-for-testing`).

## Build and unit tests

From `clients/apple/` (after `xcodegen generate` if `project.yml` changed):

```bash
xcodebuild -project Oppi.xcodeproj -scheme OppiMac -destination 'platform=macOS' \
  -derivedDataPath .build/mac-tests CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Oppi.xcodeproj -scheme OppiMac -destination 'platform=macOS' \
  -derivedDataPath .build/mac-tests CODE_SIGNING_ALLOWED=NO test
```

Filters use `-only-testing:OppiMacTests/...`. The pre-push Mac lane is compile-only and never runs `OppiMacTests`; run the tests when Mac behaviour changed. `server/testing-policy.json` has no Mac key, so its gates are not Mac coverage.

## Visual evidence

`MacComposerVisualGateTests`, `MacSessionShellVisualGateTests`, and `MacToolMetadataVisualGateTests` host SwiftUI offscreen and assert geometry. They prove one hosted paint of the test binary, not a running app, Liquid Glass, send/stop/reconnect, LaunchAgent attach, or release readiness; a live-window claim records the commit, dirty paths, `.app` path, and a running-window artifact.
