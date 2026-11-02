# Networking and connection routing

User-facing pairing and setup: [Onboarding](../docs/onboarding.md), [Reverse proxy](../docs/reverse-proxy.md).

Remote transport is authenticated HTTPS/WSS over LAN, Tailscale, or a public HTTPS reverse proxy (`publicUrl`, optional `proxy.trustedPeers`, system CA on the phone). iOS tries verified LAN HTTPS first on Wi-Fi or Ethernet, then in-app Tailscale, then the system resolver (including a system Tailscale VPN); there is no route picker. The Share extension has no Bonjour browser or embedded node.

## Credentials and pairing

- Device auth: per-device P-256 signing key, short-lived access token, single-use refresh challenge. The owner `sk_` credential is accepted only on the Unix socket. Legacy `dt_` credentials are rejected (re-pair, no migration). Revocation removes access tokens and closes matching live WebSockets. Logs never expose tokens or keys.
- Pairing runs an approver (`invite`, `/pair/tailscale`, or `auth.module`'s `approvePairing`), then one policy: with another active device, a `tailscale` or `custom` pairing, or an invite with TTL over 90 000 ms, gets `202 approval_required` and waits in memory (`server/src/device-pairing.ts`, 120 s, at most 8) until a paired device signs `oppi:pair-approve:v1.<id>.<RFC 7638 key thumbprint>` (`POST /auth/pairing-approvals/:id/approve`, device principals only, never the owner socket). The waiting device polls `POST /pair/approval-status` (TLS-only).
- `auth.module` (`server/src/auth-module.ts`) loads before the network listener; its `gate` runs before `/health`, bootstrap, and token checks on network requests and upgrades (Unix-socket requests skip it). A module that fails to load makes the gate answer 503 everywhere, with no fallback.
- `/auth/challenge` is rate-limited per source only, and `issueChallenge` evicts a device's oldest challenge instead of refusing: a per-device limit let anyone who knew a device id exhaust it.
- Pairing probes HTTPS before the one-time `/pair` mutation; a route change never replays a mutation. Connections without an HTTPS endpoint must re-pair; nothing falls back to plaintext.
- The apps have no ATS domain exceptions, only `NSAllowsLocalNetworking`, so a leaf pin works only on IP, `.local`, or unqualified hosts. `*.ts.net` invites require `tls.mode=tailscale` (no pin): `generateInvite` refuses other modes and the app rejects a pinned tailnet invite before the trust prompt.

## iOS connection policy

`ServerRouteController` builds verified-LAN and paired HTTPS candidates, each with its final authenticated `APIClient`, and probes `GET /server/info` under one bootstrap deadline. A route with current health evidence stays installed across foreground and network changes. Availability failures may try another candidate and stay retryable; TLS identity or protocol failures stop fallback; unknown or revoked credentials fail closed.

- LAN: cold preparation waits up to 500 ms for the first verified Bonjour endpoint; a LAN bootstrap has a 1 s total deadline and must match the paired fingerprint and pin checks. Cellular paths and endpoints Bonjour removed are never LAN candidates.
- An enabled in-app node has up to 6 s to publish its current-generation SOCKS proxy before the client uses the system resolver; a disabled or failed node never blocks system routing.
- The winning HTTP client's atomic proxy/generation snapshot is shared with focused, app-event, and dictation streams, including later ones; if the proxy changes during bootstrap, a fresh candidate pass runs before streams bind. A tailnet route notification never rebuilds LAN, a current-generation SOCKS connection, or an in-flight preparation.
- Bonjour promotes a remote connection to LAN only when no work is active (a starting/running/stopping session, a pending turn send, live dictation), on Bonjour arrival or the next foreground. A path change, Bonjour removal, or persistent stream-health failure demotes LAN; one HTTP availability failure does not. LAN becomes eligible again at a path or foreground boundary, never on a timer.
- Logs: `Verified LAN discovery` (`discoveryMs`) and `Route committed` (`route`, `pathType`, `sinceLaunchMs`).

## Reverse proxy trust

`publicUrl` is the Origin and public-host authority; security URLs are never built from `Host` or `X-Forwarded-Host`. Trusted private HTTP requires: the socket peer in `proxy.trustedPeers` (CIDRs, IPv4-mapped IPv6 normalized); exactly one `X-Forwarded-Proto: https` (anything else fails closed); a proxy-overwritten `X-Forwarded-For`, used as the single client IP for rate limits (leftmost and vendor headers ignored). Owner `sk_` and `/mirror/v1/bridge` stay Unix-socket only through a proxy. Public-domain invites omit the leaf pin, and clients never Bonjour-bypass that pair to a LAN IP. Isolated proof: `server/proxy-review/` (`npm run test:proxy-review`); do not reuse `server/e2e/docker-compose.e2e.yml`.

## Embedded Tailscale node (iOS)

- `TailnetNodeController` runs the official userspace TailscaleKit (no Network Extension, VPN entitlement, or auth key). The machine list comes from LocalAPI status, not `NWPathMonitor`, re-read at most every 3 s after peer-change notifications. Node state lives in Application Support/Tailscale, excluded from backup.
- `TailnetTransportRoute` adds the node's loopback SOCKS5 proxy to every Oppi HTTPS/WSS URLSession, scoped by `matchDomains` to `ts.net` and `beta.tailscale.net`; LAN and public hosts stay direct, and TLS pinning is unchanged. Transports read the route only when they build a session. Network framework connections use `TailnetTransportRoute.apply(to:route:)` (Rex's `RexTLSStream`, because URLSession's WebSocket task cannot carry Rex's in-app framing). `ConnectionCoordinator.handleTailnetRouteChange` rebuilds only paired `*.ts.net` servers not on LAN or not already on the published generation.
- `Running` can land before the route publishes, so same-user pairing waits for the current-generation proxy. A bus watch that fails before delivering anything recreates the node from saved state (at most once per 30 s), because iOS can reclaim the loopback listener from a suspended app.
- `POST /pair/tailscale` proves same-user identity with `tailscale whois --json` `UserProfile.LoginName` (not `User.LoginName`) on the socket peer, off the request thread. Tagged identities and trusted-proxy ingress fail closed. `auth.tailscalePairing: false` answers 404 (restart required).
- Machine list (`TailnetPeerStatus.derive`): Paired by MagicDNS name match (no probe); Ready to pair only on Oppi's own `/health` answer, per the probe rules in `TailnetSameUserPairing`. Nothing branches on machine names. Probes run per visit, are cancelled on leave, and store nothing when cancelled; there is no polling timer.
- TailscaleKit is not tracked (the Go archive exceeds the file-size limit). `clients/apple/scripts/build-tailscalekit.sh` builds the pinned libtailscale commit into `clients/apple/Vendor/TailscaleKit/` with `OMIT_FEATURES` (its comments list what must stay compiled in), cached in `~/Library/Caches/oppi-tailscalekit/<build-id>/` and embedded unsigned with Code Sign On Copy.

## Machine setup over SSH

`SSHPreflightViewController` (Set Up a Computer) signs in to ordinary sshd to check, install, and pair.

- `SSHDial` picks the network: a tailnet name uses `TailnetNodeController.dialTCP` only while the embedded node runs; Check and Pair fail "Tailscale is not connected" otherwise, without `getaddrinfo`. `BlockingSocketDial` bounds `tailscale_dial` (no deadline of its own) at 15 s.
- Host key first: an unknown key stops before the password is offered; a changed key fails with both fingerprints. `SSHKnownHosts` stores trusted keys in this-device-only Keychain (`SSHKeychain`), keyed by lowercased host and port; nothing else is saved. Password auth is offered once, bounded at 20 s.
- Every script adopts the login shell's PATH (`SSHPreflightProbe.loginPathPreamble`; sshd's non-interactive PATH lacks Homebrew and nvm). Probe output without its final `end=1` line is rejected.
- Pair runs only after the same loopback health check answers, so a stopped server never mints an invite. Install & Start runs the bundled repo-root `install.sh` (`project.yml` copies it; there is no second script) and parses only the installer's `oppi-install:` contract lines, never detail text.
