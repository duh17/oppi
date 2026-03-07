# ARCHITECTURE.md

This is a map of the code that exists today.

- If this document and code disagree, code wins.
- This document is intentionally mechanical: files, entry chains, dependency directions, and data flow.

Oppi has two runtimes in one repo:

- `server/` — Node.js/TypeScript server embedding pi SDK sessions in-process.
- `ios/` — iOS app (SwiftUI + UIKit) supervising sessions over `/stream` + REST.

---

## High-level overview

A user action in iOS becomes a `ClientMessage`, goes to `server/src/ws-message-handler.ts`, is routed into `SessionManager` coordinators, then pi SDK emits agent events. Those events are translated to `ServerMessage` (`session-protocol.ts`), sequenced (`session-broadcast.ts`, `event-ring.ts`), multiplexed (`stream.ts`), decoded on iOS (`ServerMessage.swift` / `StreamMessage`), coalesced (`DeltaCoalescer.swift`), reduced (`TimelineReducer.swift`), and rendered by `ChatTimelineView` through `Features/Chat/Timeline/Collection/ChatTimelineCollectionView.swift`.

---

## Server architecture (`server/src`)

### Entry chain and composition root

1. `server/src/cli.ts`
   - `main()` parses command/flags.
   - `cmdServe()` creates `Storage`, then `new Server(storage, apnsConfig)` and calls `server.start()`.
2. `server/src/server.ts` (composition root)
   - Wires `SessionManager`, `PolicyEngine`, `RuleStore`, `GateServer`, `AuditLog`, `SkillRegistry`, `UserSkillStore`, `UserStreamMux`, `WsMessageHandler`, `RouteHandler`, `LiveActivityBridge`, push client.
   - Owns HTTP server + WS upgrade handling.
3. `Server.handleHttp(...)`
   - Handles CORS/health/auth, then delegates to `RouteHandler.dispatch(...)`.
4. `Server.handleUpgrade(...)`
   - Only upgrades `/stream` (per-session WS endpoint is removed).
   - Delegates WS runtime to `UserStreamMux.handleWebSocket(...)`.
5. Session startup path from stream subscribe:
   - `stream.ts` (`subscribe` level=`full`) -> `sessions.startSession(...)`
   - `sessions.ts` -> `SessionActivationCoordinator` -> `SessionStartCoordinator.startSessionInner(...)` -> `SdkBackend.create(...)`.

### Dependency direction rules (current code)

These are the observed directions in imports/calls today:

1. **Single composition root**
   - `server.ts` imports and wires subsystems.
   - Subsystems do not import `server.ts`.

2. **Route layer is boundary-only**
   - `routes/*` depend on `RouteContext` services (`SessionManager`, `Storage`, `GateServer`, etc.).
   - Core session/policy/storage modules do not import `routes/*`.

3. **Stream mux delegates command execution, does not own session command logic**
   - `stream.ts` delegates non-subscription client messages via injected `handleClientMessage` (wired to `WsMessageHandler`).
   - `ws-message-handler.ts` delegates runtime operations to `SessionManager`/`GateServer`.

4. **Session runtime is decomposition-by-coordinator with a facade**
   - `sessions.ts` owns top-level orchestration.
   - `session-coordinators.ts` wires `session-*.ts` coordinators.
   - `session-*.ts` modules do not import `sessions.ts`.

5. **Rule evaluation flow is one-way**
   - `gate.ts` depends on `policy.ts` + `rules.ts` + `audit.ts`.
   - `policy.ts` does not import `gate.ts`.

6. **Storage layer is leaf infrastructure**
   - `storage/*.ts` are used by higher layers.
   - Storage modules do not import session/route/stream modules.

7. **Protocol contract file is a leaf**
   - `types.ts` is the canonical protocol/domain contract.
   - `types.ts` does not import from sibling modules.

8. **Permission gate stays out of session runtime**
   - `gate.ts` may depend on policy/rules/audit layers.
   - `gate.ts` does not import `sessions.ts` or `session-*.ts` runtime modules.

### Module inventory (one-line purpose)

#### Composition, transport, and boundaries
- `cli.ts` — CLI entry and command dispatch (`serve`, `pair`, `status`, `doctor`, `config`).
- `server.ts` — HTTP/WS server composition root and runtime wiring.
- `stream.ts` — `/stream` multiplexed WS subscriptions + user-level replay ring.
- `ws-message-handler.ts` — routes inbound WS client messages to session/gate actions.
- `types.ts` — canonical server/client protocol + shared domain types.

#### Session runtime decomposition
- `sessions.ts` — session facade API (start/stop/prompt/queue/commands/catch-up).
- `session-coordinators.ts` — coordinator bundle wiring.
- `session-start.ts` — constructs active session state + `SdkBackend`.
- `session-activation.ts` — start dedupe + session lock gating.
- `session-input.ts` — prompt/steer/follow_up ingress + turn intent tracking.
- `session-turns.ts` — turn ack stage progression (`accepted`/`dispatched`/`started`).
- `session-queue.ts` — queue sync (`get_queue`/`set_queue`) + dequeue reconciliation.
- `session-queue-utils.ts` — queue normalization/cloning helpers.
- `session-commands.ts` — command allowlist + SDK command forwarding.
- `session-agent-events.ts` — SDK event handling + broadcast/state updates.
- `session-events.ts` — extension UI request handling + session mutation from events.
- `session-protocol.ts` — pure pi-event -> `ServerMessage` translation + stats helpers.
- `session-state.ts` — apply `get_state` snapshots + persisted thinking/model updates.
- `session-stop.ts` — pending stop state machine + timeout escalation logic.
- `session-stop-flow.ts` — abort vs terminate stop flows.
- `session-lifecycle.ts` — idle timers + teardown/release lifecycle.
- `session-ui.ts` — extension UI response routing to SDK.
- `session-broadcast.ts` — per-session subscribers + durable sequencing/replay.

#### SDK bridge and runtime guards
- `sdk-backend.ts` — wraps pi `AgentSession` creation, prompting, extension UI context.
- `workspace-runtime.ts` — session/workspace mutexes + slot limits.
- `turn-cache.ts` — LRU+TTL idempotency cache for client turn IDs.
- `pi-events.ts` — typed SDK event/state parsing utilities.
- `event-ring.ts` — bounded sequenced event ring for catch-up.

#### Policy and permission system
- `policy.ts` — policy engine evaluation pipeline.
- `policy-presets.ts` — declarative policy compilation + default preset config.
- `policy-heuristics.ts` — heuristic checks (pipe-to-shell, data egress, secret access).
- `policy-bash.ts` — bash parsing/splitting/matching helpers.
- `policy-types.ts` — policy/request/decision type definitions.
- `policy-approval.ts` — normalization of approval action+scope options.
- `policy-allowlist.ts` — fetch domain allowlist file management.
- `gate.ts` — in-process permission gate and pending approval lifecycle.
- `rules.ts` — persisted + session-scoped rule store.
- `audit.ts` — append-only policy audit log.

#### HTTP route modules
- `routes/index.ts` — authenticated route dispatcher composition.
- `routes/types.ts` — route context/dispatcher contracts.
- `routes/http.ts` — route helper primitives (`parseBody`, `json`, `error`).
- `routes/identity.ts` — `/pair`, `/me`, `/models`, `/server/info`, device token endpoints.
- `routes/workspaces.ts` — workspace CRUD, graph, git status, local session discovery endpoint.
- `routes/sessions.ts` — workspace-scoped session CRUD/resume/fork/stop/events/trace/files/tool-output/diff/client-logs.
- `routes/streaming.ts` — `/stream/events`, pending permissions, permission response endpoint.
- `routes/skills.ts` — skill listing/detail/file access and user-skill read-only APIs.
- `routes/policy.ts` — fallback/rules/audit APIs.
- `routes/themes.ts` — theme list/get/put/delete APIs.
- `routes/theme-convert.ts` — pi theme -> Oppi theme conversion.
- `routes/telemetry.ts` — MetricKit + chat metric ingestion and retention pruning.
- `routes/__tests__/theme-convert.test.ts` — converter correctness tests.

#### Storage and host integration
- `storage.ts` — storage facade over config/auth/preferences/sessions/workspaces.
- `storage/config-store.ts` — config validation/defaulting/persistence.
- `storage/auth-store.ts` — pairing/auth/push token state.
- `storage/preference-store.ts` — per-model thinking level preferences.
- `storage/session-store.ts` — session file CRUD.
- `storage/workspace-store.ts` — workspace file CRUD + default workspace seeding.
- `skills.ts` — built-in skill registry + user skill store.
- `extension-loader.ts` — host extension discovery and workspace extension resolution.
- `host.ts` — host project directory discovery for workspace creation UX.
- `host-env.ts` — runtime env/path resolution and process env application.
- `local-sessions.ts` — local pi session discovery + path/cwd validation.
- `model-catalog.ts` — model list/context-window catalog from SDK registry.

#### Observability, security, and support utilities
- `tls.ts` — TLS mode resolution + self-signed/tailscale cert preparation.
- `security.ts` — server identity key material + fingerprint derivation.
- `push.ts` — APNs push sender client.
- `live-activity.ts` — debounced Live Activity update bridge.
- `trace.ts` — JSONL trace parsing and context reconstruction.
- `graph.ts` — workspace session/entry graph assembly from trace/session files.
- `overall-diff.ts` — derive file baseline + line diff from trace mutations.
- `visual-schema.ts` — sanitize dynamic visual payloads (`details.ui`, charts).
- `git-status.ts` — git status extraction for workspace roots.
- `mobile-renderer.ts` — server-side styled tool segment rendering for mobile UI.
- `qr.ts` — terminal QR code encoding/rendering.
- `log-utils.ts` — compact timestamp helper.
- `ansi.ts` — ANSI text helpers.
- `glob.ts` — glob matcher utility.
- `id.ts` — URL-safe ID generator.

### Cross-cutting concerns

- **Durable replay:**
  - Session-level: `session-broadcast.ts` + `event-ring.ts`.
  - User-stream-level: `stream.ts` keeps `streamSeq` ring for `/stream/events`.
- **Security posture at startup:**
  - `validateStartupSecurityConfig(...)` + `formatStartupSecurityWarnings(...)` in `server.ts`.
  - TLS setup in `tls.ts`; identity material in `security.ts`.
- **Policy + approval auditability:**
  - `gate.ts` + `policy.ts` + `rules.ts` + `audit.ts`.
- **Telemetry ingestion:**
  - `routes/telemetry.ts` (`/telemetry/metrickit`, `/telemetry/chat-metrics`).
- **Push and live activity fanout:**
  - `push.ts` + `live-activity.ts`, wired from `server.ts` and `sessions.ts` events.

---

## iOS architecture (`ios/Oppi`)

### Layer map (current imports and call paths)

```text
Core/Models
  ├─ ClientMessage.swift
  └─ ServerMessage.swift (+ StreamMessage, SessionScopedMessage)

Core/Networking
  ├─ APIClient (REST)
  ├─ WebSocketClient (/stream transport, reconnect, ping)
  ├─ SessionStreamCoordinator (actor: stream lifecycle + recovery state machine)
  └─ ServerConnection (+ MessageRouter/Refresh/ModelCommands/Fork; transport + routing)

Core/Runtime
  ├─ DeltaCoalescer (33ms batch for high-frequency deltas)
  ├─ TimelineReducer (AgentEvent -> [ChatItem])
  └─ Tool* stores (output/args/segments/details)

Core/Services
  ├─ SessionStore / WorkspaceStore / PermissionStore / MessageQueueStore
  ├─ ConnectionCoordinator (multi-server pool)
  └─ TimelineCache, GitStatusStore, etc.

Features/Chat
  ├─ ChatSessionManager (UI/session lifecycle + history orchestration)
  ├─ ChatActionHandler (send/stop/model/thinking/session actions)
  ├─ ChatTimelineView (SwiftUI render window + overlay/scroll wiring)
  └─ Timeline/
      ├─ Collection/ (UICollectionView host, apply plan, snapshot diffing, scroll/perf/tool-output loading)
      ├─ Rows/ (assistant/user/thinking/system/error/audio/permission content configurations)
      ├─ Tool/ (tool row content, plan builder, interaction policy, expanded surface host, full-screen support, render strategies)
      ├─ Assistant/ (markdown segment source/applier/block views)
      └─ Interaction/ (shared full-screen vs inline-selection specs)
```

### iOS layers

Mechanically enforced boundaries:

1. **UIKit stays out of runtime reducers/coalescers**
   - `Core/Runtime/TimelineReducer.swift` and `Core/Runtime/DeltaCoalescer.swift` must not import UIKit.
   - UIKit-only behavior belongs in `Features/Chat/Timeline/*` host/render files.

2. **View-layer files avoid direct networking primitives**
   - `Core/Views/*` and `Features/Chat/Timeline/*` must not reference `APIClient` / `WebSocketClient` directly.
   - Network work should flow through `ServerConnection` / session managers / stores.

3. **Primary stores stay isolated from each other**
   - `SessionStore`, `WorkspaceStore`, `PermissionStore`, and `MessageQueueStore` must not directly reference each other.
   - Cross-store orchestration belongs in `ServerConnection` / coordinators.

### Timeline rendering package map

- `ChatTimelineView.swift` is the SwiftUI entry point for the timeline render window, jump/initial scroll commands, empty state, and permission overlay.
- `Timeline/Collection/ChatTimelineCollectionView.swift` owns the UIKit host/controller. `ChatTimelineApplyPlan.swift`, `ChatTimelineControllerContext.swift`, `TimelineSnapshotApplier.swift`, `ChatTimelineToolOutputLoader.swift`, and `ChatTimelinePerf.swift` are collection-local support modules.
- `Timeline/Rows/` contains non-tool row configurations/content views (assistant, user, thinking, permission, system, error, audio, load-more, working-indicator).
- `Timeline/Assistant/` contains the markdown pipeline split: `AssistantMarkdownSegmentSource`, `AssistantMarkdownSegmentApplier`, and block renderers.
- `Timeline/Tool/` owns tool-row rendering. The main flow is `ToolPresentationBuilder.ToolExpandedContent` -> `ToolRowPlanBuilder` -> `ToolTimelineRowContentView` -> per-mode `ToolRow*RenderStrategy` or `ToolExpandedSurfaceHostView`.
- `Timeline/Interaction/` holds the shared explicit interaction contracts: `TimelineExpandableTextInteractionSpec` and `TimelineInteractionSpec`.

### Event pipeline (runtime)

`ServerMessage` handling path in code:

1. `WebSocketClient.startReceiveLoop(...)` decodes `StreamMessage`, records inbound sequence metadata.
2. `ServerConnection.routeStreamMessage(...)` routes by `sessionId`.
3. `ServerConnection.handleServerMessage(...)` maps server protocol to local events/stores.
4. `DeltaCoalescer.receive(...)` batches `textDelta`, `thinkingDelta`, `toolOutput` (~33ms).
5. `TimelineReducer.processBatch(...)` mutates timeline state and bumps `renderVersion` once per mutating batch.
6. `ChatTimelineView` observes `renderVersion` and builds `ChatTimelineCollectionHost.Configuration`.
7. `ChatTimelineCollectionHost.Controller.apply(...)` builds `ChatTimelineApplyPlan`, updates controller context, and delegates snapshot diffing to `TimelineSnapshotApplier.applySnapshot(...)`.
8. `ChatTimelineCollectionHost.Controller.apply(...)` then runs `layoutIfNeeded`, scroll logic, and visible hint updates.

### Store isolation rules (as implemented)

Separate `@Observable` stores are used to avoid cross-feature re-renders:

- `SessionStore` (session lists / active session)
- `WorkspaceStore` (workspace + skill catalogs, freshness)
- `PermissionStore` (pending permission requests)
- `MessageQueueStore` (queue chips/state)
- `TimelineReducer` (chat items state machine)
- `ToolOutputStore`, `ToolArgsStore`, `ToolSegmentStore`, `ToolDetailsStore` (large/tool-specific payloads)

Examples from code comments:

- `SessionStore`: scoped so permission timer ticks do not re-render session list.
- `PermissionStore`: separate from session store so permission polling does not churn session UI.
- Tool data stores: kept outside `ChatItem` to keep `Equatable` comparisons cheap and snapshot diffs stable.

### Stream lifecycle ownership (post P1 split)

- `SessionStreamCoordinator` is the single owner of stream lifecycle state transitions.
- `ServerConnection` handles `/stream` socket connectivity, message routing, and command tracking.
- `ChatSessionManager` owns UI entry state and reconnect scheduling, and delegates stream lifecycle policy to the coordinator through `ServerConnection`.
- Recovery behavior (full-subscription recovery cooldown/in-flight guard), queue sync retries, and reconnect resubscribe sequencing are centralized in the coordinator actor.

### Import direction rules (observed)

- `ChatView` composes `ChatSessionManager` + `ChatActionHandler` + `ChatTimelineView`.
- `ChatSessionManager` depends on `ServerConnection`, `TimelineReducer`, `SessionStore`, and history APIs; it does not own stream subscribe/resubscribe/recovery mechanics.
- `SessionStreamCoordinator` owns stream lifecycle policy (subscribe/resubscribe, queue sync, full-subscription recovery, notification-level sync, and seq/catch-up bookkeeping).
- `ServerConnection` owns network transport + message routing and delegates stream lifecycle transitions to `SessionStreamCoordinator`.
- `TimelineReducer`/`DeltaCoalescer` stay UI-framework-free (`Foundation` + runtime types).
- UIKit-specific rendering stays in timeline host/render files under `Features/Chat/Timeline/Collection`, `Rows`, `Tool`, and `Assistant`; reducers/coalescers remain UIKit-free.

### Multi-server boundary

`ConnectionCoordinator` keeps one `ServerConnection` per paired server. Each connection has isolated WS client, stores, reducer, and coalescer. Active UI focus switches by `activeServerId`; non-active servers can remain notification-subscribed.

---

## Protocol boundary (`server/src/types.ts` <-> iOS models)

### Contract source files

- Server contract: `server/src/types.ts`
  - `ClientMessage` union
  - `ServerMessage` union
  - stream envelope fields (`sessionId`, `seq`, `streamSeq`, `currentSeq`)
- iOS mirrors:
  - `ios/Oppi/Core/Models/ClientMessage.swift` (manual `Encodable`)
  - `ios/Oppi/Core/Models/ServerMessage.swift` (manual `Decodable` + `.unknown(type:)`)
  - `SessionScopedMessage` (outbound `/stream` envelope)
  - `StreamMessage` (inbound `/stream` envelope)

### Contract discipline

When protocol changes, current repo rule is explicit:

1. Update `server/src/types.ts`.
2. Update iOS message models (`ServerMessage.swift`, `ClientMessage.swift`).
3. Update protocol tests on both sides.

No partial protocol updates.

---

## End-to-end data flow: server event to rendered pixel

```text
pi AgentSession event
  -> session-agent-events.ts::handlePiEvent
  -> session-protocol.ts::translatePiEvent
  -> session-broadcast.ts::broadcast (assign per-session seq; durable ring)
  -> stream.ts::recordUserStreamEvent (assign streamSeq; user ring)
  -> /stream WebSocket frame
  -> iOS WebSocketClient.decode(StreamMessage)
  -> ServerConnection.routeStreamMessage / handleServerMessage
  -> DeltaCoalescer.receive (batch high-frequency deltas)
  -> TimelineReducer.processBatch (state machine -> [ChatItem], renderVersion++)
  -> ChatTimelineView observes renderVersion
  -> ChatTimelineCollectionHost.Controller.apply
  -> TimelineSnapshotApplier.applySnapshot
  -> ChatTimelineCollectionHost layout + scroll coordination
  -> UIKit draws pixels
```

Catch-up path on reconnect is separate but parallel:

- `SessionStreamCoordinator` tracks per-session `lastSeenSeq` and drives catch-up decisions; iOS fetches `APIClient.getSessionEvents(...since=lastSeenSeq)` when needed.
- Server serves from `SessionManager.getCatchUp()` (`session-broadcast.ts` + `event-ring.ts`).
- If `catchUpComplete == false`, iOS triggers full trace reload (`APIClient.getSession(...traceView:.full)`), then reducer rebuild.
