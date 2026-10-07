# Networking and connection routing

Oppi's supported remote transport is authenticated HTTPS/WSS. iOS tries verified LAN HTTPS first on Wi-Fi or Ethernet, then in-app Tailscale, then the system resolver (including an official Tailscale VPN). There is no user-facing route picker. The local CLI uses an owner-only Unix socket. The Share extension has no Bonjour browser or embedded node.

## Supported routes

| Route | Status | Use |
| --- | --- | --- |
| LAN HTTPS/WSS | Supported | Verified local-network endpoint |
| Tailscale HTTPS/WSS | Supported | Remote access through Tailscale |
| Public HTTPS reverse proxy | Supported | `publicUrl` + optional `proxy.trustedPeers`; phone uses system CA |


Device authentication uses a per-device P-256 signing key, short-lived HTTPS access token, single-use refresh challenge, and HTTP/WSS token refresh. The owner `sk_` credential is accepted only on the Unix socket. Legacy `dt_` credentials are rejected; old clients must update and re-pair. Device revocation removes its access tokens and closes matching live WebSockets. No automatic credential migration runs on either side.

Older persisted connections without an HTTPS endpoint are unsupported and must be paired again over HTTPS/Tailscale. They never fall back to plaintext.

## iOS connection policy

- Cold preparation waits up to 500 ms for the first verified Bonjour endpoint on a local path. An unknown startup path can use the same bounded wait; LAN is not attempted until the path is Wi-Fi or Ethernet.
- A LAN bootstrap has a 1-second total deadline. The endpoint must match the paired server fingerprint and pass the existing leaf-pin or exact paired-port Tailscale public-CA checks. Cellular paths and endpoints removed by Bonjour are not LAN candidates.
- For paired Tailscale names, an enabled in-app node has up to 6 seconds to publish its current-generation SOCKS proxy before the client uses the system resolver. This reuses the same proxy wait as same-user pairing. A disabled or failed node does not block system routing.
- A tailnet route notification does not rebuild LAN, a current-generation SOCKS connection, or an in-flight coordinator preparation. The winning HTTP client's atomic proxy/generation snapshot is shared with focused, app-event, and dictation streams, including streams built later. If the proxy changes during HTTP bootstrap, the connection starts a fresh candidate pass before binding streams. Preparation checks the current route again before returning.
- Bonjour discovery promotes a remote connection only when no work is active (a starting/running/stopping session, a pending turn send, or a live dictation recording). Promotion triggers are Bonjour arrival or the next foreground, never while work is active; finishing work does not switch the route in place. A network path change, Bonjour removal, or persistent stream-health failure demotes LAN. One HTTP availability failure does not demote a connected LAN WebSocket. After a stream-health demotion, LAN is eligible again at a path or foreground boundary, not on a timer.
- Route preparation and routine refresh keep the host badge connected when there is a viable configured transport or a prior successful sync. Initial preparation, offline states, and sync failures remain visible.

Client logs include `Verified LAN discovery` (`discoveryMs`, browse start to first verified paired endpoint; emitted when the path is known to be local) and `Route committed` (`route`, `pathType`, `sinceLaunchMs`). App-event reconnect metrics and WebSocket logs include the route captured by their transport. No new server metric names are required.

## Pairing and recovery

The iOS app and Share extension have no ATS domain exceptions, only `NSAllowsLocalNetworking`. A leaf pin (self-signed or manual TLS) therefore works only on IP, `.local`, or unqualified hosts; ATS applies default CA trust to every other DNS name and cannot be loosened by the trust delegate. `*.ts.net` invites require `tls.mode=tailscale` (Tailscale-issued, no pin). The server refuses other modes in `generateInvite`, and the app rejects a pinned tailnet invite before the trust prompt.

Pairing probes HTTPS before the one-time `/pair` mutation. A route change never replays a mutation. During one selection pass, a candidate TLS or availability failure may advance to the next supported HTTPS candidate. TLS identity failures and unknown/revoked credentials fail closed when they are the last remaining error. Availability exhaustion stays retryable.

Pairing, LAN vs Tailscale, reverse proxy, expired invites, and `oppi status` / `oppi doctor` live in [Onboarding](../docs/onboarding.md) and [Reverse proxy](../docs/reverse-proxy.md). This page keeps leftover transport notes for contributors.

## Reverse proxy trust

`publicUrl` is the Origin/public-host authority. Oppi never builds security URLs from arbitrary `Host` or `X-Forwarded-Host`. Trusted private HTTP requires:

1. The real socket peer is in `proxy.trustedPeers` (CIDRs; IPv4-mapped IPv6 is normalized).
2. Exactly one `X-Forwarded-Proto: https` value. Missing, comma-lists, duplicates, and any other value fail closed.
3. The proxy overwrites `X-Forwarded-For`. Oppi uses a single overwritten client IP for pairing/challenge rate limits; otherwise it falls back to the socket peer. Leftmost/vendor headers are ignored.
4. Owner `sk_` and `/mirror/v1/bridge` remain Unix-socket only, including through a trusted proxy.

Public-domain invites omit the origin leaf pin. Apple clients use system CA on the paired public hostname and do not Bonjour-bypass that pair to a LAN IP. Tailscale no-pin LAN shortcuts stay Tailscale-only.

## Embedded Tailscale node (iOS)

iOS can join the tailnet itself through the official userspace TailscaleKit (`github.com/tailscale/libtailscale`, `swift/`), with no Network Extension, VPN entitlement, or auth key. `TailnetNodeController` runs the node after the user connects from Settings → Tailscale. Login and run state come from the IPN bus (`BrowseToURL`, `State`); the machine list comes from LocalAPI status (`TailscaleNode.statusJSON()`), not from `NWPathMonitor`. Node state lives in Application Support/Tailscale, excluded from backup.

While the node is Running, `TailnetTransportRoute` adds the node's loopback SOCKS5 proxy (user `tsnet`, per-node credential) to every Oppi HTTPS/WSS URLSession, scoped by `matchDomains` to `ts.net` and `beta.tailscale.net`. `Running` can land before `publishRoute` finishes; same-user pairing waits for the current-generation proxy before it builds a bootstrap URLSession. LAN IPs and public hosts stay direct; failover keeps a system Tailscale VPN usable if the loopback listener is gone. TLS and leaf pinning are unchanged end to end. Transports read the route only when they build a session. A route change rebuilds paired `*.ts.net` servers only when they are not on LAN or already configured for the published SOCKS generation (`ConnectionCoordinator.handleTailnetRouteChange`). The share extension runs in its own process without the node.

`POST /pair/tailscale` proves same-user identity with `tailscale whois --json` `UserProfile.LoginName` (not `User.LoginName`) on the socket peer, off the request thread, with admission before spawn. Tagged identities and trusted-proxy ingress fail closed. Invites advertise only `tls.mode=tailscale` MagicDNS names.

iOS can reclaim the loopback listener from a suspended app. A bus watch that fails before delivering anything recreates the node from its saved state (at most once per 30 seconds); an idle long-poll that ends after delivering is re-watched.

### Machine list status

Settings → Tailscale → Online Machines (`TailnetSettingsView`) shows one state per online peer, derived by `TailnetPeerStatus.derive`:

- **Paired**: the peer's MagicDNS name (case-insensitive, no root dot) equals a paired server host. The row opens that server; no probe runs.
- **Ready to pair**: an unauthenticated `GET /health` over the node's SOCKS route returned a direct HTTP 200 with Oppi's `{ok: true, protocol: 2}` body on a `TailnetSameUserPairing.probeURLs` port (7749, then 443). Readiness probes refuse redirects and reject other services' 200 responses. The Pair button uses the same port order; its existing reachability check is unchanged.
- **Oppi needs Tailscale HTTPS**: a probe got a certificate verdict (`serverCertificateUntrusted`, `…HasUnknownRoot`, `…HasBadDate`, `…NotYetValid`), even if a later port was merely refused. `secureConnectionFailed` is not one: CFNetwork also reports resets and SOCKS failures that way, so it counts as not reachable.
- **Oppi not reachable**: refused, timed out, or not Oppi. Both setup states offer an SSH check with that peer selected: **Check this Mac** on macOS, **Check this Linux machine** on Linux, and **Check this machine** otherwise.
- iOS, iPadOS, and Android peers (`TailnetPeer.os`) are not listed. Nothing branches on machine names.

Probes start under `.task(id:)` when the screen appears with the node running and the current-generation proxy published, run concurrently (5 s per port), and every start re-probes all unpaired machines. They are cancelled when the screen disappears or the machine list changes; a cancelled probe stores nothing. There is no polling timer. Pull-to-refresh and a pairing attempt re-probe.

### Machine setup check over SSH

Settings → Tailscale → Check a machine for Oppi (`SSHPreflightView`) signs in to ordinary sshd (macOS Remote Login, or Linux `sshd`, not Tailscale SSH) to report what Oppi's installer needs, without a terminal and without installing anything. The machine picker reuses the LocalAPI online peers that can host Oppi, plus a manual hostname or tailnet IP.

- Transport: a `*.ts.net` name uses `TailnetNodeController.dialTCP` only while Oppi's embedded node is running. If that node is stopped, Check and Pair fail with “Tailscale is not connected” and do not call `getaddrinfo`. Every other host uses `SSHDirectTCP.dial` on the current network. `tailscale_dial` has no deadline, so `BlockingSocketDial` bounds it (15 s) and closes a socket that arrives after timeout or cancellation.
- SSH: `SSHPreflightClient` (swift-nio-ssh). Host key first: an unknown key stops the connection before the password is offered and shows its `SHA256:` fingerprint; the user trusts it and the check reconnects. A changed key fails with both fingerprints and can be forgotten explicitly. `SSHKnownHosts` stores trusted keys in the app-private, this-device-only Keychain (`SSHKeychain`), keyed by lowercased host and port; nothing else is saved.
- Auth: password only, offered once. A second prompt maps to "not accepted"; a server that does not list `password` maps to "does not accept password sign-in". Sign-in is bounded at 20 s.
- Probe: one exec of `/bin/sh -s` with `SSHPreflightProbe.script` on stdin (no PTY, no shell session), bounded at 20 s. It adopts the login shell's PATH, since sshd's non-interactive PATH lacks Homebrew and nvm, and reports `id -un`, `uname`, `sw_vers` (macOS), `PRETTY_NAME` from `/etc/os-release` (Linux), `command -v node npm git oppi tailscale`, `node --version`, and whether the Xcode Command Line Tools are installed (the `/usr/bin/git` stub does not count without them; Linux `/usr/bin/git` does). When `oppi` is on PATH it also runs `oppi status --json` with stdin closed, collapses the output to one `oppi_status=` line, and Swift decodes `paired` and `server.transport`, `server.tlsMode`, `server.port` from the `{ok, data: {status}}` envelope (anything else is unreadable); nothing else from it is shown. Unreadable status is informational, not a failure. Output without the final `end=1` line is rejected. Node must meet `server/package.json` `engines.node`. Checks: system (macOS or Linux; other kernels are unsupported), Node.js, npm, git, Tailscale CLI (same-account pairing runs `tailscale whois`; found on the login shell's PATH), Oppi, and Tailscale HTTPS (`transport=https` with `tlsMode=tailscale`). When Oppi is installed and that status says HTTPS, the result offers **Pair**. Pair signs in again, runs a fixed status script that prints `end=1` only after loopback `https://127.0.0.1:<port>/health` returns `{"ok":true,"protocol":2}`. The health read tries `curl`, then Node (self-signed allowed), then `wget`, so a Linux host without curl can still pair. Only then does it run `exec oppi pair --json`. The invite is enrolled through the existing bootstrap. A stopped server does not mint an invite.
- Cancel or leaving the screen cancels the task, which closes the SSH connection and the tailnet socket.

The framework is not tracked (the Go c-archive exceeds the repository file-size limit). `clients/apple/scripts/build-tailscalekit.sh` builds the pinned libtailscale commit into `clients/apple/Vendor/TailscaleKit/TailscaleKit.xcframework`, keeping Go caches under `clients/apple/.build/tailscalekit`. It compiles out tailscale.com features the embedded tsnet client never uses (`OMIT_FEATURES`: serving, advertising, daemon/CLI, Linux and cloud integrations, auth-key and MDM policy sources, OS DNS and split DNS, system proxies, port mapping, exit-node use, health warnings, metrics, and log upload), builds with `-trimpath`, and strips local symbols: 22.9 MB → about 15 MB. MagicDNS names still resolve because tsdial reads them from the netmap. The script comments list what must stay compiled in (netstack, the SOCKS5 proxy, PeerAPI client, Tailnet Lock) and why. A matching xcframework is reused from `~/Library/Caches/oppi-tailscalekit/<build-id>/` without compiling. The frameworks are built unsigned; the Oppi target embeds them with Code Sign On Copy.

Isolated Docker proof: `server/proxy-review/` (`npm run test:proxy-review`). Do not reuse `server/e2e/docker-compose.e2e.yml`.

See [Client architecture](architecture-client.md), [Server architecture](architecture-server.md), and [Testing](testing/README.md).
