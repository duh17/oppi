# Telemetry and Privacy Policy (Oppi iOS)

## TL;DR (public/TestFlight builds)

- **No usage analytics are collected.**
- **No feature usage logs are sent to any remote service by default.**
- Public/TestFlight builds are configured to send **zero remote telemetry** unless an operator explicitly changes build settings.

Specifically, the release flow defaults to:
- `SENTRY_DSN=""` (Sentry disabled)
- `OPPI_DISABLE_METRICKIT_UPLOAD=1` (MetricKit upload disabled)

This is enforced by `ios/scripts/release.sh` unless intentionally overridden.

## Explicit non-goals (what Oppi does not track)

Oppi is not designed to collect product analytics. We do **not** track:
- screen views
- button clicks / tap funnels
- feature adoption metrics
- retention cohorts
- “how people use the app” behavior analytics

We also do not upload conversation content as telemetry:
- prompt text
- assistant responses
- tool arguments
- session transcripts

## What exists only for optional internal diagnostics

Oppi has two diagnostics channels that can be enabled intentionally for internal testing:

1. **Sentry** (errors/traces/breadcrumbs)
2. **MetricKit upload** (`POST /telemetry/metrickit`)

Both are optional and configuration-gated.

### 1) Sentry (optional)

Sentry is active **only** when `SentryDSN` in `Info.plist` is non-empty.

If enabled, it adds environment/release tags (e.g. `app_environment`, `app_release`, `session_id`, `workspace_id`) and captures runtime diagnostics. In public/TestFlight release flow this is disabled by default.

### 2) MetricKit upload (optional)

MetricKit upload is active **only** when:
- `OPPIDisableMetricKitUpload` is false/0 in `Info.plist`
- and the app has an API client configured

In public/TestFlight release flow this is disabled by default (`OPPI_DISABLE_METRICKIT_UPLOAD=1`).

When enabled, payloads are diagnostic summaries from Apple MetricKit plus metadata:
- `appVersion`, `buildNumber`, `osVersion`, `deviceModel`
- payload window times
- diagnostic summary fields and sanitized raw MetricKit blob

No prompt/session content is sent in MetricKit payloads.

Example payload shape:

```json
{
  "generatedAt": 1739901234567,
  "appVersion": "1.0.0",
  "buildNumber": "42",
  "osVersion": "iOS 26.0",
  "deviceModel": "iPhone16,6",
  "payloads": [
    {
      "kind": "metric",
      "windowStartMs": 1739900000000,
      "windowEndMs": 1739901234567,
      "summary": { "key": "value" },
      "raw": { "payload": "..." }
    }
  ]
}
```

Server storage (when enabled):
- `<OPPI_DATA_DIR>/diagnostics/telemetry/metrickit-YYYY-MM-DD.jsonl`
- retention via `OPPI_METRICKIT_RETENTION_DAYS` (default `14`)

## Debug-only client log upload

Client-log upload tooling exists for development triage and is not product analytics:
- manual toolbar upload is `#if DEBUG`
- watchdog auto-upload is `#if DEBUG`

These paths are not active in normal release builds.

## Configuration summary

- `SENTRY_DSN` / `Info.plist:SentryDSN`
  - Empty => Sentry off
- `OPPI_DISABLE_METRICKIT_UPLOAD` / `Info.plist:OPPIDisableMetricKitUpload`
  - `1` => MetricKit upload off
  - `0` => MetricKit upload on
- `OPPI_TELEMETRY_MODE`
  - environment tagging only (does not force telemetry transport)

## Policy statement

For public usage, Oppi’s intended posture is:

> **No behavior analytics, no usage tracking, and no remote telemetry by default.**

Any diagnostics upload requires explicit operator opt-in via build/runtime configuration.
