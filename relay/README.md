# Oppi push relay

Carries Oppi's end-to-end-encrypted push alerts from self-hosted Oppi servers to Apple Push
Notification service (APNs). Apple accepts pushes for an app only from the developer team that
signs it, so the relay holds that team's APNs key; Oppi servers hold only a per-device send
token. The relay never sees a push key or push content and contains no decryption code.

It also carries Oppi's Live Activity: a counts-only card ("3 running · 1 needs you") that a server
starts, updates, and ends while the phone is away. Those pushes carry two integers the relay
validates and puts into a fixed ActivityKit template; nothing else from the server reaches APNs.

The protocol, the envelope, and the threat model are in
[protocol/push/spec.md](../protocol/push/spec.md). This package implements relay API v1.

## What the relay sees and keeps

| | Sees | Stores |
| --- | --- | --- |
| Device registration | APNs token, sandbox or production, App Attest attestation | Token, environment, App Attest public key and counter, `SHA-256` of the registration secret |
| Send permissions | — | Permission ID and `SHA-256` of its secret, up to 16 per registration |
| Each push | Server IP address, time, a 641-byte envelope it cannot open, an optional collapse ID | Daily and per-minute alert counts only |
| Live Activity state | ActivityKit push-to-start token; per server whose card is on, the permission ID that may drive it, the phone's random slot, the live card's update token, and whether the person dismissed it | The tokens, slots, permission IDs, when each update token first arrived, and which dismissed cards a server has ended since |
| Each Live Activity push | Server IP address, time, `start`/`update`/`end`, the running and needs-you counts | Daily and per-minute Live Activity counts only |

No envelopes, IP addresses, request bodies, or request logs are stored. Logs carry event names
and status codes only. Client addresses feed in-memory rate limits and are never written down.
A registration is deleted when APNs reports its token retired (`410`, `400 BadDeviceToken`,
`400 DeviceTokenNotForTopic`), when the app deletes it, or after 90 days without a push (from
its creation or last counted push, read from the quota counters it already keeps). On a relay
deployed before this change, a registration made earlier starts that 90-day count at its next
push, when it gets its alarm; one that never pushes again is not deleted. Challenges
are not stored: each one carries its own expiry and a keyed tag (spec §3.1).

The APNs request is fixed: `apns-push-type: alert`, priority 10, the configured topic, an
expiration of at most an hour, and the payload
`{"aps":{"alert":{"title":"Oppi","body":"You have a new notification."},"mutable-content":1},"e":"<envelope>"}`.

Live Activity requests are fixed too: `apns-push-type: liveactivity`, topic
`<bundle ID>.push-type.liveactivity`, priority 5 for updates and 10 for start and end, and an
`aps` built only from the event, the two counts, the relay's own timestamp (always later than the
registration's last one), and the phone's slot; `start`
adds the fixed alert `Oppi` / `Agents are working.` that Apple requires. An APNs answer that
retires a Live Activity token clears that token only; the registration stays. Only the send
token whose permission the phone lists for a card can start, update, or end it; a permission the
phone leaves out (a server whose card the person turned off) gets `409 no_activity`. On an
attested registration the state is written in the same atomic step that checks the App Attest
counter, so an older upload that arrives late cannot replace a newer one. A card the phone lists as dismissed gets no `start` until a server sends
`end` for it (its counts reached zero), and a card's update token is forgotten only once APNs
accepts the `start` that replaces it.
See spec §3.6.

## Limits and why they are set this way

Oppi's relay at `push.oppi.chaosdonkey.dev` runs on the Cloudflare Workers Free plan. There
is no paid tier and no plan for subscriptions or accounts. These limits are preliminary and may
change. They come from the operator's own daily use, sized so that most people get a good experience while the relay
stays inside the free plan:

| Limit | Value |
| --- | --- |
| Pushes per phone per UTC day, alerts and Live Activity together | 100 with App Attest; 20 for sandbox registrations without it |
| Kept for alerts | 30 with App Attest (Live Activity `start` and `update` stop at 70); 6 without (they stop at 14). Alerts may use the whole day's pushes |
| Live Activity `end` | Counted, but never refused for the day's limit: it has an overdraft of 8 more (108 with App Attest, 28 without) |
| Alerts per phone per minute | 10 |
| Live Activity pushes per phone per minute | 3, `end` included |
| Registrations per phone | 1 per APNs token; registering again keeps the day's counts |
| Pushes, Live Activity pushes, and permission releases per client address per minute | 60 together, checked before any send token is looked up; an IPv6 address counts as its /64 |
| Registrations without App Attest | sandbox only, 5 per client address per hour |
| Challenge and registration requests | 3 per client address per 10 seconds (Cloudflare rate limiting rule) |

One pool serves both kinds because the operator's phone used 5 to 25 alerts a day but ran out
of separate Live Activity pushes daily: a Live Activity gets whatever alerts leave, and alerts
keep the last 30 for themselves.

Each Oppi server keeps its own per-device budget at or below the relay's (100 a day; Live
Activity starts and updates stop at 70, routine alerts at 90), so one server alone rarely
reaches the relay's limit. The
relay's limits are per phone and shared by every server that phone is paired with. A server
keeps its count in memory, so a restart starts that server's count over.

The Free plan allows 100,000 Worker requests, 100,000 Durable Object requests, and 100,000
rows written a day. An alert or Live Activity update costs one of each; the table below has
the rest. A phone at the cap (100 pushes, a few card starts and ends, 10 uploads of its Live
Activity state) uses about 130 Durable Object requests a day, so about 750 such phones fill
the plan; the pushes alone would allow about 1,000. When a daily Durable Object limit is reached, every
push fails until 00:00 UTC, and the relay answers `503 relay_capacity` with `Retry-After` set
to then; when the Worker request limit is reached, Cloudflare answers before the relay runs.
The Free plan never bills. A determined flood of junk requests can still use up a day's
limit. The limits above raise the cost of that; they cannot prevent it on this plan.

### What each request costs

On the Cloudflare adapter every request is one Worker request; Durable Object requests (one
per stub call or alarm) and rows written (each `put`, `setAlarm`, and deleted key) are:

| Request | Durable Object requests | Rows written |
| --- | --- | --- |
| `POST /v1/challenge` | 0 (challenges are not stored) | 0 |
| Register, new APNs token | 3 (token lookup, bind, create) | 3 (bind, registration, its expiry alarm) |
| Register again, same APNs token | 5 (adds reading and deleting the old one) | about 4 |
| Mint a permission | 3 with App Attest (read, counter, add), 2 without | 2, or 1 |
| `POST /v1/push` | 1 | 1 (0 when refused) |
| `POST /v1/push` that APNs answers with a retired token | 3 | 3 |
| Live Activity `update` | 1 | 1 (0 when refused) |
| Live Activity `end` delivered, or `start` that replaces a card's token | 2 | 2 |
| `PUT .../live-activity` | 2 | 1 |
| `DELETE /v1/registrations/{id}` | 4 with App Attest, 3 without | 3, or 2 |
| `DELETE /v1/permission` | 2 (1 for an unknown token) | 1 (0 when nothing changed) |
| Idle-expiry alarm, once per registration per 90 days or more | 1, or 2 when it deletes | 1, or 2 when it deletes |

The first push after a registration's object starts also reads whether it has an alarm (a
row read, not written); a registration made before idle expiry existed gets its alarm then.

The limits count pushes only. They need no account, no identifiers beyond what the table in
[What the relay sees and keeps](#what-the-relay-sees-and-keeps) lists, and no analytics. If
usage grows past what the free plan carries, the limits and the Cloudflare plan will be
revisited, and this section and the [privacy policy](../docs/privacy.md) updated with them.

## Layout

| Path | |
| --- | --- |
| `src/core/` | Request handling, validation, App Attest (CBOR, X.509 and ECDSA on WebCrypto), quotas, the APNs template and provider token. Runs on Workers and Node. |
| `src/node/` | `node:http` adapter, in-memory or JSON-file store, HTTP/2 APNs sender, capture mode. |
| `src/cloudflare/` | Worker entry, one SQLite-backed Durable Object per registration and per APNs token, `fetch` APNs sender. |
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
(JSON file; memory when unset), and `OPPI_RELAY_TRUST_FORWARDED_FOR=1` behind one reverse proxy.
Rate limits then use the last `X-Forwarded-For` address, the one that proxy added.
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
   address per 10 seconds is plenty. Then harden TLS at the edge on the zone, not in the
   Worker: minimum TLS 1.2 (Oppi's relay uses 1.3) and a WAF custom rule that blocks this
   hostname when `not ssl`, so plain HTTP is refused rather than redirected. `wrangler.toml`
   cannot express either; see "Edge TLS" under [Operator security](#operator-security).
2. An APNs auth key (`.p8`) from the Apple Developer account of the team that signs the app.
3. `npx wrangler login`, then set secrets: `wrangler secret put APNS_KEY_P8` (the file's
   contents), `APNS_KEY_ID`, `APNS_TEAM_ID`. `APNS_KEY_P8` also keys registration challenges,
   through HKDF with its own label; without it the Worker refuses every request.
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

**Edge TLS.** Registration secrets, send tokens, and APNs tokens reach the edge in cleartext
inside TLS, so the zone must not offer a weaker handshake than the clients require. These are
zone and ruleset settings, not Worker configuration:

- Minimum TLS Version **1.3** on the zone (1.2 is the floor for a relay that cannot use 1.3;
  TLS 1.0 and 1.1 are always refused). Pair it with a WAF custom rule so a later change to
  the zone minimum cannot weaken the relay hostname:
  `http.host eq "push.oppi.chaosdonkey.dev" and (not ssl or cf.tls_version in {"TLSv1"
  "TLSv1.1" "TLSv1.2"})` → Block.
- **Refuse plain HTTP; do not redirect it.** A client that sent a send token or a
  registration secret over `http://` has already leaked it: a `301`/`308` hides that, and a
  redirected `POST` often reaches the Worker as a `GET`. Leave Cloudflare's zone-wide
  "Always Use HTTPS" off and let the WAF rule answer `403`.
- **HSTS** for the relay hostname alone, through a Response Header Transform Rule
  (`max-age=300`, no `includeSubDomains`, no preload; raise `max-age` once it has been quiet
  for a day or so). The relay has no browser users, so this is hygiene for a person pasting
  the URL, not protection for Oppi clients.
- **0-RTT stays off**, because `/v1/push` is not idempotent. TLS 1.3 and HTTP/3 stay on.

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
Challenges handed out under the old key in the last 5 minutes stop working: a phone that was
registering gets `400 challenge_invalid` and registers on its next attempt.

## Test

```bash
npm ci
npm test
```

The canary run in `server/` (`npm run push:canary`) sends real server-sealed pushes through
both adapters and checks that no plaintext reaches the relay's input, logs, storage, or APNs
output.