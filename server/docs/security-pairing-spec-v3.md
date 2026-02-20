# Oppi Security + Pairing Spec (v3 Draft)

**Status:** Draft (design contract for upcoming simplification)
**Scope:** `oppi-server` + iOS client
**Intent:** practical protections only; avoid unverifiable security claims.

---

## 1) Security Reality (Non-Negotiable)

Oppi exposes a high-privilege remote control surface (pi can run shell commands, read/write/edit files, etc.).

Treat an authenticated Oppi session as equivalent to **SSH access to your workstation**.

This spec optimizes for:
- strong identity + auth semantics,
- clear blast-radius control,
- deployment portability (LAN, Tailscale, Cloudflare, VPS),
- no “security theater” toggles that imply guarantees we cannot enforce.

---

## 2) Threat Model + Boundaries

### In scope
- Unauthorized client connecting to HTTP/WS endpoints
- Token leakage/misuse
- Pairing replay attacks
- Accidental public exposure from misconfiguration
- Privilege confusion between auth tokens and push-notification tokens

### Out of scope (for now)
- Full enterprise IAM/SSO
- Formal multi-tenant RBAC
- Guaranteed MITM prevention on arbitrary LAN without trusted transport/pinning

---

## 3) 3-Layer Security Model

Keep these concerns separate:

1. **Reachability** (how phone reaches server)
   - LAN / Tailscale / Tunnel / Public host
2. **Transport** (TLS / trust of endpoint)
   - Public CA certs, tailnet HTTPS, or explicit pinning strategy
3. **Application Auth + Pairing** (who is allowed)
   - one-time pairing bootstrap → long-lived per-device credential

No single layer substitutes for the other two.

---

## 4) Credential Classes (Strict Separation)

Token classes MUST NOT overlap.

- `sk_...` = **Owner/Admin token**
  - high-privilege administrative credential
- `pt_...` = **Pairing token**
  - one-time, short-lived bootstrap secret
- `dt_...` = **Auth device token**
  - long-lived per-device API credential
- `pushDeviceTokens[]` = APNs push registration tokens
  - never accepted as API auth
- `liveActivityToken` = APNs live activity token
  - never accepted as API auth

### Hard rule
Only `sk_...` and `dt_...` can authenticate API/WS calls.

---

## 5) Stable Server Identity (Keep, but Honest)

Keep a stable server identity (existing fingerprint or equivalent immutable `serverInstanceId`) for:
- iOS server dedupe,
- trust reset prompts,
- continuity across host/port/token changes.

This identity is a **continuity signal**, not magic security by itself.

It only upgrades security if:
1. captured at trusted pairing time,
2. checked on reconnect,
3. mismatch requires explicit user trust reset.

---

## 6) Pairing Protocol (v3)

## 6.1 Pairing bootstrap
`oppi pair` creates one pairing session:
- `pairingToken` (`pt_...`)
- `expiresAt` (default 90s, max 120s)
- optional metadata: host/port hint, server identity fingerprint

Server prints/scans QR with payload:

```json
{
  "v": 3,
  "host": "...",
  "port": 7749,
  "pairingToken": "pt_...",
  "name": "...",
  "fingerprint": "sha256:..."
}
```

### Requirements
- single-use
- short TTL
- not reusable after success
- never embeds `sk_...`
- pairing invites should avoid embedding long-lived bearer tokens; use `pairingToken` bootstrap instead
- current pairing invite format is unsigned v3 payload only

## 6.2 Pair exchange API
`POST /pair`

Request:
```json
{ "pairingToken": "pt_...", "deviceName": "Chen iPhone" }
```

Response:
```json
{
  "deviceToken": "dt_..."
}
```

Semantics:
- validate token format + expiry,
- consume token atomically,
- issue new `dt_...`,
- reject replay,
- return generic errors (`invalid or expired pairing token`).

## 6.3 Abuse controls
Minimum required:
- bounded failed attempts per minute,
- short cooldown after repeated failures,
- audit entry for failed pairing attempts.

---

## 7) Authentication + Authorization Rules

## 7.1 Auth acceptance
- Accept: `Bearer sk_...` and `Bearer dt_...`
- Reject: APNs tokens, live-activity tokens, unknown formats

## 7.2 Token capabilities
- `sk_...`: admin + operational endpoints
- `dt_...`: normal client/session endpoints (and push registration if desired)

Exact endpoint scoping can start coarse and tighten later.

## 7.3 Revocation
Server must support:
- revoke one `dt_...`
- revoke all `dt_...`
- rotate `sk_...`

Rotation/revocation events must be visible in logs/audit.

---

## 8) Network Exposure Guardrails

1. **Hard bind guard**
   - refuse non-loopback bind when no auth token exists
2. **Source CIDR allowlist enforcement**
   - apply to HTTP + WS upgrade
3. **Startup warnings**
   - wildcard bind
   - global CIDR ranges (`0.0.0.0/0`, `::/0`)
4. **Doctor command**
   - fail on critical posture, warn on risky posture

---

## 9) Deployment Profiles (Practical Guidance)

## 9.1 Recommended default (personal)
**Tailscale + app-layer auth**
- Keep app auth even on tailnet
- Treat tailnet ACLs as network gate, not sole authorization

## 9.2 LAN-only
- If no trusted public cert, do not claim strong MITM resistance
- Optional: use explicit pinning strategy in pairing payload

## 9.3 Tunnel/Public internet
- Require TLS at edge
- keep app auth mandatory
- enforce rate limits + CIDR controls where possible

---

## 10) Config Model (v3 target)

Security-relevant fields (target):

```json
{
  "configVersion": 3,
  "host": "0.0.0.0",
  "port": 7749,
  "allowedCidrs": ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10"],
  "token": "sk_...",
  "authDeviceTokens": ["dt_..."],
  "pushDeviceTokens": ["...apns..."],
  "liveActivityToken": "..."
}
```

Identity continuity is derived from on-disk identity material (`identity_ed25519` + `.pub`) and surfaced via server metadata APIs; it is not a mutable config field.

Removed from control plane:
- mutable security profile toggles (`requireTlsOutsideTailnet`, `allowInsecureHttpInTailnet`, etc.)
- mutable trust posture endpoints that imply transport guarantees

---

## 11) Migration Rules (No Auth Widening)

From legacy config:
- `security.allowedCidrs` → top-level `allowedCidrs`
- legacy `deviceTokens` → `pushDeviceTokens` only (or quarantine), **never** directly to `authDeviceTokens`

Migration must log an explicit warning when legacy ambiguous token arrays are found.

Compatibility requirement:
- either dual-path support for one release,
- or explicit minimum iOS build gate with actionable error.

---

## 12) Logging + Audit Requirements

- Never log full token values
- Avoid token prefix leakage in auth failure logs
- Audit entries should capture:
  - token class (`sk`, `dt`, pairing)
  - device id (if known)
  - endpoint + outcome
  - revocation/rotation events

---

## 13) Required Test Gates

Server tests must prove:
1. APNs token cannot authenticate
2. `dt_...` token authenticates correctly
3. pairing token replay fails
4. expired pairing token fails
5. non-loopback + missing token fails startup
6. migration does not convert legacy push tokens into auth tokens

iOS tests/integration must prove:
1. QR with `pt_...` pairs via `/pair`
2. Keychain stores `dt_...`
3. subsequent `/me` uses `dt_...`
4. push registration does not mutate auth credential

---

## 14) Future Upgrade Path (Optional)

If stronger auth is needed later, upgrade pairing from token-based device auth to device key registration (challenge/response). This can be added without changing reachability model.

Current v3 design intentionally keeps this path open.

---

## 15) Execution Milestones + Exit Criteria

### M1 — Token separation + migration safety (P0)
**Done when:**
- API auth accepts only `sk_...` and `dt_...`
- Push/live activity tokens are rejected for API auth
- Legacy `deviceTokens` migrate to `pushDeviceTokens` only
- Tests pass:
  - `tests/auth-token-separation.test.ts`
  - `tests/config-migration-v3.test.ts`

### M2 — Pair bootstrap split (`pt_ -> /pair -> dt_`)
**Done when:**
- `oppi pair` emits one-time `pt_...` invite payload
- `POST /pair` consumes `pt_...` atomically and issues `dt_...`
- Replay and expiry cases fail as expected
- iOS onboarding uses `/pair` and stores `dt_...`

### M3 — Exposure guardrails
**Done when:**
- non-loopback bind without token fails startup with actionable message
- CIDR enforcement covers HTTP and WS paths
- `oppi doctor` exits non-zero on critical posture

### M4 — Remove legacy mutable security profile surface
**Done when:**
- deprecated security profile mutation endpoints removed
- iOS/server contract migration completed (dual-path window or min-build gate)
- no references to removed profile mutation flow remain
