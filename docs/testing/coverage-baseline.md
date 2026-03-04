# Coverage Baseline

Last updated: 2026-03-04

Measured with unit tests only (`-only-testing:OppiTests`, `-enableCodeCoverage YES`).

## Summary

| Side | Line Coverage | Enforced Threshold |
|------|--------------|-------------------|
| **Server** | 72.7% | 70% statements, 63% branches, 77% functions, 70% lines |
| **iOS (overall)** | 42.0% (24632/58704) | Not yet enforced |
| **iOS (logic only)** | ~74% | Target: 70% |

iOS overall is dragged down by pure SwiftUI view files at 0%. Logic layers are strong.

## iOS Coverage by Layer

### Logic layers (testable with unit tests)

These should be at 70%+ and rising. Regressions are bugs.

| Layer | Coverage | Lines | Status |
|-------|----------|-------|--------|
| Core/Runtime | 95.4% | 1492 | Stable. Timeline reducer, coalescer, tool mapper. |
| Core/Formatting | 87.2% | 1552 | Stable. ANSI, markdown, syntax, diff, bash detector. |
| Features/Chat/Timeline | 80.5% | 11106 | Stable. Cell factory, row builders, perf, scroll. |
| Features/Chat/Output | 75.4% | 1424 | Stable. Tool presentation, plot spec. |
| Features/Chat/Session | 73.9% | 2364 | Stable. Action handler, scroll controller, session manager. |
| Core/Models | 73.9% | 1380 | Stable. Protocol types, codable, JSON. |
| Core/Networking | 72.4% | 4966 | Stable. WS client, API client, connection, LAN. |
| Core/Extensions | 56.5% | 115 | Small. Color, date, string helpers. |
| Core/Services | 54.8% | 5592 | Mixed. Stores tested, some services not (audio, biometric). |
| Core/Theme | 35.4% | 427 | RemoteTheme at 0% — needs tests. |
| App | 32.8% | 3522 | ContentView (766 lines) untested — view logic. |
| Core/Notifications | 7.2% | 139 | Push path — hard to unit test. |
| Core/Push | 0% | 140 | APNs registration — hard to unit test. |

### UI view layers (0% — need UI tests or view-model extraction)

Pure SwiftUI views. Cannot be meaningfully covered by unit tests.
UI tests cover these but slowly (~4 min for full suite).

| Layer | Lines | Notes |
|-------|-------|-------|
| Core/Views | 5533 | FullScreenCodeVC (1020), DiffContentView (378) |
| Features/Chat/Composer | 3382 | ExpandedComposerView (864), MessageQueueContainer (621) |
| Features/Chat/Support | 4590 | SessionChangesView (1254), SessionOutlineView (997) |
| Features/Workspaces | 5214 | 8 views, all 0% |
| Features/Onboarding | 926 | 3 views |
| Features/Permissions | 930 | 3 views |
| Features/Settings | 1013 | 2 views |
| Features/Sessions | 511 | 2 views |
| Features/Skills | 516 | 3 views |
| Features/Servers | 413 | 1 view |

## Coverage Strategy

### Principle

Stable features get solidified with tests. Rapid-change areas get tested once they stabilize.
Coverage is a ratchet — it should only go up for stable layers.

### Non-UI code targets (enforced in nightly gate)

| Layer | Current | Target | When |
|-------|---------|--------|------|
| Core/Runtime | 95% | 90%+ | Now — stable |
| Core/Formatting | 87% | 85%+ | Now — stable |
| Core/Models | 74% | 75%+ | Now — stable |
| Core/Networking | 72% | 70%+ | Now — stable |
| Features/Chat/Timeline | 80% | 75%+ | Now — stable |
| Features/Chat/Output | 75% | 70%+ | Now — stable |
| Features/Chat/Session | 74% | 70%+ | Now — stable |
| Core/Services | 55% | 65%+ | Next — extract untested service logic |
| Core/Theme | 35% | 60%+ | Next — RemoteTheme needs tests |
| App | 33% | 50%+ | Later — ContentView needs refactor |

### UI view coverage (via UI tests, nightly gate)

UI tests verify views render and respond to interaction.
Coverage from UI tests is coarse but prevents dead-render regressions.

Not gated on thresholds — measured for visibility only.

### What NOT to test

- Thin SwiftUI view bodies that just compose other views
- Apple framework wrappers (PushRegistration, BiometricService)
- One-shot onboarding flows (diminishing returns)

## Server Coverage (vitest v8)

| Metric | Current | Threshold |
|--------|---------|-----------|
| Statements | 72.2% | 70% |
| Branches | 64.9% | 63% |
| Functions | 79.7% | 77% |
| Lines | 72.7% | 70% |

Enforced via `vitest.config.ts` thresholds. Fails CI if below.
