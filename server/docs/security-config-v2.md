# Security Config v2 + Signed Invite Bootstrap

Status: Draft (2026-02-11)
Owner: oppi-server server + iOS client
Related TODOs: `TODO-65cabfd5`, `TODO-2a12a17c`

## Why

Current bootstrap trust model is:
- invite QR contains plain JSON (`host`, `port`, `token`, `name`)
- iOS trusts that payload and starts using bearer auth over HTTP/WS
- transport confidentiality relies on Tailscale/WireGuard deployment assumptions

This leaves a fake-server bootstrap gap and makes security posture mostly implicit.

This doc defines:
1. **Config v2 schema** (explicit server security profile)
2. **Signed invite v2 format** (anti-fake-server bootstrap)
3. **Migration plan** (server + iOS, fail-safe rollout)

---

## Design goals

1. **Server-authored policy**: connection policy is configured on server, not guessed by client.
2. **Bootstrap authenticity**: client can verify invite came from server identity key.
3. **Pinning**: client stores server identity and detects identity drift.
4. **Operator UX**: Ghostty-style config discoverability + validation.

Non-goals (v2):
- Full PKI deployment
- Mutual TLS everywhere
- End-to-end encrypted app payloads

---

## Config v2 schema (proposed)

`~/.config/oppi-server/config.json`

```json
{
  "configVersion": 2,
  "port": 7749,
  "host": "0.0.0.0",
  "dataDir": "~/.config/oppi-server",
  "defaultModel": "anthropic/claude-sonnet-4-0",
  "sessionTimeout": 600000,
  "sessionIdleTimeoutMs": 600000,
  "workspaceIdleTimeoutMs": 1800000,
  "maxSessionsPerWorkspace": 3,
  "maxSessionsGlobal": 5,
  "legacyExtensionsEnabled": true,

  "security": {
    "profile": "tailscale-permissive",
    "requireTlsOutsideTailnet": true,
    "allowInsecureHttpInTailnet": true,
    "requirePinnedServerIdentity": true
  },

  "identity": {
    "enabled": true,
    "algorithm": "ed25519",
    "keyId": "srv-2026-02",
    "privateKeyPath": "~/.config/oppi-server/identity_ed25519",
    "publicKeyPath": "~/.config/oppi-server/identity_ed25519.pub",
    "fingerprint": "sha256:..."
  },

  "invite": {
    "format": "v2-signed",
    "maxAgeSeconds": 600,
    "singleUse": false
  }
}
```

### Field semantics

#### `security.profile`
- `legacy` — compatibility mode, minimal enforcement
- `tailscale-permissive` — allow HTTP/WS on tailnet, require stronger controls outside tailnet
- `strict` — signed invites + pinned identity required, no legacy invite acceptance

#### `security.requireTlsOutsideTailnet`
If true, iOS rejects `http://` and `ws://` targets that are not tailnet/local policy-approved.

#### `security.allowInsecureHttpInTailnet`
Controls whether plain HTTP/WS is allowed for `.ts.net`/tailnet endpoint classes.

#### `security.requirePinnedServerIdentity`
If true, once identity is pinned on client, fingerprint mismatch is hard-fail unless user explicitly resets trust.

#### `identity.*`
Defines server signing identity for invites and trust handshakes.

#### `invite.format`
- `v2-signed` (required)

---

## Signed invite v2 format

Current v1 payload:
```json
{ "host": "...", "port": 7749, "token": "sk_...", "name": "..." }
```

Proposed v2 envelope (QR payload JSON):

```json
{
  "v": 2,
  "alg": "Ed25519",
  "kid": "srv-2026-02",
  "iss": "oppi-server",
  "iat": 1760000000,
  "exp": 1760000600,
  "nonce": "k9H6fY...",
  "payload": {
    "host": "myhost.tail12345.ts.net",
    "port": 7749,
    "token": "sk_...",
    "name": "my-mac",
    "fingerprint": "sha256:...",
    "securityProfile": "tailscale-permissive"
  },
  "sig": "base64url(signature over canonical envelope without sig)"
}
```

### Verification rules (iOS)

1. Parse envelope and require `v=2` for strict mode.
2. Check `iat/exp` and reject expired invites.
3. Resolve public key by `kid` (from payload or pinned source) and verify `sig`.
4. Persist pinned server fingerprint on first successful trust.
5. On reconnect/onboarding updates, hard-fail (or explicit recovery flow) on fingerprint mismatch.

---

## Server trust contract endpoint (proposed)

`GET /security/profile`

Response:
```json
{
  "configVersion": 2,
  "profile": "tailscale-permissive",
  "requireTlsOutsideTailnet": true,
  "allowInsecureHttpInTailnet": true,
  "requirePinnedServerIdentity": true,
  "identity": {
    "enabled": true,
    "algorithm": "ed25519",
    "keyId": "srv-2026-02",
    "fingerprint": "sha256:..."
  },
  "invite": {
    "format": "v2-signed",
    "maxAgeSeconds": 600
  }
}
```

Used by iOS for sanity checks and post-bootstrap trust confirmation.

---

## Ghostty-inspired config UX for oppi-server

### New CLI

- `oppi-server config show`
- `oppi-server config show --default`
- `oppi-server config show --docs`
- `oppi-server config validate [--config-file <path>]`

### Behavior requirements

1. **Strict validation** with actionable errors (`file:line:key: reason`).
2. Unknown keys fail validation.
3. Type/range errors fail validation.
4. Optional include support with deterministic ordering and cycle detection (future if needed).
5. Clear separation of config-file options vs CLI-only options.

---

## Migration plan

### Phase 0 — Schema + tooling (safe, no behavior break)
- Add config v2 schema model in server.
- Add `oppi-server config validate` and `config show`.
- On startup: warn on insecure combinations, do not block yet.

### Phase 1 — Identity provisioning
- Generate server Ed25519 keypair if missing.
- Persist `keyId`, `fingerprint` in config.
- Expose `/security/profile`.

### Phase 2 — Signed invites (v2-only)
- `invite` command emits signed v2 invites only.
- Unsigned v1 payloads are rejected by config validation.
- iOS accepts signed v2 invites only.

### Phase 3 — Client pinning and enforcement
- iOS pins fingerprint after verified bootstrap.
- Mismatch flow: block by default; explicit “reset trust” path.
- Enforce server-authored transport profile checks.

### Phase 4 — Hardened defaults
- `invite.format = v2-signed` (required).
- transport outside tailnet must be TLS.

---

## Compatibility matrix

| Server | iOS | Result |
|---|---|---|
| any profile + v2 signed invite | current iOS | works |
| any profile + unsigned invite config | any iOS | blocked by server config validation |
| strict profile + v2-only | old iOS | blocked (expected) |

---

## Test plan (required for release gate)

1. Config parser/validator tests:
   - unknown key reject
   - invalid enum reject
   - range checks (`maxAgeSeconds`, etc.)
2. Invite signature tests:
   - valid signature accept
   - tampered payload reject
   - expired reject
3. iOS trust/pinning tests:
   - first trust stores fingerprint
   - mismatch blocks
   - explicit trust reset recovers
4. Transport policy tests:
   - non-tailnet insecure URL rejected when policy requires
   - tailnet HTTP allowed only when configured

---

## Suggested default profile (near-term)

For current dogfood:
- `security.profile = tailscale-permissive`
- `requireTlsOutsideTailnet = true`
- `allowInsecureHttpInTailnet = true`
- `requirePinnedServerIdentity = true`
- `invite.format = v2-signed`

---

## Startup warning contract (implemented)

At server boot, `oppi-server` emits non-blocking security warnings when posture is permissive/risky:

- wildcard bind (`host=0.0.0.0` / `::`)
- `security.requireTlsOutsideTailnet=false` while binding beyond loopback
- `security.profile=legacy`
- `security.requirePinnedServerIdentity=false`
- `identity.enabled=false`
- unusually long invite TTL (`invite.maxAgeSeconds > 3600`)

Warnings are advisory (not hard failures) so local dev remains possible, while insecure production posture is visible immediately.

---

## At-rest protection assumptions (P0)

### iOS client
- Server credentials are stored in Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).

### Server host
- `~/.config/oppi-server` and nested runtime directories are owner-only (`0700` directories).
- Persisted metadata (`config.json`, `users.json`, session/workspace JSON) is written with owner-only file permissions (`0600`).
- Server signing key (`identity.privateKeyPath`) is persisted as `0600`.

### Operator baseline
- File permissions are necessary but not sufficient.
- Recommended baseline:
  1. FileVault enabled on macOS host.
  2. Dedicated user account for oppi-server runtime.
  3. Do not share host login/session while server is running.

---

## Threat model and residual risk (P0)

### Addressed in this track
- Invite tampering/replay and unsigned-downgrade attempts.
- Fake-server bootstrap via signed invite + fingerprint pinning.
- Post-pairing insecure transport downgrade outside tailnet when disallowed by policy.

### Residual risk
1. **Host compromise**: attacker with host-level access can still read local state and keys.
2. **Bearer token leakage**: replay remains possible until token revocation/rotation.
3. **Network policy drift**: wildcard binds still depend on operator ACL/firewall correctness.
4. **Tailnet trust assumption**: confidentiality for HTTP/WS inside tailnet relies on WireGuard + tailnet policy hygiene.
