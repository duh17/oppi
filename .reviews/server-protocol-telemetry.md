# Server Protocol + Telemetry Review (since `testflight/19`)

Scope reviewed: protocol contract (`server/src/types.ts`), server wiring (`server/src/server.ts`), policy engine (`server/src/policy.ts`, `server/src/policy-presets.ts`, `server/src/visual-schema.ts`), telemetry ingestion/emission paths (`server/src/routes/telemetry.ts`, `server/src/routes/sessions.ts`, stream/socket paths), Docker/infra (`server/docker-compose*.yml`, `server/Dockerfile`, `server/knip.json`, `server/scripts/review-dispatch.mjs`), and related tests.

## Protocol Health (type safety, forward compatibility, breaking change risk)

**What looks solid**
- Protocol contract remains centralized and explicit in `server/src/types.ts` (`ClientMessage`/`ServerMessage` unions at `:619` and `:732`), including new file suggestion command (`:704`) and stream cursor fields (`sinceSeq` at `:626`, `streamSeq` at `:862`).
- Server advertises protocol version consistently via `X-Oppi-Protocol: 2` (`server/src/server.ts:754`) and `/health` (`server/src/server.ts:763-765`).
- Stream catch-up path does ordering validation and fails on non-monotonic replay (`server/src/stream.ts:139-146`), with strong invariant coverage (`server/tests/ws-ordering-invariants.test.ts:79-153`, `server/tests/offline-recovery.test.ts:155-279`, `server/tests/ws-invariants.test.ts:163-293`).
- Forward-compat tolerance is tested (extra fields, missing optionals, discriminator stability) in `server/tests/protocol-schema-drift.test.ts:33-387`.

**Risks / inconsistencies**
- `get_file_suggestions` has **type/runtime mismatch**: `requestId` is optional in the protocol type (`server/src/types.ts:704`), but handler hard-fails without it (`server/src/ws-message-handler.ts:413-415`).
- Incoming WS messages are cast directly from JSON (`server/src/stream.ts:359`) with no runtime schema validation; unknown/future message types route through default handling (`server/src/stream.ts:409-448`) and can be silently no-op in `WsMessageHandler` (switch has no default branch, `server/src/ws-message-handler.ts:112-206`).
- Workspace `allowedPaths` deserialization trusts disk shape via cast (`server/src/storage/workspace-store.ts:98-99`), which can produce malformed runtime objects later consumed by `.path.trim()` (`server/src/ws-message-handler.ts:431-440`).

## Telemetry Design (metric naming consistency, cardinality, gating)

**What looks solid**
- Metric naming is centralized in `CHAT_METRIC_REGISTRY` (`server/src/types.ts:413-554`), including new session/context and stream timing metrics (`:466-523`) and plot metrics (`:538-550`).
- Route enforces registry parity at startup (`server/src/routes/telemetry.ts:287-294`) and unit contract per metric (`:371-373`).
- Telemetry mode gating is deduped and reused (`telemetryUploadsEnabledFromEnv` at `server/src/types.ts:345-374`), enforced in both telemetry and diagnostics upload routes (`server/src/routes/telemetry.ts:454-455,481-482`, `server/src/routes/sessions.ts:349-350`), with tests (`server/tests/routes-modules.test.ts:86-90,616-651,1271-1340`).
- iOS/server metric parity is tested (`server/tests/routes-modules.test.ts:67-83`).

**Risks / data quality gaps**
- Tag normalization is good, but cardinality control is weak: only field count and string length caps (`server/src/routes/telemetry.ts:25-27,317-339`), no per-metric key allowlist or value bucketing.
- Ratio semantics are not enforced: `plot.scroll_enabled` is documented as 0/1 ratio (`server/src/types.ts:546-548`) but validator accepts any finite number (`server/src/routes/telemetry.ts:350-384`).
- Ingestion writes use synchronous filesystem calls (`appendFileSync` in `server/src/routes/telemetry.ts:278-283,438-441`), which can block the event loop under upload bursts.
- Registry currently carries overlapping connect metrics (`chat.ws_connect_ms` legacy + `chat.stream_open_ms`) (`server/src/types.ts:466-471`), increasing dashboard/query drift risk without a deprecation window.

## Policy Engine (self-protection gates, plot normalization pipeline, extensibility)

**What looks solid**
- Runtime policy layering is clear in `evaluateWithRules` (`server/src/policy.ts:216-287`): reserved `policy.*` gate (`:222-229`), protected path guard (`:234-243`), heuristics, then user rules.
- Server wires hard protection for `rules.json` (`server/src/server.ts:275-281`) and protected-path behavior is tested (`server/tests/policy-rules.test.ts:519-616`).
- Self-protection + communication gates are present in presets (`server/src/policy-presets.ts:229-285,421-452`) and mirrored in built-in host rules (`:717-925`).
- Plot payload sanitization is robust: render-hint clamping/enums (`server/src/visual-schema.ts:394-548`) and dense-category safety guard (`:575-611`), covered by tests (`server/tests/visual-schema.test.ts:127-311`, `server/tests/plot-extension.test.ts:8-124`).

**Risks / extensibility issues**
- Protected-path guard can be bypassed for relative bash/file references: bash check is substring match against absolute path (`server/src/policy.ts:316-318`), and file path normalization uses `pathResolve` against server process cwd (`server/src/policy.ts:80-82`), not session cwd.
- Policy rule definitions are duplicated between declarative default config and built-in host arrays (`server/src/policy-presets.ts:154-487` vs `:717-925`), which is drift-prone.
- Render-height contract mismatch: plot extension schema caps height at 480 (`server/experiments/extensions/plot-extension.ts:104`) while visual-schema sanitizer allows up to 640 (`server/src/visual-schema.ts:666-669`).
- Coverage gap: I did not find targeted tests for new communication gate patterns (`ask-imessage-*`, `ask-email-*`) in existing policy suites (`server/tests/policy-host.test.ts:122-205`, `server/tests/policy-rules.test.ts:160-616`).

## Server Infrastructure (Docker compose, knip integration, dead code discipline)

**What looks solid**
- Skills-ready container runtime is well-integrated: seed sync + wrapper setup (`server/docker/entrypoint.sh:16-137`), compose mounts for skills/dotfiles/cache/docker socket (`server/docker-compose.yml:24-35`).
- Dead-code discipline is wired into standard checks: `knip` config (`server/knip.json:1-7`), dedicated script (`server/package.json:65`), and enforced in `npm run check` (`server/package.json:72`).
- Review dispatch now prefers unified `agent-sessions` skill path with local/home fallback (`server/scripts/review-dispatch.mjs:69-76,103-106`).

**Risks / polish gaps**
- Port mismatch: Dockerfile still exposes `7749` (`server/Dockerfile:45`) while compose/runtime defaults are `7750` (`server/docker-compose.yml:9,15`).
- Telemetry Grafana defaults are permissive (`admin/admin`, anonymous enabled) and bound via standard host mapping (`server/docker-compose.telemetry.yml:6-14`), which is risky outside strictly local environments.
- `review-dispatch` hardcodes `--workspace oppi` (`server/scripts/review-dispatch.mjs:105-106`), reducing portability across repo/workspace naming changes.

## Suggestions (concrete improvements, ordered by impact)

1. **Close protected-path bypasses (highest impact).**  
   Resolve file/bas h paths relative to session cwd, not server cwd; parse bash redirections/targets instead of `command.includes(...)` (`server/src/policy.ts:80-82,316-318`). Add regression tests for relative `rules.json` edits and `cd ... && echo > rules.json`.

2. **Add runtime WS message validation + deterministic unknown-command errors.**  
   Replace raw cast (`server/src/stream.ts:359`) with schema validation and emit explicit `command_result`/`error` for unsupported `type` values before dispatch.

3. **Fix `get_file_suggestions` contract mismatch.**  
   Either make `requestId` required in `ClientMessage` (`server/src/types.ts:704`) or allow fire-and-forget behavior in handler (`server/src/ws-message-handler.ts:413-415`). Add dedicated ws handler tests for this command path.

4. **Harden telemetry cardinality and value contracts.**  
   Add per-metric tag key allowlists and value bucketing; enforce `[0,1]` (or `{0,1}`) for ratio metrics like `plot.scroll_enabled` (`server/src/types.ts:546-548`, `server/src/routes/telemetry.ts:350-384`).

5. **Sanitize persisted `allowedPaths` on read, not just on API writes.**  
   Replace cast in workspace store (`server/src/storage/workspace-store.ts:98-99`) with structural filtering/normalization to prevent malformed disk state from propagating into suggestion path resolution (`server/src/ws-message-handler.ts:431-440`).

6. **Unify plot height limits across extension + sanitizer.**  
   Align `server/experiments/extensions/plot-extension.ts:104` and `server/src/visual-schema.ts:666-669` to a single bound.

7. **Tighten local telemetry/Grafana security defaults.**  
   Bind Grafana to loopback by default and require non-default admin credentials in docs/compose (`server/docker-compose.telemetry.yml:6-14`).

8. **Infra consistency cleanup.**  
   Align Docker exposed port (`server/Dockerfile:45`) with compose default (`server/docker-compose.yml:9,15`) and make review dispatch workspace configurable (`server/scripts/review-dispatch.mjs:105-106`).
