# Telemetry and privacy

## TL;DR

- In iOS public/release mode, **Sentry is off**.
- In iOS public/release mode, **Send Performance Metrics** is **off by default**.
- If enabled, performance metrics are uploaded only to your configured Oppi server.
- Metric upload endpoints:
  - `POST /telemetry/metrickit`
  - `POST /telemetry/chat-metrics`

## In-app controls

- Public/release mode: Settings → **Diagnostics** → **Send Performance Metrics**.
- Default: **Off**.
- Off: MetricKit and chat metrics are not uploaded.
- On: MetricKit and chat metrics are uploaded to your configured Oppi server.
- Internal/debug mode: diagnostics are always active and the toggle is replaced by an informational message.

## Sentry

Sentry starts only when both are true:

- telemetry mode is `internal`
- `SentryDSN` is configured

iOS Release sets `OPPI_TELEMETRY_MODE=public`, so Sentry does not start in public/release mode.

Turning on **Send Performance Metrics** in public/release mode does not enable Sentry.

## Server enforcement and storage

- Server-side telemetry gate: `OPPI_TELEMETRY_MODE`
  - `internal`/`debug`/`test`/`dev` (and aliases): uploads accepted
  - `public`/`release`/`prod`/`off` (and aliases): uploads rejected (`HTTP 403`)
- Stored on server at:
  - `<OPPI_DATA_DIR>/diagnostics/telemetry/metrickit-YYYY-MM-DD.jsonl`
  - `<OPPI_DATA_DIR>/diagnostics/telemetry/chat-metrics-YYYY-MM-DD.jsonl`
- Retention:
  - `OPPI_METRICKIT_RETENTION_DAYS` (default `14`)
  - `OPPI_CHAT_METRICS_RETENTION_DAYS` (default `14`)

## Self-monitoring (Grafana)

- Prebuilt dashboard included: **Oppi Release Preflight**
- Dashboard JSON: `server/docker/grafana/dashboards/oppi-release-preflight.json`
- Start local stack: `cd server && npm run telemetry:grafana:up`
- Setup docs: `server/README.md` → **Local release telemetry dashboard (SQLite + Grafana)**
