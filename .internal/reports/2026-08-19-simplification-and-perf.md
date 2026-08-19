# Oppi maintainability and performance findings

Measured on `main` at `87cd49f363c5edd9e87a1eaa66877244e30e6d9d` (2026-08-19). Line counts are `wc -l` unless noted. Microbenchmarks are from the checked-in file `server/bench/baselines/server-hotpath.metrics`. No production timings were collected in this pass.

Findings only. No production refactor. A one-line `protocol/README.md` correction (the table still says `pi-events.json` is “used to test `translatePiEvent`”; no test reads that file) was **not** landed here because `protocol/**` is in both Apple and Server CI path filters and would schedule a hosted simulator job.

---

### 1. What is actually complex (with current paths and line counts)

Complexity is concentrated, not uniform. Architecture docs already name most of the right seams. Several large files added after 17 Aug 2026 are now bigger than the “god files” the prior report emphasized.

**Tree size (this HEAD)**

| Tree | Files | Lines |
|------|------:|------:|
| `server/src/**/*.ts` | 245 | 84,865 |
| `clients/apple/**/*.swift` (includes tests, E2E, perf, Mac) | 1,002 | 353,511 |

**Server — largest production modules**

| Path | Lines | What it actually is |
|------|------:|---------------------|
| `server/src/sdk-backend.ts` | 2,173 | Pi `AgentSession` wrapper: exported cwd/sandbox helpers, `createRuntimeFactory` closure, prompt/tool policy, queue/dispose |
| `server/src/pi-tui-mirror-runtime.ts` | 2,082 | Terminal bridge WS + takeover + subset of coordinator wiring + queue proxy |
| `server/src/cli/help.ts` | 1,811 | Declarative `HELP_TOPICS` data (~1,600 lines) plus render helpers |
| `server/src/session-protocol.ts` | 1,524 | Pi event → `ServerMessage` translation (hot path) |
| `server/src/server.ts` | 1,465 | Composition root: listeners, auth, wiring |
| `server/src/storage/session-id-migration-executor.ts` | 1,393 | Offline Session.id=Pi UUID cutover executor (not request hot path) |
| `server/src/storage/session-id-migration-inventory.ts` | 1,347 | Same cutover: inventory |
| `server/src/routes/registry.ts` | 1,280 | Static API catalog + metrics path normalizer; **not** HTTP dispatch |
| `server/src/storage/session-sqlite-store.ts` | 1,269 | SQLite read model + migrations |
| `server/src/search-index.ts` | 1,183 | FTS |
| `server/src/trace-paging.ts` | 1,151 | Incremental JSONL page reads |
| `server/src/cli.ts` | 1,143 | CLI command implementations |
| `server/src/session-attachments.ts` | 1,125 | Attachment materialization |
| `server/src/routes/workspaces.ts` | 1,081 | Workspace HTTP |
| `server/src/trace.ts` | 1,047 | Full trace read / context builder |
| `server/src/session-lifecycle-service.ts` | 1,037 | HTTP lifecycle application service |
| `server/src/tls.ts` | 1,037 | TLS |
| `server/scripts/architecture-layer-rules.mjs` | 1,192 | Import/boundary rules (enforced, not runtime) |

`server/src/routes/index.ts` is 66 lines and is the actual route dispatcher. Do not conflate it with `registry.ts`.

**Session-* sprawl**

38 `session-*.ts` files sit flat in `server/src/` (plus `sessions.ts` at 631 lines). Combined `session-*` production files: 13,916 lines.

Name collisions are **different layers**, not duplicates:

| Pair | Lines | Role |
|------|------:|------|
| `session-lifecycle.ts` vs `session-lifecycle-service.ts` | 184 vs 1,037 | Idle/end coordinator vs HTTP open/stop/fork/delete/import service |
| `session-stop.ts` vs `session-stop-flow.ts` | 398 vs 285 | Pending-stop state machine vs abort/terminate orchestration |

`server/scripts/architecture-layer-rules.mjs` matches session runtime files with `/server\/src\/session-[^/]+\.ts$/`. Folder moves break that check until the regex and ~40 import sites update together.

**Trace façade (already split)**

| Path | Lines |
|------|------:|
| `server/src/trace.ts` | 1,047 |
| `server/src/trace-paging.ts` | 1,151 |
| `server/src/trace-outline.ts` | 542 |
| `server/src/session-trace-service.ts` | 646 |
| `server/src/routes/session-trace-handlers.ts` | 564 |
| **sum** | **3,950** |

Paging and outline each have a `traceVersionFor` helper and similar tree walks. Merging them would recreate a 2k+ module.

**Session.id migration (new since prior report)**

| Path | Lines |
|------|------:|
| `session-id-migration-executor.ts` | 1,393 |
| `session-id-migration-inventory.ts` | 1,347 |
| `session-id-migration-planner.ts` | 922 |
| `session-id-migration-snapshot.ts` | 255 |
| `session-id-migration-merge.ts` | 180 |
| tests (`executor`/`inventory`/`planner`) | 3,299 |
| **prod + tests** | **7,396** |

Header states it never writes the live data directory. This is cutover machinery, not stream complexity.

**Apple — largest production modules**

| Path | Lines | Notes |
|------|------:|-------|
| `clients/apple/Oppi/Core/Views/FullScreenCodeBodies.swift` | 2,907 | Code/diff/terminal/source bodies in one file |
| `clients/apple/Oppi/App/ScreenshotPreviewView.swift` | 2,843 | Screenshot harness, not product UI |
| `clients/apple/Oppi/Core/Networking/ServerConnection.swift` | 2,599 | Connection composition root |
| `clients/apple/Shared/Renderers/Mermaid/MermaidFlowchartRenderer.swift` | 2,560 | Shared renderer |
| `clients/apple/Oppi/Features/Chat/Timeline/Tool/ToolTimelineRowContent.swift` | 2,508 | Tool row host |
| `clients/apple/Oppi/Core/Networking/APIClient.swift` | 2,476 | HTTP actor; domain split only partial |
| `clients/apple/Oppi/Features/Chat/ChatView.swift` | 2,264 | Chat shell orchestration |
| `clients/apple/Oppi/Core/Views/MarkdownText.swift` | 2,203 | Assistant markdown |
| `clients/apple/Oppi/Features/Workspaces/SessionInboxView.swift` | 2,078 | Inbox **plus** `WorkspaceSidebarView` and stack root in the same file |
| `clients/apple/OppiCore/Runtime/TimelineReducer.swift` | 2,045 | Platform-neutral reducer |
| `clients/apple/Oppi/Features/Chat/Support/ExtensionSurfacePanel.swift` | 1,895 | Generic extension surfaces |
| `clients/apple/Oppi/Features/Chat/Session/ChatSessionManager.swift` | 1,853 | Per-session stream/cache/coalescer owner |
| `clients/apple/Oppi/Features/Workspaces/WorkspaceDetailView.swift` | 1,374 | Workspace recent + archive buckets |
| `clients/apple/Oppi/App/AppNavigation.swift` | 1,163 | Explicit stack vs split state |
| `clients/apple/Oppi/Core/Networking/WebSocketClient.swift` | 1,043 | Focused-session WS |

**Apple clusters**

| Cluster | Files | Lines |
|---------|------:|------:|
| `Features/Chat/Timeline/Tool/` | 32 | 10,213 |
| `Features/Chat/Timeline/` | 75 | 24,630 |
| `ServerConnection.swift` + `ServerConnection+*.swift` + types | 10 | 6,248 |
| `APIClient.swift` + `APIClient+Agents.swift` + `APIClient+ServerResources.swift` + env | 4 | 3,081 |

`APIClient.swift` MARK sizes (approximate, from section starts): Workspace-scoped Sessions 440 lines; Authorization 325; Sessions (search/catch-up helpers) 274; Workspace File Browser 188; Private helpers 188; Skills 138; Git 134; Tool Output & Files 112.

**pi-extensions / server extensions**

| Path | Lines | Status |
|------|------:|--------|
| `pi-extensions/oppi-mirror/extensions/oppi-mirror.ts` | 5,334 | Load-bearing terminal bridge |
| `pi-extensions/goal/extensions/goal.ts` | 1,256 | Documented **disabled prototype**; canonical goal is external `pi-goal` |
| `server/extensions/voice.ts` | 1,008 | Server Pi extension (TTS) |
| `pi-extensions/ask/extensions/ask-terminal.ts` | 800 | Portable ask example |
| `pi-extensions/browser-automation-video/extensions/browser-automation-video.ts` | 794 | Documented example |
| `pi-extensions/working-words/index.ts` | 95 | Demo status/widget |
| `server/extensions/built-ins.ts` | 8 | `MANAGED_EXTENSION_NAMES = []`; still called from `extension-loader.ts` |

Mirror contract is duplicated on purpose and locked: `pi-extensions/oppi-mirror/extensions/oppi-mirror-contract.ts` (97) vs `server/src/pi-tui-mirror-contract.ts` (55), asserted by `server/tests/pi-tui-mirror-contract.test.ts` (95). Mirror queue tests: `server/tests/pi-tui-mirror-runtime-queue.test.ts` (2,675).

**Protocol**

| Path | Lines |
|------|------:|
| `server/src/types/protocol.ts` | 595 |
| `clients/apple/OppiCore/Models/ServerMessage.swift` | 767 |
| `clients/apple/OppiCore/Models/ClientMessage.swift` | 461 |
| `clients/apple/OppiCore/Models/AppEventMessage.swift` | 229 |
| `protocol/server-messages.json` | 876 (generated) |
| `protocol/app-event-messages.json` | 420 (generated) |
| `protocol/pi-events.json` | 323 (hand-written; **no test reads this file**) |
| `server/tests/protocol-fixtures.ts` | 899 |
| `server/tests/session-protocol.test.ts` | 2,807 |

**CI / scripts**

| Path | Lines |
|------|------:|
| `.github/workflows/apple.yml` | 140 |
| `.github/workflows/server.yml` | 115 |
| `.github/workflows/hygiene.yml` | 76 |
| `scripts/detect-ci-relevant-paths.sh` | 134 |
| `clients/apple/scripts/sim-pool.sh` | 1,322 |
| `clients/apple/scripts/ci-simulator.sh` | 967 |
| `clients/apple/scripts/check-coverage.sh` | 377 |
| `scripts/duplication-scan.ts` | 670 (local; not a CI job) |
| `.githooks/pre-push` | 433 |
| `scripts/pre-push-plan.ts` | 187 |
| `server/scripts/testing-gates.ts` | 217 |

Apple CI: `macos-26`, Xcode 26.6, 40 minute timeout, `OPPI_CI_SIM_SILENCE_TIMEOUT=300`, `OPPI_CI_SIM_RETRY_DEADLINE=900`. Server CI: Ubuntu, Node 24.15, Bun 1.3.11, 20 minute timeout. `bench:hotpath` is **not** in GitHub Actions.

**Largest tests (feature locks unless noted)**

| Path | Lines |
|------|------:|
| `clients/apple/OppiTests/Markdown/MarkdownTextTests.swift` | 3,812 |
| `server/tests/sdk-backend.test.ts` | 2,892 |
| `server/tests/session-protocol.test.ts` | 2,807 |
| `server/tests/pi-tui-mirror-runtime-queue.test.ts` | 2,675 |
| `server/tests/cli.test.ts` | 2,584 |
| `clients/apple/OppiTests/Network/ServerConnectionTests.swift` | 2,458 |
| `clients/apple/OppiTests/Chat/ChatSessionManagerTests.swift` | 2,427 |
| `clients/apple/OppiE2ETests/ExtensionUISnapshotLabE2ETests.swift` | 1,838 | Harness; not in Apple coverage job |
| `clients/apple/Oppi/App/ScreenshotPreviewView.swift` | 2,843 | Screenshot lab |

`clients/apple/OppiTests/Network/ServerConnectionLifecycleTests.swift` is now **711** lines (was 3,485 at the prior agent’s commit).

---

### 2. Maintainability simplifications, ranked

#### 1. Finish `APIClient` domain splits
- **Paths:** `clients/apple/Oppi/Core/Networking/APIClient.swift` (2,476), existing `APIClient+Agents.swift` (457), `APIClient+ServerResources.swift` (126)
- **Impact:** Navigability of the HTTP actor; matches `docs/architecture-client.md` cleanup target
- **Risk:** Low if new files stay `extension APIClient` on the same actor and private request helpers stay in the main file
- **Effort:** Small–medium
- **Why:** Domain split already started, then the main file grew (2,238 → 2,476 since the prior report). Safest next slices: Git (~134), files/browser (~300), workspace-scoped sessions (~440)
- **What not to merge:** Do not fold `+Agents` / `+ServerResources` back. Do not split TLS/`request()`/auth helpers first

#### 2. Split data catalogs that are not logic
- **Paths:** `server/src/routes/registry.ts` (1,280), `server/src/cli/help.ts` (1,811)
- **Impact:** Smaller diffs when adding a route or CLI topic
- **Risk:** Low — `registry.ts` is a static spec list; `help.ts` is `HELP_TOPICS` plus renderers. Dispatch stays in `routes/index.ts` (66) and `cli.ts` (1,143)
- **Effort:** Small
- **Why:** Prior “split registry” claim is still valid. Help is now larger than `cli.ts`
- **What not to merge:** Do not merge registry into `index.ts`. Do not move help *rendering* into command modules until topics are split

#### 3. File-split sibling views already in one file
- **Paths:** `SessionInboxView.swift` (2,078) contains `WorkspaceSidebarView` (~line 1440) and `WorkspaceSessionInboxStackRootView` (~line 1250); `FullScreenCodeBodies.swift` (2,907) has MARK sections for code (629), diff (1,091), terminal (1,348), source (292)
- **Impact:** Reviewability without changing navigation or preview behavior
- **Risk:** Low if types move unchanged; medium if sidebar presentation state is rewritten
- **Effort:** Small
- **Why:** These are already separate types. Prior report treated inbox as one fat view; the file is a bundle
- **What not to merge:** Do not combine sidebar into `WorkspaceDetailView`. Do not merge fullscreen body types

#### 4. Extract already-exported SDK cwd helpers
- **Paths:** `server/src/sdk-backend.ts` (2,173), ~17 importers of `resolveSdkSessionCwd` / sandbox cwd / prompt builders
- **Impact:** Shrink the SDK module without touching `createRuntimeFactory`
- **Risk:** Medium if prompt rebuild is pulled out of the factory closure (`buildCurrentAppendSystemPrompt` reads live `oppiSettingsHolder` around sdk-backend.ts:849)
- **Effort:** Small for cwd; medium for prompt; high for tool policy + factory
- **Why:** CWD helpers (roughly lines 113–234) are already public. Tool policy and the ~470-line factory closure share locals (control/sandbox Oppi/allowlists)
- **What not to merge:** Do not chop tool policy and factory in the same PR. Do not share this with mirror ownership

#### 5. `session-*` folders, no merges
- **Paths:** 38 files under `server/src/session-*.ts`; `server/scripts/architecture-layer-rules.mjs:268-271`
- **Impact:** Naming (`lifecycle`×2, `stop`×2) becomes obvious
- **Risk:** Medium — import churn plus boundary-regex update; easy to miss a test import
- **Effort:** Medium (mechanical but wide)
- **Why:** Confirmed confusing siblings. Architecture forbids merging lifecycle/list/trace services
- **What not to merge:** Any of those services. Do not put coordinators and HTTP services in one file “to reduce count”

#### 6. Chat / workspace-detail controllers
- **Paths:** `ChatView.swift` (2,264), `WorkspaceDetailView.swift` (1,374)
- **Impact:** Moves `@State` orchestration out of SwiftUI structs, as docs already suggest
- **Risk:** Medium — sheet/lifecycle bindings are cross-cutting; ChatView is not the timeline renderer (`ChatSessionManager` is)
- **Effort:** Medium
- **Why:** Real fat views. Inbox is a better first extract (item 3) because sibling types already exist
- **What not to merge:** Do not inline `ChatSessionManager` into `ChatView`

#### 7. Share mirror coordinator bootstrap only
- **Paths:** `pi-tui-mirror-runtime.ts` constructor ~521–604 vs `session-coordinators.ts` `createSessionCoordinatorBundle` (99–278)
- **Impact:** Removes ~60 lines of duplicated wiring
- **Risk:** High — mirror stubs stop (`finishPendingStopOnAgentEnd: () => {}`), sends commands over the bridge, has queue version constants and idle eviction (~1803–1814)
- **Effort:** Medium, high verification cost (`pi-tui-mirror-runtime-queue.test.ts` is 2,675 lines)
- **Why:** Duplication is real; ownership must stay split (`SessionRuntimes`, 149 lines)
- **What not to merge:** Managed `SessionManager` with `PiTuiMirrorRuntime`. Do not share projection *and* ownership

#### 8. Leave `ServerConnection` and `AppNavigation` alone for now
- **Paths:** `ServerConnection*.swift` (6,248), 14 `OppiTests/Network/ServerConnection*.swift` files; `AppNavigation.swift` (1,163)
- **Impact of touching them:** High regression surface (transport races; iPhone stack vs iPad split)
- **Risk:** Highest
- **Effort:** Large
- **Why:** Extensions already isolate refresh, routing, ask, fork, app events. Dual stack/split is explicit (`WorkspaceNavigationPresentation`)
- **What not to merge:** Extensions back into the main class; stack path into split path

#### 9. Goal prototype / empty managed-extension stub (optional later)
- **Paths:** `pi-extensions/goal/` (1,256 + 827 tests); `server/extensions/built-ins.ts` (8)
- **Impact:** Less dead-looking code
- **Risk:** Medium for goal (docs say keep until pi-goal compaction/snapshot audit). Low for empty `MANAGED_EXTENSION_NAMES` if the `extension-loader.ts:385` hook stays for a future name
- **Effort:** Small
- **Why:** Goal is disabled-on-purpose, not leftover related-work. `related-work` has **zero** remaining matches after `5bf67d3a`
- **What not to merge:** Do not enable `pi-extensions/goal` beside `pi-goal`. Do not delete voice (1,008) or ask/mirror

---

### 3. Performance opportunities, ranked, with evidence

No production traces or Instruments runs were taken here. Numbers below are either checked-in baselines, constants in code, or explicitly **unmeasured**.

#### Already paid for (do not “simplify” away)

- **Delta coalescing:** `DeltaCoalescer.swift` (676) flushes `textDelta` / `thinkingDelta` / `toolOutput` about every **50ms**, caps **512 events** and **256KB**, pauses on background. Comment at lines 35–51
- **Broadcast fan-out:** `session-broadcast.ts:193-195` skips EventEmitter for high-frequency text/thinking/tool_output/tool_update
- **Translation allocs:** `session-protocol.ts:771-777` shared `EMPTY_MESSAGES`; `computeToolOutputUpdate` hoisted out of `translatePiEvent`
- **Tool row streaming:** `ToolTimelineRowContent.swift:112-118` fixed **200pt** streaming viewport to avoid nested-scroll invalidation
- **Render cache:** `ToolRowRenderCache.swift` `countLimit = 128`, `totalCostLimit = 8 * 1024 * 1024`
- **Tool output off the row:** `ToolOutputStore.swift` ≤500 char preview on `ChatItem`, **16MB** FIFO for full text
- **Layout coalescing:** `ToolTimelineRowHelpers.swift:251-255` one invalidate per runloop tick
- **Markdown cache:** `MarkdownText.swift:29-36` 128 entries, 1MB total, 16KB/entry
- **Telemetry noise floor:** `ChatTimelinePerf.swift:302-304` skip sub-1ms cell telemetry because `Task.detached` exceeds the sample; `MetricKitModels.swift` documents removed `wsDecodeMs` (“32% of samples, almost always 0ms”)
- **Local JSONL catalog:** `local-sessions.ts:219-223` mtime cache; author comment “stat ~0.01ms per file” — **not independently measured here**
- **List path:** architecture forbids rereading `~/.pi/agent/sessions/*.jsonl` on hot workspace endpoints

#### Measured (in-process microbench suite, not a live session)

From `server/bench/baselines/server-hotpath.metrics`. `total_avg_us=69.98` is the **sum of category aggregates**, including synthetic worst cases, not TTFT of a real turn.

| Metric | µs | Implication |
|--------|---:|-------------|
| `sanitize_us` | 37.07 | Dominated by `sanitize_chart_1000rows_avg_us=28.37` and `sanitize_chart_200rows_avg_us=8.59` |
| `sanitize_simple_details_avg_us` | 0.06 | Production-like details without `ui` |
| `sanitize_null_avg_us` | 0.05 | |
| `ring_us` | 14.15 | Dominated by `ring_push_500_avg_us=13.16` |
| `ring_push_single_avg_us` | 0.10 | |
| `translate_us` | 8.38 | |
| `translate_text_delta_avg_us` | 0.20 | Streaming text |
| `translate_full_turn_avg_us` | 3.68 | |
| `ansi_us` | 8.48 | |
| `renderer_us` | 1.67 | |
| `broadcast_us` | 0.25 | |
| `broadcast_durable_avg_us` | 0.15 | |
| `broadcast_ephemeral_avg_us` | 0.10 | |

`server/src/visual-schema.ts` (43 lines) **drops** `details.ui` chart payloads; comments say Oppi does not render them. The 28µs chart case is a sanitizer that copies a record to strip an unsupported field. **Do not treat 37µs as live stream cost.**

Gate: `npm run bench:hotpath:gate` fails median avg metrics if they regress **>15%** (absolute **+0.05µs** when baseline ≤0.2µs). This gate is **not** in `.github/workflows/server.yml`.

#### Ranked opportunities

1. **Keep the hot-path bench honest** — **unmeasured in CI.** If chart sanitizer cases dominate `total_avg_us`, a real translate/broadcast regression can hide. Evidence: baseline composition above; `visual-schema.ts:4-6,24-26`. Risk of changing the suite: medium (gate comparisons). Not a user-visible feature change if production still drops `details.ui`.

2. **EventRing 500-entry fill** — measured **13.16µs avg** for `ring_push_500`. Live catch-up uses this structure (`event-ring.ts`, exercised by the bench). Whether production reconnects fill 500 entries is **unmeasured**. Do not shrink the ring without checking catch-up completeness (`docs/architecture.md` focused-session catch-up).

3. **Trace page stringify/gzip** — **unmeasured.** `trace-paging.ts` records `readMs`/`parseMs`/`formatMs`; `session-trace-handlers.ts:341-352` records `stringifyMs`/`gzipMs`. No checked-in baselines. Opening a long session is the likely user-visible cost, not token deltas (0.20µs translate).

4. **Client timeline apply/layout** — **unmeasured here.** Code documents thresholds in `ChatTimelinePerf.swift`: slow apply/layout **24ms**, cell configure **8ms**, guardrail apply/layout **250ms**, jank hitch **>16ms**. Mermaid perf tests document pipeline large flowchart **<16ms** (`OppiPerfTests/MermaidPerfBench.swift`). Apple perf bundle is **not** in hosted coverage.

5. **SDK session create** — **unmeasured.** `sdk-backend.ts` records `server.session_create_sdk_ms` / `server.session_create_bind_ms` (~1289–1296 per earlier read). Not in the hotpath bench.

6. **Attachment / media copies** — **unmeasured.** Path: `session-attachments.ts` (1,125), HTTP range (`http-range.ts`), Apple `AuthenticatedMediaSource`. WS is not supposed to carry raw media (`docs/architecture-client.md`).

7. **Extension UI chatter** — **unmeasured.** Mirror extension is 5,334 lines because it proxies UI/queue; app-event stream is allowlisted and must not carry timeline deltas (`docs/architecture-server.md`). Splitting the extension file would not reduce WS traffic by itself.

8. **N+1 HTTP** — no N+1 loops found in list/inbox code. Inbox uses summary projections; archive buckets load on demand (`WorkspaceDetailView`). Refresh coalescing exists on `ConnectionCoordinator` (tests). **Unmeasured** request counts on a real inbox open.

9. **sim/CI cost** — Apple job: 40 min timeout on `macos-26`; silence 300s; retry deadline 900s. Unifying `sim-pool.sh` (1,322) and `ci-simulator.sh` (967) would touch hosted first-boot vs erase policy. **That is the current Apple CI flake surface; do not merge those scripts as a “simplification.”** Path filtering already skips Apple coverage when the PR does not touch Apple/protocol globs.

10. **Session.id migration** — 4,097 production lines. Offline/disposable copy. Not a stream optimization target.

---

### 4. What NOT to touch

| Area | Why it is still load-bearing |
|------|------------------------------|
| Managed vs mirror runtimes (`SessionRuntimes` / `runtime-router.ts` 149) | Different execution owners; architecture forbids silent SDK start for `runtime == "pi-tui"` |
| `SessionLifecycleService` vs `SessionListService` vs `SessionTraceService` | Docs + boundary script; different data and failure modes |
| Server ↔ Apple protocol dual types | Manual mirrors + snapshot tests; no codegen. Partial updates fail at the transport boundary |
| Compatibility: `sqlite-compat.ts` (147), SQLite schema migrations in `session-sqlite-store.ts`, `dt_` device-token migration (`cli.ts` / device-auth; E2E commit `87cd49f3` still needs it), `KeychainService.migrateLegacyServersToSharedGroup`, `ComposerDraftStore.stageLegacyDraft`, voice metric tag aliases (`ui_locale` duplicates `locale`) | Still on upgrade paths |
| Generic extension UI metadata rule | `ExtensionSurfacePanel` is status/tone/widget-size driven. Built-in Pi tools (`bash`/`read`/…) still branch in `ToolPresentationBuilder.swift` (786) and `ChatSessionManager.swift:989` (`voice_reply_mode`). New **extensions** must not add name switches |
| Tool streaming policy / render strategies | Intentional perf isolation; merging back into `ToolTimelineRowContent` would undo 10k of extracted strategy code |
| `DeltaCoalescer` vs `TimelineReducer` vs `ServerConnection` | Separate layers; comments warn against putting timeline in the connection root |
| AppNavigation stack vs split | Parallel state machines; comment around navigation replacement vs stream stealing |
| `pi-extensions/goal` deletion without the pi-goal audit | Docs: compaction recovery / snapshot migration still pending |
| `oppi session wait` internals in `cli/commands/session-watch.ts` (403) | Public `watch` is gone (`cb580b87`); wait still imports the poller |
| Pairing | Live: `oppi pair`, `/pair`, Nearby pairing, e2e pairing tests. Iroh **code** is gone from `main`; leftover user copy in What’s New / CHANGELOG only |
| Unifying `sim-pool.sh` and `ci-simulator.sh` | Different erase/boot contracts; would intersect hosted-sim flake |
| Protocol codegen / merging TS and Swift models | Checklist in `docs/architecture-server.md` exists because drift is dangerous |
| Session.id migration rewrite into sqlite-store | Isolated on purpose; executor refuses live data dir |

---

### 5. Suggested first 3 moves

1. **`APIClient+Git.swift` / `APIClient+Files.swift` (then workspace-sessions)** — lowest behavior risk, docs already prescribe it, main file grew after the last report.
2. **Split `routes/registry.ts` and `cli/help.ts` by domain** — data-only; keep one concatenated export / one help renderer.
3. **Move `WorkspaceSidebarView` (and stack root) out of `SessionInboxView.swift`; split `FullScreenCodeBodies.swift` by MARK** — types already exist; no navigation rewrite.

Stop there before sdk-backend factory, session-* folders, mirror bootstrap sharing, ChatView controllers, or ServerConnection.

Do **not** start a CI redesign. Path filters, required summary jobs, and separate sim runners are doing real work. Optional later: make `bench:hotpath` a non-flaky server job only if the suite’s `total_avg_us` is reweighted away from dropped `details.ui` charts.

---

### 6. Prior-agent claim audit

Prior agent: `bc-01a00d24-a581-7863-9ba9-6a58800e9353` (“Repository simplification opportunities”), measured at `cf39d641`. Current `main` is `87cd49f3` after the 17–19 Aug 2026 landings (Session.id migration, related-work add+remove, Iroh leftover cleanup, session watch removal, TestFlight 46, sandbox Oppi, CI simulator reboot, etc.).

| Claim | Verdict | Current evidence |
|-------|---------|------------------|
| `sdk-backend.ts` ~2.2k — split helpers (cwd, system prompt, tool policy) | **Confirmed** (size slightly stale) | **2,173** lines (was 2,194). CWD extract still safest; tool policy + factory still entangled |
| `pi-tui-mirror-runtime.ts` ~2.1k — share bootstrap with managed; keep ownership separate | **Confirmed** (size slightly stale) | **2,082** (was 2,093). Constructor still hand-wires coordinators; `SessionRuntimes` still the ownership façade |
| ~35 `session-*` files flat; lifecycle×2, stop×2 — folder-group only | **Stale count, confirmed shape** | **38** `session-*.ts` files (added `session-command-parse.ts`, `session-jsonl-meta.ts`, `session-runtime-capabilities.ts`). Collisions still real and still different layers |
| Trace façade ~4k (trace + paging + outline + service + handlers) | **Confirmed as a sum** | **3,950** exact (`1047+1151+542+646+564`). Prior ~4k was an estimate; they had not `wc`’d outline/service/handlers. **Do not merge** — already split |
| `routes/registry.ts` ~1.3k | **Confirmed** | **1,280** (was 1,286). Still a catalog, not a router (`index.ts` is 66) |
| `server.ts` / `cli.ts` / `help.ts` still large | **Confirmed; help grew** | server **1,465** (was 1,524), cli **1,143** (was 1,147), help **1,811** (was 1,722) |
| `APIClient.swift` ~2.2k — split via `APIClient+*.swift` | **Stale size, confirmed advice** | **2,476** (was 2,238). `+Agents` / `+ServerResources` exist; main file grew |
| Tool timeline stack ~10k under `Timeline/Tool/`; `ToolTimelineRowContent` ~2.5k | **Confirmed** | Directory **10,213** lines / 32 files (prior did not measure the directory). Row content still **2,508** |
| ChatView / inbox / workspace detail are fat views | **Confirmed** | ChatView **2,264**, SessionInboxView **2,078** (file also includes sidebar), WorkspaceDetailView **1,374** |
| AppNavigation dual stack/split | **Confirmed** | **1,163** lines; `WorkspaceNavigationPresentation` stack/split still explicit |
| ServerConnection ~3k + extensions (highest risk) | **Stale size, confirmed risk** | Main file **2,599** (was 3,035); cluster **6,248**. Still highest-risk client root |
| ExtensionSurfacePanel ~2.2k / fullscreen bodies ~2.9k | **Stale panel size, confirmed bodies** | Panel **1,895** (was 2,223); `FullScreenCodeBodies.swift` **2,907** (was 2,901) |
| Managed vs mirror must stay separate | **Confirmed still load-bearing** | `runtime-router.ts` + architecture-server “Runtime ownership” |
| Lifecycle / list / trace services must stay separate | **Confirmed** | Docs “Server cleanup targets” + layer rules |
| Server ↔ Apple protocol dual types | **Confirmed** | `protocol.ts` 595 vs Swift models; snapshots generated for server/app-event only |
| Compatibility shims still needed | **Confirmed** | sqlite-compat, `dt_` E2E, keychain/draft migrations, voice tag aliases |
| Tool-name branching in UI should stay protocol-metadata driven | **Confirmed rule; built-in exceptions remain** | Extension surfaces metadata-driven; `ToolPresentationBuilder` still switches Pi built-ins; `voice_reply_mode` in `ChatSessionManager` |
| *(implied)* `iroh-pairing-server.ts` ~829 as a large server file | **Stale / gone** | File absent on `main`. Iroh pairing removed; leftover strings are What’s New / CHANGELOG |
| *(unpublished measurement)* ServerConnectionLifecycleTests 3,485 | **Stale** | Now **711** |
| Performance | **Not covered by prior agent** | This report; they had no runtime numbers |
| CI / protocol snapshots / pi-extensions / dead code | **Under-covered by prior agent** | related-work fully gone; public `session watch` gone; pairing live; `pi-events.json` unused by tests; goal disabled prototype; session-id-migration **4,097** prod lines not mentioned |

**Prior list as prescription:** still a decent map for *file splits*, incomplete as a *system* map. Highest new complexity they missed: Session.id migration suite, `session-protocol.ts` (1,524, hot path), `search-index.ts` (1,183), `architecture-layer-rules.mjs` (1,192), mirror extension (5,334), and sim-pool/ci-simulator overlap (2,289 lines) which must not be “simplified” into the Apple CI flake.
