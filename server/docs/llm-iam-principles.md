# LLM IAM Principles (Plain-Language)

Status: Draft v0 (2026-02-11)  
Scope: `oppi-server` permission gate + policy engine + iOS approval UX

Related technical docs:
- `oppi-server/docs/policy-engine-v2.md` (full architecture/data model)
- `oppi-server/src/policy.ts` (evaluation logic)
- `oppi-server/src/gate.ts` (approval lifecycle + fail-safe)
- `oppi-server/src/rules.ts` (learned/manual rule store)
- `oppi-server/src/audit.ts` (audit log)

---

## Why this exists

We want IAM-level control for agent actions, but understandable by non-technical users.

This document is the **human contract**:
- what users should expect,
- what guarantees the system provides,
- and where the limits are.

---

## Mode profiles

Current host/runtime profiles:

| Preset | Who it is for | Behavior |
|---|---|---|
| `host` | Trusted developer workflow | Default allow, ask for external/high-impact actions |
| `host_standard` | Normal users | Approval-first, bounded read-only auto-allow |
| `host_locked` | High-control environments | Unknown actions blocked by default |
| `container` | Isolated runtime | Container boundary + targeted ask rules |

## Simple mental model (5 principles)

1. **Never**  
   Some actions are always blocked (secrets, critical safety boundaries).

2. **Ask**  
   Risky actions need approval before execution.

3. **Remember**  
   Approved/denied decisions can be remembered with clear scope and optional expiry.

4. **Explain**  
   Every approval prompt must show plain-language summary, full action text, and reason.

5. **Review & Undo**  
   Every decision is logged. Remembered permissions can be revoked.

---

## Decision flow (what happens on every tool call)

1. **Hard deny rules** (immutable)  
2. **Learned/manual deny rules**  
3. **Scoped allow rules** (session/workspace/global)  
4. **Heuristics + preset rules** (may require approval)  
5. **Default action** for the active preset

Core rule: **explicit deny beats allow**.

---

## Permission scopes (what “remember” means)

| Scope | Effect | Lifetime |
|---|---|---|
| once | this one action only | immediate |
| session | this session only | until session ends |
| workspace | this workspace | persisted (optional TTL) |
| global | all workspaces | persisted (optional TTL) |

Notes:
- Session rules are ephemeral (in-memory).
- Persisted rules are stored in rule store and are auditable.

---

## What makes this model grounded (not naive)

This model is grounded because it uses concrete security invariants, not intent guessing:

- **Fail-closed supervision**: if gate extension is disconnected, actions are denied.
- **Immutable hard denies**: secret exfiltration and critical patterns cannot be bypassed by learned allows.
- **Scoped persistence**: approvals are not all-or-nothing forever; scope and TTL limit blast radius.
- **Auditability**: every allow/deny path is logged with reason/layer/source.
- **Revocability**: learned permissions are removable.
- **Defense in depth**: policy gate + runtime boundary (container where enabled).

---

## Where this model is not magic

This system reduces risk; it does not eliminate it.

Known limits:
- It cannot perfectly infer user intent from arbitrary commands.
- Prompt injection can still trick an agent into asking for dangerous actions.
- Human approval fatigue is real; UX and defaults matter.
- Host mode has weaker isolation than container mode (no runtime boundary).

Implication: keep defaults conservative for non-experts, especially in host mode.

---

## UX contract for approval prompts

Each prompt should include:
- **Intent label** (what kind of action this is)
- **Plain summary** (human-readable)
- **Full raw action** (untruncated)
- **Why it triggered** (policy reason/risk)
- **Scope options** (once/session/workspace/global when safe)

Intent categories should be stable and simple:
- Read
- Change
- Send
- Control
- Secret

---

## Policy invariants (must hold)

1. Hard deny rules are not overrideable by learned rules.
2. Guard disconnect or timeout path is fail-closed.
3. Unknown or malformed scope defaults to `once` (no silent privilege expansion).
4. Every decision path writes an audit entry.
5. Critical-risk actions do not get permanent “always allow” by default.
6. Permission copy must match actual persistence behavior.

---

## Generality test (how to know model scales)

The model is general enough if it works across:
- different tools (`bash`, file tools, browser skill, future tools),
- different runtimes (container and host),
- different users (developer vs non-technical),
without changing the mental model.

If users still understand decisions as **Never / Ask / Remember / Explain / Review**,
then the model is stable.

---

## Current implementation alignment (today)

Already present in codebase:
- Layered policy evaluation + deny precedence (`src/policy.ts`)
- Learned rules with scope + optional expiry (`src/rules.ts`, `src/gate.ts`)
- Audit trail (`src/audit.ts`)
- Resolution options in wire protocol (`src/types.ts`)
- iOS prompt supports full action text and scope-based choices

Current gap to track:
- Ensure onboarding defaults and UX explain profile tradeoffs clearly (Dev vs Standard vs Locked).
- Add explicit profile switching and guidance in all clients, not only workspace settings.

---

## Practical rollout recommendation

1. Keep this doc as product-level contract.  
2. Keep `policy-engine-v2.md` as implementation detail.  
3. Align iOS copy and server behavior to these 5 principles.  
4. Add regression tests for invariants above.  
5. Keep regression tests for each profile mode (`host`, `host_standard`, `host_locked`, `container`).
