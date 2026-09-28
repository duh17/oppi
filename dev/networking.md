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

## Embedded Tailscale node (iOS)

iOS can join the tailnet itself through the official userspace TailscaleKit (`github.com/tailscale/libtailscale`, `swift/`), with no Network Extension, VPN entitlement, or auth key. `TailnetNodeController` runs the node after the user connects from Settings → Network → Tailscale. Login and run state come from the IPN bus (`BrowseToURL`, `State`); the machine list comes from LocalAPI status (`TailscaleNode.statusJSON()`), not from `NWPathMonitor`. Node state lives in Application Support/Tailscale, excluded from backup.

While the node is Running, `TailnetTransportRoute` adds the node's loopback SOCKS5 proxy (user `tsnet`, per-node credential) to every Oppi HTTPS/WSS URLSession, scoped by `matchDomains` to `ts.net` and `beta.tailscale.net`. `Running` can land before `publishRoute` finishes; same-user pairing waits for the current-generation proxy before it builds a bootstrap URLSession. LAN IPs and public hosts stay direct; failover keeps a system Tailscale VPN usable if the loopback listener is gone. TLS and leaf pinning are unchanged end to end. Transports read the route only when they build a session, so each route change rebuilds paired `*.ts.net` servers that are not on LAN (`ConnectionCoordinator.handleTailnetRouteChange`). The share extension runs in its own process without the node.

`POST /pair/tailscale` proves same-user identity with `tailscale whois --json` `UserProfile.LoginName` (not `User.LoginName`) on the socket peer, off the request thread, with admission before spawn. Tagged identities and trusted-proxy ingress fail closed. Invites advertise only `tls.mode=tailscale` MagicDNS names.

iOS can reclaim the loopback listener from a suspended app. A bus watch that fails before delivering anything recreates the node from its saved state (at most once per 30 seconds); an idle long-poll that ends after delivering is re-watched.

### Mac setup check over SSH

Settings → Network → Tailscale → Check a Mac for Oppi (`SSHPreflightView`) signs in to a Mac's ordinary Remote Login (sshd, not Tailscale SSH) to report what Oppi's installer needs, without a terminal and without installing anything. The machine picker reuses the LocalAPI online peers, plus a manual hostname or tailnet IP.

- Transport: `TailnetNodeController.dialTCP` calls `tailscale_dial` directly. TailscaleKit's `OutgoingConnection` wrapper is send-only; the C call returns the local end of a socketpair that SwiftNIO adopts (`ClientBootstrap.withConnectedSocket`). `tailscale_dial` has no deadline, so `BlockingSocketDial` bounds it (15 s) and closes a socket that arrives after timeout or cancellation.
- SSH: `SSHPreflightClient` (swift-nio-ssh). Host key first: an unknown key stops the connection before the password is offered and shows its `SHA256:` fingerprint; the user trusts it and the check reconnects. A changed key fails with both fingerprints and can be forgotten explicitly. `SSHKnownHosts` stores trusted keys in UserDefaults by lowercased host and port; nothing else is saved.
- Auth: password only, offered once. A second prompt maps to "not accepted"; a server that does not list `password` maps to "does not accept password sign-in". Sign-in is bounded at 20 s.
- Probe: one exec of `/bin/sh -s` with `SSHPreflightProbe.script` on stdin (no PTY, no shell session), bounded at 20 s. It adopts the login shell's PATH, since sshd's non-interactive PATH lacks Homebrew, and reports `id -un`, `uname`, `sw_vers`, `command -v node npm git oppi`, `node --version`, and whether the Xcode Command Line Tools are installed (the `/usr/bin/git` stub does not count without them). Output without the final `end=1` line is rejected. Node must meet `server/package.json` `engines.node`.
- Cancel or leaving the screen cancels the task, which closes the SSH connection and the tailnet socket.

The framework is not tracked (the Go c-archive exceeds the repository file-size limit). `clients/apple/scripts/build-tailscalekit.sh` builds the pinned libtailscale commit into `clients/apple/Vendor/TailscaleKit/TailscaleKit.xcframework`, keeping Go caches under `clients/apple/.build/tailscalekit`. A matching xcframework is reused from `~/Library/Caches/oppi-tailscalekit/<commit>/` without compiling. The frameworks are built unsigned; the Oppi target embeds them with Code Sign On Copy.

Isolated Docker proof: `server/proxy-review/` (`npm run test:proxy-review`). Do not reuse `server/e2e/docker-compose.e2e.yml`.

See [Client architecture](architecture-client.md), [Server architecture](architecture-server.md), and [Testing](testing/README.md).
