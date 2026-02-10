{
  "id": "df9d69ba",
  "title": "TRACKER: Terminal-feel reliability 80/20 core",
  "tags": [
    "pi-remote",
    "ios",
    "tracker",
    "websocket",
    "protocol",
    "reliability",
    "core"
  ],
  "status": "open",
  "created_at": "2026-02-09T20:43:29.087Z",
  "assigned_to_session": "d5f9bb8a-214a-43e0-9505-d6ed1b55e4a9"
}

Tracks the three non-negotiable protocol guarantees for native-terminal feel on iOS.

## Core items
- [ ] Idempotent input + staged ACKs (TODO-d5e28705)
- [ ] Ordered event sequence + replay on reconnect (TODO-fb28452c)
- [ ] Explicit run/stop lifecycle + stop_confirmed (TODO-93a7d9fd)

## Exit criteria
- [ ] No ghost sends under reconnect/retry
- [ ] No missing structural events after 1006/reconnect
- [ ] Stop path always ends in explicit confirmed/failed outcome

## Progress update (2026-02-09)

Core item #1 has an initial server+wire implementation in progress (TODO-d5e28705):
- `clientTurnId` added to turn messages
- staged `turn_ack` emitted (`accepted`/`dispatched`/`started`)
- per-session LRU+TTL dedupe cache
- duplicate resend returns prior stage and does not re-dispatch

Still open for full completion:
- iOS retry must reuse `clientTurnId`
- UI must be driven by staged ACK transitions
- reconnect churn integration proving no ghost sends

## Progress update (2026-02-09, iOS)

For core item #1 (idempotent input + staged ACK):
- iOS now decodes `turn_ack` and uses staged ACK progression for turn send completion.
- iOS retries reconnectable send failures with the same `(requestId, clientTurnId)` instead of minting a new turn id.
- Added unit coverage for staged ACK handling + retry ID reuse.

Still open:
- explicit user-facing staged send progress UI
- full reconnect churn e2e proving no duplicate runs
