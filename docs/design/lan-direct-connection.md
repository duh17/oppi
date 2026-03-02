# LAN-Direct Connection (Bonjour Discovery)

**Status:** Design
**Priority:** High — eliminates 92% of WS disconnects when at home
**Depends on:** None (can ship independently of backoff fixes)

## Problem

All connections go through Tailscale (WireGuard tunnel) even when phone and server
are on the same WiFi. This adds:
- Encryption overhead per packet
- WireGuard re-key / path detection disconnects (676 code-1006 drops today)
- Tunnel keepalive traffic
- Reconnect latency after iOS process suspension

When at home (~80% of usage), this is all waste.

## Design

### Server: Bonjour Advertisement

On startup, the server advertises a Bonjour service:

```
Service type: _oppi._tcp
Service name: oppi-<serverIdPrefix>
Port: 7749 (HTTPS port)
TXT record:
  fp=<cert-fingerprint-prefix>   (first 16 chars, for matching)
  v=1                            (protocol version)
```

Node.js implementation: `mdns` or `bonjour-service` npm package, or
raw `dns-sd` via `child_process` on macOS.

### iOS: NWBrowser Discovery

```swift
let browser = NWBrowser(for: .bonjour(type: "_oppi._tcp", domain: nil), using: .tcp)
browser.browseResultsChangedHandler = { results, changes in
    for result in results {
        // Extract TXT record, match cert fingerprint to paired servers
        // If matched, construct LAN URL: https://<lanIP>:<port>
    }
}
browser.start(queue: .main)
```

### Connection Priority

```
1. LAN-direct (if Bonjour-discovered and reachable)
2. Tailscale (existing path, always available)
```

The switch is transparent to ServerConnection — only the URL changes.
TLS cert pinning works because it's fingerprint-based, not hostname-based.

### Failover

- **LAN → Tailscale:** If LAN connection fails (left home), fall back to Tailscale URL.
  Detected by WS disconnect + Bonjour service disappearing.
- **Tailscale → LAN:** If Bonjour service appears while on Tailscale, switch on next
  reconnect (don't kill a working connection).
- **No double-connections:** Only one WS active at a time. The URL is swapped, not duplicated.

## Implementation Plan

### Server (`server/src/`)

1. Add Bonjour advertisement on server startup
2. Include cert fingerprint prefix in TXT record
3. Stop advertising on shutdown
4. Config: `OPPI_BONJOUR=true` (default true for self-hosted)

### iOS (`ios/Oppi/Core/Networking/`)

1. New `LANDiscovery` service — wraps `NWBrowser`, emits discovered servers
2. `ServerCredentials` gets optional `lanURL` (populated from discovery)
3. `WebSocketClient` uses `lanURL ?? tailscaleURL` for connection
4. `ConnectionCoordinator` listens to `LANDiscovery` and updates credentials
5. Info.plist: add `NSBonjourServices` → `["_oppi._tcp"]` and
   `NSLocalNetworkUsageDescription`

### Testing

- Unit: `LANDiscovery` with mock `NWBrowser`
- Integration: verify failover LAN→Tailscale→LAN
- Manual: background app, switch WiFi networks, verify seamless transition

## Why This Kills the Delay

On home WiFi with LAN-direct:
- No WireGuard tunnel = no tunnel-related disconnects
- TCP over WiFi is stable while both devices are on the network
- iOS only kills the socket on full process suspension (background)
- Reconnect after suspension is instant (LAN, no TLS negotiation overhead)
- The 676 daily code-1006 disconnects should drop to near-zero at home

## Security

- Bonjour only advertises on the local network (not internet-reachable)
- Cert fingerprint in TXT record prevents connecting to wrong servers
- Same TLS + token auth as Tailscale path (no security downgrade)
- LAN connection still uses HTTPS (self-signed cert, pinned fingerprint)

## Alternatives Considered

- **mDNS only (no NWBrowser):** Lower-level, more code, less Apple-native
- **Hardcoded LAN IP in settings:** Fragile, breaks on DHCP changes
- **Multicast UDP discovery:** Reinventing Bonjour
- **Both connections simultaneously:** Wastes resources, complex state
