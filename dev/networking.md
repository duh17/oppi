# Networking and connection routing

Oppi's supported remote transport is authenticated HTTPS/WSS. Automatic Apple routing evaluates verified LAN HTTPS and paired HTTPS only. Tailscale HTTPS is supported. The local CLI uses an owner-only Unix socket.

## Supported routes

| Route | Status | Use |
| --- | --- | --- |
| LAN HTTPS/WSS | Supported | Verified local-network endpoint |
| Tailscale HTTPS/WSS | Supported | Remote access through Tailscale |
| Public HTTPS reverse proxy | Supported | `publicUrl` + optional `proxy.trustedPeers`; phone uses system CA |


Device authentication uses a per-device P-256 signing key, short-lived HTTPS access token, single-use refresh challenge, and HTTP/WSS token refresh. The owner `sk_` credential is accepted only on the Unix socket. Legacy `dt_` credentials are rejected; old clients must update and re-pair. Device revocation removes its access tokens and closes matching live WebSockets. No automatic credential migration runs on either side.

Older persisted connections without an HTTPS endpoint are unsupported and must be paired again over HTTPS/Tailscale. They never fall back to plaintext.

## Pairing and recovery

The iOS app and Share extension have no ATS domain exceptions, only `NSAllowsLocalNetworking`. A leaf pin (self-signed or manual TLS) therefore works only on IP, `.local`, or unqualified hosts; ATS applies default CA trust to every other DNS name and cannot be loosened by the trust delegate. `*.ts.net` invites require `tls.mode=tailscale` (Tailscale-issued, no pin). The server refuses other modes in `generateInvite`, and the app rejects a pinned tailnet invite before the trust prompt.

Pairing probes HTTPS before the one-time `/pair` mutation. A route change never replays a mutation. TLS identity failures and unknown/revoked credentials fail closed. Availability failures may retry another supported HTTPS candidate during the current selection pass.

Pairing, LAN vs Tailscale, reverse proxy, expired invites, and `oppi status` / `oppi doctor` live in [Onboarding](../docs/onboarding.md) and [Reverse proxy](../docs/reverse-proxy.md). This page keeps leftover transport notes for contributors.

## Reverse proxy trust

`publicUrl` is the Origin/public-host authority. Oppi never builds security URLs from arbitrary `Host` or `X-Forwarded-Host`. Trusted private HTTP requires:

1. The real socket peer is in `proxy.trustedPeers` (CIDRs; IPv4-mapped IPv6 is normalized).
2. Exactly one `X-Forwarded-Proto: https` value. Missing, comma-lists, duplicates, and any other value fail closed.
3. The proxy overwrites `X-Forwarded-For`. Oppi uses a single overwritten client IP for pairing/challenge rate limits; otherwise it falls back to the socket peer. Leftmost/vendor headers are ignored.
4. Owner `sk_` and `/mirror/v1/bridge` remain Unix-socket only, including through a trusted proxy.

Public-domain invites omit the origin leaf pin. Apple clients use system CA on the paired public hostname and do not Bonjour-bypass that pair to a LAN IP. Tailscale no-pin LAN shortcuts stay Tailscale-only.

Isolated Docker proof: `server/proxy-review/` (`npm run test:proxy-review`). Do not reuse `server/e2e/docker-compose.e2e.yml`.

See [Client architecture](architecture-client.md), [Server architecture](architecture-server.md), and [Testing](testing/README.md).
