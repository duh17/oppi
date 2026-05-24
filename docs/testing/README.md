# Testing Guide

Canonical test commands for the Oppi monorepo.

## Policy as code

- Gate policy: `server/testing-policy.json`
- Gate runner: `cd server && npm run test:gate:pr-fast`
- PR fast gate currently runs `check` and `test:coverage`; coverage thresholds live in `server/vitest.config.ts`.
- Last server coverage run: 2026-05-23 with Vitest v8 — statements 75.29%, branches 65.15%, functions 80.07%, lines 76.21%.

## Server

From `server/`:

```bash
npm run check
npm test
```

Fast PR gate:

```bash
npm run test:gate:pr-fast
```

## Apple

From `clients/apple/`:

### Regenerate project

```bash
xcodegen generate
```

### Simulator build (public-safe command)

Use a unique `-derivedDataPath` so concurrent builds do not collide.

```bash
xcodebuild -project Oppi.xcodeproj -scheme Oppi build \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -derivedDataPath .build/derived-data-build
```

### iOS unit tests

Use the dedicated `OppiUnitTests` scheme for `OppiTests`.

```bash
xcodebuild -project Oppi.xcodeproj -scheme OppiUnitTests test \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -derivedDataPath .build/derived-data-tests \
  -only-testing:OppiTests
```

Why: the full `Oppi` scheme also builds `OppiPerfTests`, `OppiUITests`, and `OppiE2ETests`, which makes focused unit-test runs look hung.

### Swift Testing filters

`xcodebuild` strips one trailing `()` from Swift Testing identifiers.
Use double parentheses for function-level filters.

```bash
# Suite
xcodebuild -project Oppi.xcodeproj -scheme OppiUnitTests test \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -derivedDataPath .build/derived-data-tests \
  -only-testing:OppiTests/MySuiteStruct

# Function
xcodebuild -project Oppi.xcodeproj -scheme OppiUnitTests test \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -derivedDataPath .build/derived-data-tests \
  -only-testing:'OppiTests/MySuiteStruct/myTestFunc()()'
```

### UI / E2E / perf tests

Use project-specific scripts or your CI lane. These intentionally exercise non-unit-test bundles.

### Protocol checks

Run the protocol-related test suites from `server/` and `clients/apple/` when editing message contracts.

## Internal maintainer note

Maintainers may use additional local wrappers (for example simulator pool scripts) to coordinate parallel agent runs. Those wrappers are optional and not required for public contributors.

## Failure investigation

When a wrapper script writes an external log path, inspect the log directly instead of rerunning blindly.