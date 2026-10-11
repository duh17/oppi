# Oppi push relay

Carries Oppi's end-to-end-encrypted push alerts from self-hosted Oppi servers to Apple Push
Notification service (APNs). Apple accepts pushes for an app only from the developer team that
signs it, so the relay holds that team's APNs key; Oppi servers hold only a per-device send
token. The relay never sees a push key or push content and contains no decryption code.

The protocol, the envelope, and the threat model are in
[protocol/push/spec.md](../protocol/push/spec.md). This package implements relay API v1.

## What the relay sees and keeps

| | Sees | Stores |
| --- | --- | --- |
| Device registration | APNs token, sandbox or production, App Attest attestation | Token, environment, App Attest public key and counter, `SHA-256` of the registration secret |
| Send permissions | — | Permission ID and `SHA-256` of its secret, up to 16 per registration |
| Each push | Server IP address, time, a 1,729-byte envelope it cannot open, an optional collapse ID | Daily and per-minute counts only |

No envelopes, IP addresses, request bodies, or request logs are stored. Logs carry event names
and status codes only. Client addresses feed in-memory rate limits and are never written down.
A registration is deleted when APNs reports its token retired (`410`, `400 BadDeviceToken`,
`400 DeviceTokenNotForTopic`) or when the app deletes it.

The APNs request is fixed: `apns-push-type: alert`, priority 10, the configured topic, an
expiration of at most an hour, and the payload
`{"aps":{"alert":{"title":"Oppi","body":"You have a new notification."},"mutable-content":1},"e":"<envelope>"}`.

## Layout

| Path | |
| --- | --- |
| `src/core/` | Request handling, validation, App Attest (CBOR, X.509 and ECDSA on WebCrypto), quotas, the APNs template and provider token. Runs on Workers and Node. |
| `src/node/` | `node:http` adapter, in-memory or JSON-file store, HTTP/2 APNs sender, capture mode. |
| `src/cloudflare/` | Worker entry, one SQLite-backed Durable Object per registration and per challenge, `fetch` APNs sender. |
| `tests/` | One suite run against both adapters (Cloudflare in the local Workers runtime), plus Node-only clock and App Attest cases with a test CA. |

`relay/` imports nothing from `server/` or `clients/` and no HPKE or KEM package;
`cd server && bun scripts/check-architecture-boundaries.ts --scope relay` enforces it.

## Run on Node

```bash
npm ci
npm run build
OPPI_RELAY_APP_ID=AZAQMY4SPZ.dev.chenda.Oppi OPPI_RELAY_BUNDLE_ID=dev.chenda.Oppi \
  APNS_KEY_PATH=./AuthKey_KEYID.p8 APNS_KEY_ID=KEYID APNS_TEAM_ID=TEAMID \
  node dist/node/main.js
```

`OPPI_RELAY_PORT` (default 8787), `OPPI_RELAY_HOST` (default 127.0.0.1), `OPPI_RELAY_STORE`
(JSON file; memory when unset), and `OPPI_RELAY_TRUST_FORWARDED_FOR=1` behind a reverse proxy.
Put it behind HTTPS; servers accept `http` relays only on loopback.

**Capture mode** records each APNs request it would send instead of contacting Apple, so you
can see exactly what leaves the relay:

```bash
OPPI_RELAY_APP_ID=AZAQMY4SPZ.dev.chenda.Oppi OPPI_RELAY_BUNDLE_ID=dev.chenda.Oppi \
  node dist/node/main.js --capture ./apns-capture.jsonl
```

Point a server at it with `oppi config set push.relays '["http://127.0.0.1:8787"]'`, then
`oppi config set push.mode relay`, and restart the server.

## Deploy on Cloudflare

Not automated yet. The steps, for whoever owns the account:

1. A Cloudflare account on the Workers Paid plan (the free plan's daily request cap fails every
   push once reached) and a hostname for the relay, such as `push.<domain>`.
2. An APNs auth key (`.p8`) from the Apple Developer account of the team that signs the app.
3. `npx wrangler login`, then set secrets: `wrangler secret put APNS_KEY_P8` (the file's
   contents), `APNS_KEY_ID`, `APNS_TEAM_ID`.
4. Check `APP_ID` (`<Team ID>.<bundle ID>`) and `BUNDLE_ID` in `wrangler.toml`, add a
   `routes` entry for the hostname, then `npx wrangler deploy`.

`wrangler.toml` holds no account ID or secrets, and turns Workers Logs and invocation logs off.
The local Workers runtime cannot speak HTTP/2 to APNs, so real delivery is only testable after
deploying; tests use a mock.

## Test

```bash
npm ci
npm test
```

The canary run in `server/` (`npm run push:canary`) sends real server-sealed pushes through
both adapters and checks that no plaintext reaches the relay's input, logs, storage, or APNs
output.
