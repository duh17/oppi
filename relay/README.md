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
| Each push | Server IP address, time, a 641-byte envelope it cannot open, an optional collapse ID | Daily and per-minute counts only |

No envelopes, IP addresses, request bodies, or request logs are stored. Logs carry event names
and status codes only. Client addresses feed in-memory rate limits and are never written down.
A registration is deleted when APNs reports its token retired (`410`, `400 BadDeviceToken`,
`400 DeviceTokenNotForTopic`) or when the app deletes it.

The APNs request is fixed: `apns-push-type: alert`, priority 10, the configured topic, an
expiration of at most an hour, and the payload
`{"aps":{"alert":{"title":"Oppi","body":"You have a new notification."},"mutable-content":1},"e":"<envelope>"}`.

## Limits and why they are set this way

Oppi's relay at `push.oppi.chaosdonkey.dev` runs on the Cloudflare Workers Free plan. There
is no paid tier and no plan for subscriptions or accounts. The limits below come from the
operator's own daily use, sized so that most people get a good experience while the relay
stays inside the free plan:

| Limit | Value |
| --- | --- |
| Pushes per phone per UTC day | 100 with App Attest; 20 for sandbox registrations without it |
| Pushes per phone per minute | 10 |
| Registrations per phone | 1 per APNs token; registering again keeps the day's counts |
| Pushes per client address per minute | 60, checked before any send token is looked up |
| Registrations without App Attest | sandbox only, 5 per client address per hour |
| Challenge and registration requests | 3 per client address per 10 seconds (Cloudflare rate limiting rule) |

Each Oppi server keeps its own per-device budget at or below the relay's (100 a day, with
routine alerts stopping at 80), so normal use never reaches the relay's limit.

The Free plan allows 100,000 Worker requests and 100,000 Durable Object requests a day, and a
push costs about one of each. That covers about 1,000 phones at the daily cap and several
thousand in normal use. When a daily limit is reached, every push fails until 00:00 UTC; the
Free plan never bills. A determined flood of junk requests can still use up a day's limit.
The limits above raise the cost of that; they cannot prevent it on this plan.

The limits count pushes only. They need no account, no identifiers beyond what the table in
[What the relay sees and keeps](#what-the-relay-sees-and-keeps) lists, and no analytics. If
usage grows past what the free plan carries, the limits and the Cloudflare plan will be
revisited, and this section and the [privacy policy](../docs/privacy.md) updated with them.

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

1. A Cloudflare account and a hostname for the relay, such as `push.<domain>`. The Workers
   Free plan fits the per-phone quotas (see [Limits](#limits-and-why-they-are-set-this-way));
   move to Workers Paid if you need more. Add a rate limiting rule for `/v1/challenge` and
   `/v1/registrations`: a phone registers about once per install, so 3 requests per client
   address per 10 seconds is plenty.
2. An APNs auth key (`.p8`) from the Apple Developer account of the team that signs the app.
3. `npx wrangler login`, then set secrets: `wrangler secret put APNS_KEY_P8` (the file's
   contents), `APNS_KEY_ID`, `APNS_TEAM_ID`.
4. Check `APP_ID` (`<Team ID>.<bundle ID>`), `BUNDLE_ID`, and the `routes` hostname in
   `wrangler.toml` (Oppi's own relay is `push.oppi.chaosdonkey.dev`), then `npx wrangler deploy`.

`wrangler.toml` holds no account ID or secrets, and turns Workers Logs and invocation logs off.
The local Workers runtime cannot speak HTTP/2 to APNs, so real delivery is only testable after
deploying; tests use a mock.

## Operator security

End-to-end encryption does not protect against a stolen APNs key or a taken-over relay
account. Either lets an attacker send any alert text to every registered phone, bypassing the
extension (spec "Practical threats", threat 1). Treat the APNs key and the Cloudflare account
as the most sensitive parts of the deployment.

**APNs key.** Since February 2025 Apple offers restricted keys
([announcement](https://developer.apple.com/news/?id=wy4tb0uo),
[details](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)):

- Use a **topic-specific key** limited to the Oppi bundle ID (`dev.chenda.Oppi`), so a leak
  cannot push to the team's other apps.
- Restricted keys are **per environment** (Sandbox or Production). Use one key per environment.
  Limitation: this relay signs sandbox and production pushes with the same key
  (`APNS_KEY_P8`, `APNS_KEY_ID`). With a production-only key, pushes to development builds
  fail, and the reverse. Until the relay takes one key per environment, either accept that a
  deployment serves one environment, or use a key enabled for both environments and accept
  the wider blast radius.
- Keep the `.p8` only as Worker secrets (`wrangler secret put`). Do not commit it, put it in
  `wrangler.toml` or `vars`, or leave copies in Downloads or a shared drive after uploading.
  On Node, keep `APNS_KEY_PATH` readable only by the relay's user.

**Cloudflare account.**

- Sign in with a passkey or hardware security key as the second factor; no SMS.
- Use API tokens limited to this account's Workers scripts and the relay hostname's zone
  routes, not the Global API Key. Delete tokens a CI or laptop no longer needs.
- Turn on usage and billing notifications so unexpected request volume is visible.

**Rotating the APNs key** (after a suspected leak, or a departing account holder):

1. Revoke the old key in Apple Developer "Certificates, Identifiers & Profiles", Keys. APNs
   then rejects tokens signed with it, so pushes fail until step 4.
2. Create a new key with the same restrictions and download the `.p8` (Apple offers it once).
3. `npx wrangler secret put APNS_KEY_P8` (the new file's contents) and
   `npx wrangler secret put APNS_KEY_ID`.
4. `npx wrangler deploy`, then delete the local `.p8`.

Revoking first closes the leak at the cost of a few minutes without pushes. For routine
rotation with no suspected leak, create the new key and deploy before revoking the old one.
Registrations, permissions, and send tokens are independent of the APNs key and keep working.

## Test

```bash
npm ci
npm test
```

The canary run in `server/` (`npm run push:canary`) sends real server-sealed pushes through
both adapters and checks that no plaintext reaches the relay's input, logs, storage, or APNs
output.
