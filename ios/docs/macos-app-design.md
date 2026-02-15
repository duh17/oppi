# Oppi macOS App Design (Native + Full iOS Parity)

Last updated: 2026-02-11
Status: Proposed

## 1) Goals

- Build a **native macOS app** (not Catalyst-first UI copy) that feels at home on desktop.
- Reach **functional parity** with the iOS app supervision loop:
  - sessions, chat streaming, tools, permissions, workspaces, skills, settings, diagnostics.
- Maximize **shared logic** between iOS and macOS by extracting a shared Swift core.
- Preserve existing server contract (`pi-remote` TypeScript backend) as source of truth.

## 2) Non-goals (for v1 mac)

- Rewriting `pi-remote` backend in Swift.
- Building a full local terminal emulator inside the app.
- Multi-user collaboration UI in first mac release.

---

## 3) Product Scope: iOS Parity Matrix

| Capability | iOS today | macOS v1 target |
|---|---:|---:|
| Onboarding/connect to server | ✅ | ✅ |
| Session list/create/delete/stop | ✅ | ✅ |
| Chat streaming + deltas | ✅ | ✅ |
| Tool call rows + expanded output | ✅ | ✅ |
| Permission review/approve/deny | ✅ | ✅ |
| Live activity feed | ✅ | ✅ (desktop live panel) |
| Workspaces (CRUD + picker) | ✅ | ✅ |
| Skills browser/detail/save | ✅ | ✅ |
| File read views + diffs | ✅ | ✅ |
| Diagnostics upload | ✅ | ✅ |
| Push notifications | ✅ APNs | ✅ UserNotifications |
| Live Activities / Dynamic Island | ✅ | ❌ (mac equivalent: status center panel) |
| QR scan onboarding | ✅ VisionKit | Optional (paste token preferred) |

**Interpretation:** “Parity” means user can complete the same supervision and control tasks. Platform-specific UX can differ.

---

## 4) Native macOS UX Model

## 4.1 App shell

Use `NavigationSplitView` (3-column):

1. **Left sidebar**: workspaces + sessions + filters
2. **Middle timeline**: chat/event stream for selected session
3. **Right inspector**: selected item details (tool output, permission metadata, files, diffs)

Desktop-first behavior:
- keyboard-first navigation (`⌘1` Sessions, `⌘2` Live, `⌘3` Skills, `⌘,` Settings)
- command menu actions for approve/deny/stop/new session
- persistent selection + restoration across relaunch

## 4.2 Permission UX (desktop)

- Permission requests show as:
  - floating top banner (if chat hidden), and
  - dedicated inspector card for rich context.
- Keyboard actions:
  - `⌘↩` approve
  - `⌘.` deny
- Timeout countdown visible in-row and in global pending queue.

## 4.3 Chat/timeline UX

- Dense desktop rows (more information per row than iOS).
- Expand/collapse tool output inline with independent command/output blocks.
- Global search/filter over timeline (event type/tool/file path).

## 4.4 Server mode UX

Support two run modes in Settings:
- **Remote mode**: connect to external host (same as iOS model).
- **Local mode**: app manages local `pi-remote` server on this Mac.

---

## 5) Architecture: Shared Core + Thin Platform Shells

## 5.1 Proposed module split

Create a shared Swift package at `ios/Packages/OppiCore` used by iOS + macOS targets.

### OppiCore modules

1. `OppiCoreModels`
   - `Session`, `Permission`, `TraceEvent`, `JSONValue`
   - `ClientMessage`, `ServerMessage` encode/decode

2. `OppiCoreNetworking`
   - `APIClient`
   - `WebSocketClient`
   - protocol clients and retry/backoff policies

3. `OppiCoreRuntime`
   - `AgentEvent`
   - `TimelineReducer`
   - `DeltaCoalescer`
   - `ToolEventMapper`
   - `ChatItem`, `ToolOutputStore`

4. `OppiCoreState`
   - `SessionStore`
   - `PermissionStore`
   - `RestorationState` (platform-agnostic schema)

5. `OppiCoreProtocols`
   - abstraction interfaces for platform services:
     - notifications
     - secure storage
     - clipboard/share
     - logging sink

### Platform layers

- `PiRemote` (iOS target): SwiftUI + UIKit renderers, VisionKit, ActivityKit.
- `OppiMac` (new macOS target): SwiftUI/AppKit-bridged views where needed.

## 5.2 What is reusable today

High confidence reusable:
- wire models + coders
- API/WS transport
- reducer/coalescer/event mapping
- stores and restoration schema
- workspace/skills business logic

Low reuse / platform rewrite:
- UIKit-based chat renderer components (`ChatTimelineCollectionView`, text view wrappers)
- iOS camera/vision onboarding
- ActivityKit live activity surface

---

## 6) Local Server Management (macOS-only)

Because macOS distribution is DMG (not App Store sandbox), local management is feasible.

## 6.1 Responsibilities

- install/check `pi-remote` runtime prereqs
- start/stop/restart server
- show health, logs, active sessions
- configure host/port/data dir
- optionally install launch agent for auto-start

## 6.2 Runtime model

Preferred: `launchd` agent (`~/Library/LaunchAgents/dev.chenda.pi-remote.plist`)

Benefits:
- crash restart behavior
- standard OS lifecycle integration
- simple status inspection (`launchctl print`, log tail)

App talks to local server via `http://127.0.0.1:<port>` and same WS protocol.

## 6.3 Safety constraints

- preserve server fail-closed gate behavior for host mode
- do not auto-modify policy presets to reduce approvals
- expose clear warning when gate extension is unavailable

---

## 7) Delivery Plan (Incremental)

## Phase A — Shared core extraction (1-1.5 weeks)

- Create `OppiCore` package.
- Move models/network/runtime/state into package with minimal behavior changes.
- Keep iOS app compiling against package.
- Add shared tests for decoder + reducer + coalescer parity.

**Exit criteria**
- iOS app behavior unchanged.
- Existing tests pass.

## Phase B — macOS shell + parity backbone (1-2 weeks)

- Add `OppiMac` target.
- Build split-view shell (sessions/timeline/inspector).
- Connect to shared core and server.
- Implement session lifecycle + chat streaming + permission actions.

**Exit criteria**
- Can supervise a live session end-to-end from mac app.

## Phase C — full parity features (1-2 weeks)

- Workspaces + skills screens.
- Tool output detail views + file/diff UI.
- Diagnostics and reconnect/restoration behavior.
- Sentry observability parity (events, breadcrumbs, debug context).
- Keyboard shortcuts and command menus.

**Exit criteria**
- All iOS critical workflows are possible on mac.

## Phase D — local server manager (0.5-1.5 weeks)

- Add local mode.
- launchd integration + logs/status.
- onboarding flow for local-only users.

**Exit criteria**
- Mac app can run and supervise local server without terminal.

Total estimate: **~4-7 weeks** depending on UI polish depth.

---

## 8) Testing Strategy

- Shared package tests run once for both iOS and macOS destinations.
- Protocol conformance tests using fixtures aligned with `pi-remote/src/types.ts`.
- macOS UI tests for keyboard shortcuts, multi-window, restoration.
- Sentry verification matrix (startup, WS failure, permission failure, crash capture, breadcrumb quality).
- Soak test: long streaming sessions + repeated session switches, watch memory growth.

---

## 9) Packaging + Distribution (DMG)

- Sign app with Developer ID certificate.
- Notarize build for smooth Gatekeeper experience.
- Generate DMG for release artifacts.
- Optional auto-update channel later (Sparkle) if desired.

---

## 10) Risks + Mitigations

1. **UIKit-heavy iOS renderer limits reuse**
   - Mitigation: keep rendering platform-specific, share runtime/state only.

2. **Protocol drift between server and clients**
   - Mitigation: shared fixtures + decode tests in `OppiCoreModels`.

3. **Feature parity tax across two clients**
   - Mitigation: strict shared-core boundary and minimal duplicated business logic.

4. **Local server ops complexity**
   - Mitigation: launchd-based lifecycle and explicit health diagnostics.

---

## 11) Implementation checklist

- [ ] Create `ios/Packages/OppiCore` with module layout above
- [ ] Move `Core/Models` into shared package
- [ ] Move `Core/Networking` into shared package
- [ ] Move `Core/Runtime` into shared package
- [ ] Move portable parts of `Core/Services` into shared package
- [ ] Add macOS app target `OppiMac` in `ios/project.yml`
- [ ] Build split-view shell and command menu
- [ ] Implement permission panel + keyboard actions
- [ ] Implement workspaces + skills screens
- [ ] Implement local server manager (launchd + status/logs)
- [ ] Wire Sentry on macOS target (DSN config + breadcrumbs + filtering)
- [ ] Add macOS test plan + soak checklist

---

## 12) Decisions

- Keep Node `pi-remote` backend as source-of-truth.
- Build native macOS app with full supervision parity.
- Extract shared Swift core for all non-UI logic.
- Support both remote and local-server-managed modes on macOS.
