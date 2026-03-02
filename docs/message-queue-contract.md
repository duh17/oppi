# Message Queue Contract (Oppi)

Status: **approved behavior contract**
Scope: iOS + server queue UX/semantics for busy-session inputs (`steer`, `follow_up`)

## Upstream pi semantics (reference)

Oppi queue semantics should stay aligned with upstream pi behavior:

- pi README, **Message Queue** section:
  - Enter queues **steering**
  - Alt+Enter queues **follow-up**
  - Escape aborts and restores queued messages
  - Alt+Up dequeues back into editor
- pi RPC docs:
  - `steer` interrupts after current tool; remaining planned tools are skipped
  - `follow_up` runs after agent finishes (and after steering queue is drained)
  - queue delivery policy controlled by `set_steering_mode` / `set_follow_up_mode`

References:
- `server/node_modules/@mariozechner/pi-coding-agent/README.md` (`# Message Queue`)
- `server/node_modules/@mariozechner/pi-coding-agent/docs/rpc.md` (`prompt/steer/follow_up`, queue modes)
- `server/node_modules/@mariozechner/pi-coding-agent/docs/keybindings.md` (queue keybindings)

## Oppi UX contract

### 1) Queue visibility is footer-only chrome

Queued items are shown only in the dedicated **Message Queue** Liquid Glass component above the composer.

- Do not emit timeline rows for “queued” state.
- Do not emit timeline rows for “queue started” as system events.

### 2) Dequeue/injection appears as normal user message

When a queued item is actually injected into agent input (dequeued/started), it must appear in timeline as a **standard user message row**.

- Same visual treatment as regular user messages.
- Includes images if the queued item had image attachments.

### 3) Trace/timeline parity

Once dequeued/injected, that user input must exist in both:

- timeline (client-rendered user row)
- trace/session history (server-side persisted input)

No timeline-only synthetic rows for canonical user inputs.

## Event mapping policy

### Queue lifecycle events

- `queue_state`: updates queue footer state only.
- `queue_item_started`: authoritative dequeue signal; remove item from queue footer.

### Timeline projection

- `queue_state` -> **no timeline projection**.
- `queue_item_started` -> **append user message row** (not a system event).

## Invariants

1. **Single source of queue truth**: queue content/version comes from server queue state.
2. **No queue noise in timeline**: timeline is reserved for conversation and meaningful lifecycle output.
3. **Canonical input visibility**: every user input that reached the model appears as user message in timeline and trace.
4. **Deterministic dequeue UX**: queue footer removes started item exactly once, even under reconnect/out-of-order delivery.

## Current known gaps vs this contract

At time of writing, Oppi still emits timeline system rows for queue enqueue/dequeue feedback. Those rows are explicitly out-of-contract and should be removed in implementation follow-up.

Also, inline composer has busy-mode switching, but full keybinding parity with upstream pi (`Alt+Enter` follow-up enqueue intent) is tracked separately.

## Acceptance criteria for implementation follow-up

- No `Message Queue • ... queued` timeline system rows.
- No `Message Queue • ... started` timeline system rows.
- On dequeue (`queue_item_started`), timeline gets a standard user row with message/images.
- Dequeued input is present in persisted trace/session history.
- Existing stale/out-of-order queue version protections remain intact.
