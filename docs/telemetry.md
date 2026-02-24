# Telemetry Stack A (Sentry + MetricKit)

This project emits diagnostics for test builds using two layers:

1. **Sentry** for near-real-time traces, spans, errors, and breadcrumbs.
2. **MetricKit** for native iOS aggregated diagnostics (CPU/memory launches/hangs/crashes).

Sentry and MetricKit are intentionally split so each remains lightweight in-app and easy to evolve independently.

## Sentry scope and enablement

- `SentryService` configures tags:
  - `app_environment` (e.g. `debug`, `test`, `release`)
  - `app_release` (`<bundle id>@<version>+<build>`)
  - `session_id`
  - `workspace_id`
- `app_environment` is derived from build/test mode:
  - `OPPI_TELEMETRY_MODE=public`/`release` -> `release`
  - `OPPI_TELEMETRY_MODE=test`/`staging`/`qa`/`internal` -> `test`
  - Debug builds remain `debug`
- Public TestFlight release workflow keeps Sentry DSN disabled by default.
- Internal test lanes can set `OPPI_TELEMETRY_MODE=test` via build settings when they intentionally want test telemetry tagging.
- `SENTRY_DSN` is read from `Info.plist` (`SentryDSN` key)

## MetricKit ingestion

- Endpoint: `POST /telemetry/metrickit`
- Expected payload shape:

```json
{
  "generatedAt": 1739901234567,
  "appVersion": "1.0.0",
  "buildNumber": "42",
  "osVersion": "iOS 26.0",
  "deviceModel": "iPhone16,6",
  "payloads": [
    {
      "kind": "metric" | "diagnostic",
      "windowStartMs": 1739900000000,
      "windowEndMs": 1739901234567,
      "summary": { "key": "value" },
      "raw": { "payload": "..." }
    }
  ]
}
```

- Data is normalized server-side and appended to JSONL under:
  - `<OPPI_DATA_DIR>/diagnostics/telemetry/metrickit-YYYY-MM-DD.jsonl`
- Retention: keep last `OPPI_METRICKIT_RETENTION_DAYS` (default `14`) daily files.
  Set `OPPI_METRICKIT_RETENTION_DAYS` in the server environment to tune (e.g. `7`, `30`).

## Dashboard guidance

The codebase now exposes the signals to build dashboards manually:

### Sentry (real-time)

Recommended minimum panels:

- **Crash/stability**
  - Error rate by `app_environment`
  - Crash-free sessions by `app_environment`
- **WebSocket health**
  - `WebSocket` reconnect event count / error rate by `app_environment`
- **Spans and UX traces**
  - `chat.timeline.apply` p50/p95/p99
  - `datasource.apply` p95
  - `layout.pass` p95
- **Signals from app-only captures**
  - Watchdog stall capture volume
  - Slow-cell rendering and slow tool cell renders

Tag usage in dashboard filters should include fixed dimensions:
- `app_environment`
- `app_release`
- `session_id`
- `workspace_id`

### MetricKit (trend)

Recommended charts:

- Crash/hang trend (MetricKit crash/hang payload windows)
- CPU time trend
- Memory footprint trend
- Launch latency trend
- Daily volume of payloads accepted

> `MetricKit` summaries are persisted for trend analysis in JSONL and should typically be loaded by a scheduled batch job or BI tool for richer charting than on-device inspection.

## Privacy and retention policy

- No user prompt text, tool arguments, or high-cardinality session text is captured in MetricKit payloads.
- Telemetry includes only app/runtime metadata and diagnostic summaries:
  - `appVersion`, `buildNumber`, `osVersion`, `deviceModel`
  - payload window (`windowStartMs`, `windowEndMs`)
  - payload `summary` + sanitized raw JSON payload blob
- Files are written with file-per-day JSONL naming and daily retention pruning.
- Test builds only can transmit this telemetry by build configuration (`OPPI_TELEMETRY_MODE`) and DSN availability.
