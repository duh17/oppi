# Networking and connection routing

Oppi's supported remote transport is authenticated HTTPS/WSS. Automatic Apple routing evaluates verified LAN HTTPS and paired HTTPS only. Tailscale HTTPS is supported. The local CLI uses an owner-only Unix socket.

## Supported routes

| Route | Status | Use |
| --- | --- | --- |
| LAN HTTPS/WSS | Supported | Verified local-network endpoint |
| Tailscale HTTPS/WSS | Supported | Remote access through Tailscale |


Device authentication uses a per-device P-256 signing key, short-lived HTTPS access token, single-use refresh challenge, and HTTP/WSS token refresh. The owner `sk_` credential is accepted only on the Unix socket. Existing `dt_` credentials migrate transparently over HTTPS; revocation removes the token and its binding and closes matching live WebSockets.

Older persisted connections without an HTTPS endpoint are unsupported and must be paired again over HTTPS/Tailscale. They never fall back to plaintext.

## Pairing and recovery

Pairing probes HTTPS before the one-time `/pair` mutation. A route change never replays a mutation. TLS identity failures and unknown/revoked credentials fail closed. Availability failures may retry another supported HTTPS candidate during the current selection pass.

Pairing, LAN vs Tailscale, expired invites, and `oppi status` / `oppi doctor` live in [Onboarding](../docs/onboarding.md). This page keeps leftover transport notes for contributors.

See [Client architecture](architecture-client.md), [Server architecture](architecture-server.md), and [Testing](testing/README.md).
