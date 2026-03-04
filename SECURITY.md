# Security

Oppi runs a coding agent on your machine with filesystem and tool access. It is provided as-is with no warranty. Use at your own risk.

There is a built-in policy engine that gates tool calls (allow, deny, or prompt for approval on phone). See [policy engine docs](server/docs/policy-engine.md) for details.

For isolation, run the server in Docker:

```bash
cd server
docker compose up
```

## Privacy

Oppi does not phone home. There are no accounts, no analytics, and no data sent to any external service.

All telemetry (session metrics, performance data) is stored locally on your machine. A bundled Grafana dashboard is available if you want to visualize it — run `docker compose -f docker-compose.telemetry.yml up` in the server directory.

Sentry crash reporting in the iOS app is disabled by default and only enabled in development builds. If you self-host your own Sentry instance, you can configure it yourself.

See [`ios/Oppi/Resources/PrivacyInfo.xcprivacy`](ios/Oppi/Resources/PrivacyInfo.xcprivacy) for the Apple Privacy Manifest.

## Reporting issues

If you find a security issue, open an issue on GitHub.
