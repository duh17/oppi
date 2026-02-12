# Happy (slopus/happy) vs Pi Remote — Architecture Review

> Reviewed 2026-02-06 against `main` branch of `github.com/slopus/happy`.

## Executive Summary

Happy is a polished, feature-rich mobile remote for Claude Code (and Codex/Gemini) built as an **Expo React Native app** with a **cloud-hosted relay server** and **CLI wrapper**. It takes a fundamentally different architectural approach from Pi Remote. The two projects solve the same problem — phone access to coding agents — but make opposite bets on nearly every axis.

**Happy is a relay/wrapper.** Pi Remote is a supervision layer for a self-hosted agent runtime.

---

## Architecture Comparison

| Dimension | Happy | Pi Remote |
|---|---|---|
| **Agent relationship** | Wraps Claude Code/Codex/Gemini CLIs | Hosts pi agent in managed containers |
| **Server** | Cloud relay (Fastify + Postgres + Redis + S3) | Self-hosted Node.js (flat-file JSON) |
| **Mobile client** | Expo React Native (iOS + Android + web + macOS via Tauri) | Native SwiftUI (iOS 26+) |
| **CLI** | `happy` wrapper that spawns `claude`/`codex`/`gemini` | pi is the agent itself, pi-remote is the server extension |
| **Transport** | Socket.IO over HTTPS | Raw WebSocket over HTTP |
| **Encryption** | E2E encrypted (NaCl/AES-GCM), server is zero-knowledge | Plaintext over private network (Tailscale) |
| **Auth** | Public-key challenge/response | Shared token (QR code provisioning) |
| **State management** | Zustand-like sync reducer + CRDT-style versioned fields | Separate `@Observable` stores per concern |
| **Permissions** | Forwarded from Claude Code SDK via agent state + RPC | First-class pi extension events over WebSocket |
| **Multi-device** | Yes (any device, any time, E2E encrypted sync) | Single active device (one WS stream per session) |
| **Local/remote toggle** | "Press any key" to switch between desktop and phone | Phone is always remote, desktop runs pi TUI |

---

## What Happy Does Well (Things We Should Consider)

### 1. Optimistic Concurrency on Metadata
Happy uses `expectedVersion` on all mutable fields (session metadata, agent state, daemon state, artifacts, KV). Version mismatches return the current value so the client can merge. Pi Remote has no versioning — last write wins.

**Relevance:** Low for v1 (single active device), but important when we add macOS client or multi-device. Worth adding `version` fields to session state for conflict detection.

### 2. Persistent vs Ephemeral Event Split
Happy cleanly separates `update` events (persistent, sequenced, recoverable after reconnect) from `ephemeral` events (presence, usage, not stored). Each update has a per-user monotonic `seq` so clients can detect gaps and catch up.

**Relevance:** High. This is exactly what we're missing for reconnect. Our `state` events are somewhere in between — they carry session state but aren't sequenced. Adopting a seq-based update model would solve the "reconnect can't restore streamed tool events" blocker.

### 3. Machine/Daemon Concept
Happy has a first-class "machine" entity that represents a development computer. The daemon runs in the background, maintains machine state on the server, and can spawn sessions on demand from mobile. This means the phone can start a session on a machine that's just running the daemon — no active terminal needed.

**Relevance:** Interesting for v2. Pi Remote currently requires a session to exist (created from TUI or phone). A daemon model would let the phone wake up a pi agent on any configured machine.

### 4. Offline Resilience + Reconnection
Happy has a dedicated `serverConnectionErrors.ts` (12KB!) with backoff, offline detection, and automatic reconnection with session re-establishment. The CLI can run Claude locally when the server is unreachable and hot-reconnect when it comes back.

**Relevance:** We have basic reconnect but nothing this robust. The offline-first pattern of running the agent locally and syncing later is compelling but architecturally different from our model (server runs the agent).

### 5. RPC Bridge for Remote Tool Execution
Happy uses Socket.IO RPC to forward commands (bash, file read/write, ripgrep) from the phone through the server to the machine daemon. This lets the phone drive the agent without the agent process being in the foreground.

**Relevance:** We do something similar with our WebSocket `prompt`/`permission_response` messages, but Happy's RPC is more general-purpose and bidirectional. Worth considering for v2 features like remote file browsing.

### 6. Cross-Platform Mobile (Expo)
One codebase → iOS, Android, web, macOS (Tauri). Pi Remote is native SwiftUI which gives us better iOS integration but limits platform reach.

**Relevance:** Intentional trade-off. We chose native for iOS 26 integration (Liquid Glass, Live Activities, VisionKit). Adding Android would require a separate app or a shared protocol layer.

---

## What Happy Gets Wrong (Or Where We're Better)

### 1. Claude Code Wrapper, Not Agent Runtime
Happy wraps `claude` CLI as a subprocess. It has no control over the agent's execution environment — no container isolation, no sandbox, no resource limits. The agent runs with the user's full permissions on their machine.

**Pi Remote advantage:** Pi runs agents in Docker containers with explicit permission gates. The server manages the full lifecycle. This is fundamentally more secure for autonomous agent operation.

### 2. Cloud Relay Dependency
Happy routes all communication through `happy-api.slopus.com`. While E2E encrypted, this creates a dependency on a third-party cloud service for basic functionality. If their servers go down, phone→agent communication stops (unless you self-host their Postgres+Redis+S3 stack).

**Pi Remote advantage:** Fully self-hosted. Runs on your machine, reachable over Tailscale. No external dependencies, no data leaving your network.

### 3. Complexity
Happy's server has 80+ source files, Prisma ORM, Redis, S3, Prometheus metrics, social features (friends, feed), artifacts, KV store, voice integration (LiveKit + ElevenLabs), GitHub OAuth, vendor token management, and i18n across 9 languages. The CLI is 35K+ lines with tmux integration, offline stubs, and multi-runtime support.

**Pi Remote advantage:** ~2000 lines of server code, ~3000 lines of iOS app. Simple enough to audit in an afternoon. Appropriate for a personal tool.

### 4. No Container Isolation
Happy's permission model forwards Claude Code's built-in permission prompts to the phone. But Claude Code's permissions are opt-in and bypassable (`bypassPermissions` mode). There's no server-enforced sandbox.

**Pi Remote advantage:** Permissions are enforced by the pi agent's extension system. The server mediates — the agent cannot proceed without explicit approval for gated operations.

### 5. Expo/React Native vs Native SwiftUI
Happy uses Expo with `react-native-unistyles` for styling. This gives cross-platform reach but:
- No Liquid Glass integration
- No native Live Activities / Dynamic Island
- No VisionKit DataScanner (they use expo-camera for QR)
- Layout shift issues they explicitly warn about in CLAUDE.md
- 90KB+ single page components (`input-styles.tsx` is 91KB, `new/index.tsx` is 104KB)

**Pi Remote advantage:** Native SwiftUI means first-class platform integration, smaller binary, better performance, and direct access to iOS 26 features.

### 6. E2E Encryption is Complexity Tax
The zero-knowledge model means every piece of data goes through encrypt→base64→transmit→base64→decrypt. Session metadata, agent state, every message — all encrypted client-side. This is a significant complexity cost for a personal tool running on your own network.

**Pi Remote advantage:** Plaintext over Tailscale (WireGuard encrypted at network layer). Simpler protocol, easier debugging, lower latency. The threat model is different — your own machines on your own mesh network.

---

## Patterns Worth Adopting

### ✅ Adopt: Update Sequence Numbers
Add a per-session monotonic `seq` to state events. Clients track their last-seen seq and can request catch-up on reconnect.

**Effort:** Small server change. Add `seq: number` to session state, increment on each event, add `GET /workspaces/:wid/sessions/:id/events?since=<seq>` endpoint.

### ✅ Adopt: Persistent vs Ephemeral Event Split
Formally separate durable state changes (message added, status changed) from transient signals (thinking indicator, typing, presence). Only persist durables.

**Effort:** Already partially done (our `state` events carry session snapshots). Need to formalize which events are recoverable.

### ✅ Adopt: Session Activity Cache / Batched Writes
Happy debounces presence signals in memory and batch-writes to Postgres. We do something similar with `dirtySessions` + debounced flush, but could formalize it.

**Effort:** Already implemented. Just document the pattern.

### ⚠️ Consider: Optimistic Concurrency
Add `version` to session metadata for conflict detection. Not urgent for single-device v1, but prevents subtle bugs when macOS client is added.

**Effort:** Medium. Requires version tracking in storage, conditional updates in API.

### ⚠️ Consider: Daemon/Machine Model
Allow pi-remote to register as a background service that can spawn sessions on demand. Currently requires an active terminal or phone-initiated session.

**Effort:** Large. Requires rethinking session lifecycle.

### ❌ Skip: E2E Encryption
Our threat model (Tailscale mesh, personal devices) doesn't require it. The complexity cost is enormous and the security benefit is marginal when you control both endpoints.

### ❌ Skip: Cloud Relay
Self-hosted is our core value proposition. Adding a cloud relay would undermine the architecture.

### ❌ Skip: Cross-Platform Mobile
Native SwiftUI is the right choice for iOS-first. Android can come later as a separate app sharing the protocol, not a shared React Native codebase.

### ❌ Skip: Social Features
Friends, feed, artifacts, KV store — these are product features for a consumer app. Pi Remote is a personal tool.

---

## Protocol Comparison

### Happy Wire Protocol
```
Client → Server: Socket.IO events (message, update-metadata, session-alive, usage-report)
Server → Client: update (persistent, sequenced) | ephemeral (transient)
Auth: Public-key signatures → Bearer token
Encoding: JSON with base64 encrypted blobs
Concurrency: Versioned fields with expectedVersion
```

### Pi Remote Wire Protocol
```
Client → Server: WebSocket JSON frames (prompt, permission_response, stop)
Server → Client: WebSocket JSON frames (state, delta, tool_call, permission_request, etc.)
Auth: Shared token in WS upgrade headers / REST Authorization
Encoding: Plain JSON
Concurrency: Last-write-wins (server authoritative)
```

### Key Difference
Happy's protocol is designed for **multi-device sync** — any number of clients can connect and stay in sync via sequenced updates. Pi Remote's protocol is designed for **single-stream supervision** — one active WebSocket per session, server is source of truth.

Both are valid for their use cases. Happy's is more complex but handles multi-device gracefully. Ours is simpler and appropriate for the "phone as permission authority" model.

---

## Summary

Happy is an impressive engineering effort solving a similar problem with different constraints (cloud-hosted, cross-platform, multi-agent, consumer-facing). The key takeaways for Pi Remote:

1. **Sequenced updates for reconnect** — the most actionable gap in our architecture
2. **Persistent/ephemeral event split** — formalize what we already partially do
3. **Keep our simplicity** — Happy's 80+ file server and 100KB page components validate our lean approach
4. **Keep native** — their Expo workarounds (explicit "never use unistyles for expo-image", layout shift warnings) validate our SwiftUI choice
5. **Keep self-hosted** — the cloud relay is a liability, not an advantage, for power users
