# Auth v2 — Device Credentials & Token Theft Hardening

Status: draft (2026-02-12)

## Goals

1. Reduce blast radius of bearer-token theft.
2. Remove long-lived owner bearer token from pairing artifacts.
3. Allow per-device revoke without full server reset.
4. Keep onboarding UX fast (QR/deeplink first).

## Current state (v1)

- Single owner bearer token is minted at pairing time and persisted in `users.json`.
- Signed invite payload includes the owner bearer token.
- API/WS authenticate with `Authorization: Bearer <token>`.

## Threats to address

- Token leakage via invite payload screenshots/logs/history.
- Token leakage via host compromise of `users.json`.
- No scoped revoke (all-or-nothing owner token rotation).

## Phase plan

## Phase 0 (low-risk hardening, backward-compatible)

- Hide token from default `oppi-server pair` output.
- Add explicit `--show-token` escape hatch for emergency/manual use.
- Add operator command to rotate owner token quickly.
- Use constant-time token compare on server auth path.

## Phase 1 (protocol extension, backward-compatible)

Introduce a one-time enrollment exchange so invites no longer carry bearer credentials.

### New concepts

- `pairCode`: one-time, short-lived enrollment secret from signed invite.
- `deviceCredential`: per-device bearer credential with `id`, `secret`, `createdAt`, `lastSeen`.
- `deviceName`: optional client label (`"My iPhone"`, simulator, etc).

### New routes

- `POST /pair/enroll`
  - auth: none
  - body: `{ envelope: InviteV3Envelope, deviceName?: string }`
  - validates signature + expiry + nonce + one-time code
  - response: `{ credential: { id, secret }, owner: { id, name } }`

- `GET /me/devices`
  - auth: bearer
  - response: `{ devices: [{ id, name, createdAt, lastSeen, revokedAt? }] }`

- `DELETE /me/devices/:id`
  - auth: bearer
  - revoke a specific device credential

- `POST /me/token/rotate`
  - auth: bearer
  - rotate current device credential (rolling update)

### Storage changes

- Replace single `user.token` with:
  - `legacyOwnerToken?: string` (temporary migration bridge)
  - `deviceCredentials: Array<{ id, hash, name?, createdAt, lastSeen?, revokedAt? }>`
- Store only salted hash of credential secret (argon2id/scrypt), never plaintext.

### Server auth resolution

1. Parse bearer token into `credId.secret` (structured token format).
2. Find credential by `credId`.
3. Verify `hash(secret)`.
4. Reject revoked credential.
5. Update `lastSeen`.

## Phase 2 (defense-in-depth)

- Optional request-signing (DPoP-style) with device keypair in Secure Enclave.
- Server challenge/nonce to reduce replay value of stolen bearer.

## Migration strategy

1. Ship Phase 1 server with dual-mode auth:
   - accepts legacy owner token
   - accepts device credentials
2. Ship iOS client update that enrolls device credential on first reconnect.
3. After all active clients migrate, disable legacy owner token acceptance.

## Non-goals (for now)

- Full OAuth/JWT infrastructure.
- Multi-user RBAC.
- External identity provider integration.
