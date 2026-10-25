# Oppi push relay

Carries Oppi's end-to-end-encrypted push alerts from self-hosted Oppi servers to Apple Push
Notification service (APNs). Apple accepts pushes for an app only from the developer team that
signs it, so the relay holds that team's APNs key and an Oppi server holds only a per-device
send token. The relay never sees a push key or alert content, and contains no decryption code.

It also carries Oppi's Live Activity, a Lock Screen card with two counts ("3 running · 1 needs
you"). The relay checks the counts and puts them into a fixed ActivityKit template; nothing else
from the server reaches APNs.

App Store and TestFlight builds use Oppi's relay at `push.oppi.chaosdonkey.dev`; you do not
need to run one. Run your own only if you build and sign Oppi with your own Apple team.

The protocol, envelope, and threat model are in [protocol/push/spec.md](../protocol/push/spec.md).
This package implements relay API v1.

## What the relay sees and keeps

| | Sees | Stores |
| --- | --- | --- |
| Device registration | APNs token, sandbox or production, App Attest attestation, your device's IP address | Token, environment, App Attest public key and counter, `SHA-256` of the registration secret |
| Send permissions | — | Permission ID and `SHA-256` of its secret, up to 16 per registration |
| Each push | Server IP address, time, a 641-byte envelope it cannot open, an optional collapse ID | Daily and per-minute alert counts |
| Live Activity state | Your device's IP address, push-to-start token; per server with a card on, the permission ID allowed to drive it, a random slot, the card's update token, and whether you dismissed it | These tokens, slots, and permission IDs, when each update token arrived, and which dismissed cards a server has ended since |
| Each Live Activity push | Server IP address, time, `start`/`update`/`end`, the running and needs-you counts | Daily and per-minute Live Activity counts |

The relay stores no envelopes, IP addresses, request bodies, or request logs. Its logs carry
event names and status codes only. Client addresses feed in-memory rate limits and are never
written down.

Cloudflare, which runs the HTTPS endpoint, keeps its own HTTP analytics for the hostname:
client address, method, path, status, and time, for as long as that product retains them. So
IP addresses reach Cloudflare — your phone's on each registration, permission, and card sync,
and your server's on each push — even though the relay stores none, and the path names the
registration's opaque id (not a credential: a caller also needs the registration secret and a
fresh App Attest assertion when attested). The relay turns off Workers Logs, invocation logs,
observability, and Logpush, so there is no request log beyond that; keeping less than that
needs an endpoint you run yourself.

The relay deletes a registration when:

- APNs reports its token retired (`410`, `400 BadDeviceToken`, `400 DeviceTokenNotForTopic`);
- the app deletes it;
- 90 days pass without a push. A registration made before idle expiry was deployed starts this
  count at its next push.

What the relay sends to APNs is fixed. An alert is always:

```json
{"aps":{"alert":{"title":"Oppi","body":"You have a new notification."},"mutable-content":1},"e":"<envelope>"}
```

with `apns-push-type: alert`, priority 10, and an expiration of at most an hour. A Live Activity
push holds only the event, the two counts, the relay's timestamp, and the phone's slot; `start`
adds the alert `Oppi` / `Agents are working.` that Apple requires. Only a server the phone lists
for a card can start, update, or end it. See spec §3.6.

## Limits

Unless a row names a client address, a limit is per phone and shared by every server that phone
is paired with. The limits are preliminary and may change.

| Limit | Value |
| --- | --- |
| Pushes per UTC day, alerts and Live Activity together | 100 with App Attest; 20 for sandbox registrations without it |
| Reserved for alerts | The last 30 of 100 with App Attest (Live Activity `start` and `update` stop at 70); the last 6 of 20 without |
| Live Activity `end` | Allowed up to 8 past the day's limit, so a card is not left showing finished work |
| Alerts per minute | 10 |
| Live Activity pushes per minute | 3, `end` included |
| Registrations | 1 per APNs token; registering again keeps the day's counts |
| Pushes, Live Activity pushes, and permission releases per client address per minute | 60 together; an IPv6 address counts as its /64 |
| Registrations without App Attest | Sandbox only, 5 per client address per hour |
| Challenge and registration requests | 3 per client address per 10 seconds (Oppi's relay only, set at Cloudflare) |

An Oppi server keeps its own per-device budget inside these (Live Activity starts and updates
stop at 70, routine alerts at 90), so one server alone rarely reaches the relay's limit. It
keeps that budget in memory, so a server restart resets it.

Oppi's relay is free, needs no account, and runs on the Cloudflare Workers Free plan. If the
plan's daily capacity runs out, pushes fail until 00:00 UTC: the relay answers
`503 relay_capacity` with `Retry-After`, or Cloudflare refuses the request first.

## Run your own relay

You need an APNs auth key (`.p8`) from the Apple team that signs your build. Put the relay
behind HTTPS; servers accept an `http` relay only on loopback.

On Node:

```bash
npm ci
npm run build
OPPI_RELAY_APP_ID=<Team ID>.<bundle ID> OPPI_RELAY_BUNDLE_ID=<bundle ID> \
  APNS_KEY_PATH=./AuthKey_KEYID.p8 APNS_KEY_ID=KEYID APNS_TEAM_ID=TEAMID \
  node dist/node/main.js
```

| Variable | Default |
| --- | --- |
| `OPPI_RELAY_PORT` | `8787` |
| `OPPI_RELAY_HOST` | `127.0.0.1` |
| `OPPI_RELAY_STORE` | In memory. Set a JSON file path to keep registrations across restarts |
| `OPPI_RELAY_TRUST_FORWARDED_FOR` | Off. Set `1` behind exactly one reverse proxy; rate limits then use the last `X-Forwarded-For` address |

On Cloudflare Workers, set `APP_ID`, `BUNDLE_ID`, and `routes` in `wrangler.toml`, add the
secrets `APNS_KEY_P8` (the file's contents), `APNS_KEY_ID`, and `APNS_TEAM_ID`, and deploy. The
Worker refuses every request without `APNS_KEY_P8`.

Point your server at the relay, then restart it:

```bash
oppi config set push.relays '["https://push.example.com"]'
```

**Capture mode** writes each APNs request to a file instead of sending it, so you can see
exactly what leaves the relay. It needs no APNs key. Point a server at
`http://127.0.0.1:8787` to try it:

```bash
OPPI_RELAY_APP_ID=<Team ID>.<bundle ID> OPPI_RELAY_BUNDLE_ID=<bundle ID> \
  node dist/node/main.js --capture ./apns-capture.jsonl
```

Run the tests with `npm test`.
