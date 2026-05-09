# Oppi architecture

Oppi is an Apple client plus a self-hosted server for supervising pi coding-agent sessions from mobile and desktop surfaces. The server embeds the pi SDK, owns session runtime and protocol translation, and exposes HTTP + scoped WebSocket transports to the Apple clients.

## Scope

This document explains the current production architecture at a conceptual level: runtime topology, live stream lanes, event flow, ownership boundaries, and the rules that keep the chat timeline fast. It does not document every source file or operational runbook.

## Runtime topology

The Apple app is a remote control and renderer. The server is the authority for sessions, workspace access, policy decisions, and pi SDK interaction.

```mermaid
graph TD
  subgraph Apple[Apple clients]
    App[iOS and macOS app]
    Stores[Client stores]
    Timeline[UIKit chat timeline]
    Voice[Voice input and playback]
  end

  subgraph Server[Self-hosted Oppi server]
    HTTP[REST API]
    Streams[Scoped WebSocket streams]
    Sessions[Session manager]
    Policy[Policy and permission gate]
    Pi[pi SDK AgentSession]
  end

  subgraph Workspace[Workspace runtime]
    Files[Workspace files]
    Tools[Tools and extensions]
    Sandbox[Optional sandbox runtime]
  end

  App --> HTTP
  App --> Streams
  HTTP --> Sessions
  Streams --> Sessions
  Sessions --> Policy
  Sessions --> Pi
  Pi --> Tools
  Tools --> Files
  Tools --> Sandbox
  Streams --> Stores
  HTTP --> Stores
  Stores --> Timeline
  Voice --> Streams
```

## Live transport lanes

Oppi separates live traffic by purpose. This keeps high-frequency chat deltas from invalidating workspace lists and keeps microphone audio away from timeline frames.

```mermaid
graph TD
  Client[Apple client]

  Client --> WorkspaceWS[Workspace stream<br/>/workspaces/:workspaceId/stream]
  Client --> SessionWS[Focused session stream<br/>/workspaces/:workspaceId/sessions/:sessionId/stream]
  Client --> AudioWS[Session audio stream<br/>/workspaces/:workspaceId/sessions/:sessionId/audio/stream]
  Client --> Catchup[Workspace catch-up<br/>/workspaces/:workspaceId/stream/events]

  WorkspaceWS --> Cold[Cold projections<br/>session summaries, permissions, attention]
  SessionWS --> Hot[Hot session lane<br/>timeline deltas, commands, queue sync]
  AudioWS --> Dictation[Dictation lane<br/>control frames and PCM audio]
  Catchup --> Replay[Workspace replay<br/>after reconnect]
```

| Lane | Direction | Main server owner | Main Apple owner | Carries |
|------|-----------|-------------------|------------------|---------|
| Workspace stream | Server to client | `WorkspaceStreamMux` | `WorkspaceStreamClient` | Workspace attention, session summaries, permission state, projections |
| Focused session stream | Bidirectional JSON | `BoundSessionStreamMux` | `WebSocketClient` + `SessionStreamCoordinator` | Timeline events, prompts, commands, queue sync |
| Session audio stream | Bidirectional JSON + binary | `SessionAudioStreamMux` | `DictationStreamClient` | Dictation control messages, transcript events, PCM audio |
| Workspace catch-up | HTTP GET | `WorkspaceStreamMux` | `APIClient` | Missed workspace-stream events after reconnect |

The focused session stream is bound by URL. Client commands sent over that socket already have the target workspace and session in the path.

## Event flow: prompt to pixel

Most user-visible chat work follows this path.

```mermaid
graph TD
  Prompt[User sends prompt]
  ClientMsg[ClientMessage]
  Handler[ws-message-handler.ts]
  SessionMgr[SessionManager coordinators]
  SDK[pi SDK AgentSession]
  Translate[session-protocol.ts<br/>pi event to ServerMessage]
  Sequence[session-broadcast.ts<br/>durable sequence]
  Stream[Focused session stream]
  Route[ServerConnection.routeStreamMessage]
  Manager[ChatSessionManager]
  Coalesce[DeltaCoalescer]
  Reduce[TimelineReducer]
  Render[UIKit timeline]

  Prompt --> ClientMsg
  ClientMsg --> Handler
  Handler --> SessionMgr
  SessionMgr --> SDK
  SDK --> Translate
  Translate --> Sequence
  Sequence --> Stream
  Stream --> Route
  Route --> Manager
  Manager --> Coalesce
  Coalesce --> Reduce
  Reduce --> Render
```

Durable session events get per-session sequence numbers and can be replayed through session catch-up. High-frequency deltas such as token text, thinking deltas, and tool output are treated as hot live traffic; if a reconnect misses them, the client recovers by resuming live stream or reloading the full trace.

## Client architecture

The Apple client keeps transport, shared stores, and timeline rendering separate.

```mermaid
graph TD
  subgraph Transport[Transport]
    WorkspaceClient[WorkspaceStreamClient]
    SessionClient[WebSocketClient]
    AudioClient[DictationStreamClient]
    API[APIClient]
  end

  subgraph Coordination[Coordination]
    Connection[ServerConnection]
    StreamCoord[SessionStreamCoordinator]
    Sender[MessageSender]
    Focus[FocusedSessionStore]
  end

  subgraph State[State]
    SessionStore[SessionStore]
    PermissionStore[PermissionStore]
    QueueStore[MessageQueueStore]
    ChatState[ChatSessionState]
  end

  subgraph Timeline[Per-session timeline]
    ChatManager[ChatSessionManager]
    Reducer[TimelineReducer]
    ToolStores[Tool stores]
    UIKit[ChatTimelineCollectionView]
  end

  WorkspaceClient --> Connection
  SessionClient --> Connection
  AudioClient --> Connection
  API --> Connection
  Connection --> StreamCoord
  Connection --> Sender
  Connection --> Focus
  Connection --> SessionStore
  Connection --> PermissionStore
  Connection --> QueueStore
  Connection --> ChatState
  Connection --> ChatManager
  ChatManager --> Reducer
  Reducer --> ToolStores
  Reducer --> UIKit
```

Key boundaries:

- `ServerConnection` owns per-server coordination: stream lifecycle, shared store updates, focused-session UI effects, and forwarding send operations.
- `ChatSessionManager` owns one session's timeline pipeline: reducer, coalescer, correlator, and reconnect scheduling.
- Timeline row rendering is UIKit-backed for the hot path. SwiftUI owns navigation shells, forms, and high-level composition.
- Stores are split by reason to re-render. Hot timeline deltas must not rebuild workspace/session list projections unless they also carry cold summary state.

## Server architecture

The server has one composition root and two request boundaries. The diagram shows ownership layers, not every call edge.

```mermaid
graph TD
  Client[Apple clients]

  subgraph Entry[Server entry]
    Root[server.ts<br/>composition root]
  end

  subgraph Boundaries[Boundary adapters]
    REST[REST routes<br/>routes/*]
    Live[Live streams<br/>stream.ts + ws-message-handler.ts]
  end

  subgraph Runtime[Session runtime]
    Sessions[SessionManager<br/>sessions.ts]
    Flow[session-* coordinators]
    Pi[pi SDK bridge<br/>sdk-backend.ts]
  end

  subgraph Infrastructure[Shared infrastructure]
    Gate[Permission gate<br/>gate.ts + policy.ts]
    Store[Persistence<br/>storage/*]
    Ops[Search, metrics,<br/>push, live activity]
  end

  Client --> Root
  Root --> REST
  Root --> Live
  REST --> Sessions
  Live --> Sessions
  Sessions --> Flow
  Flow --> Pi
  Sessions --> Gate
  Sessions --> Store
  Sessions --> Ops
```

Read the server as four blocks:

| Block | Owns | Does not own |
|-------|------|--------------|
| `server.ts` | startup, dependency wiring, HTTP/WS entry | session semantics |
| `routes/*` | HTTP parsing, auth boundary, REST response shape | runtime orchestration |
| `stream.ts` + `ws-message-handler.ts` | WebSocket framing, scoped stream fan-out, client-message routing | pi SDK lifecycle |
| `sessions.ts` + `session-*` | session lifecycle, queue, stop, event translation, SDK calls | HTTP/WS transport details |

Core rules:

- `server.ts` is the composition root; subsystems do not import it.
- Route modules are boundary-only and depend on explicit route context services.
- `stream.ts` owns transport framing and fan-out, not session command semantics.
- `ws-message-handler.ts` routes client messages into `SessionManager` and `GateServer`.
- `types.ts` is the protocol contract leaf shared by tests and client mirrors.

## Protocol boundary

The protocol is mirrored manually on both sides:

- Server source of truth: `server/src/types.ts`
- Apple mirrors: `ClientMessage.swift`, `ServerMessage.swift`, and `StreamMessage`
- Snapshot and codable tests guard drift.

When a message contract changes, update server types, Apple models, and protocol tests together. Partial protocol updates are invalid because a mismatched app/server pair can fail at the transport boundary.

## Design invariants

- Keep hot timeline traffic separate from cold workspace/session projections.
- Use the focused session stream for one session's timeline and command plane.
- Use the workspace stream for attention and list projection state.
- Use the audio stream for server dictation so microphone frames do not compete with chat deltas.
- Apply shared store updates exactly once per inbound live event on the client.
- Keep reducers and coalescers UI-framework-free; keep UIKit-specific rendering under the timeline package.
- Prefer narrow dependencies in views: REST-only views use `APIClient`, UI state uses `ChatSessionState`, and transport actions go through `ServerConnection`.

## Where to look in code

| Concern | Server | Apple |
|---------|--------|-------|
| Capability advertisement | `server/src/routes/identity.ts` | `ServerInfo.swift`, `ServerConnection.refreshStreamCapabilities()` |
| WebSocket upgrade routing | `server/src/server.ts` | `WorkspaceStreamClient.swift`, `WebSocketClient.swift`, `DictationStreamClient.swift` |
| Stream muxes | `server/src/stream.ts` | `ServerConnection.swift`, `SessionStreamCoordinator.swift` |
| Session runtime | `server/src/sessions.ts`, `server/src/session-*.ts` | `ChatSessionManager.swift`, `ChatActionHandler.swift` |
| Protocol contract | `server/src/types.ts` | `ClientMessage.swift`, `ServerMessage.swift` |
| Timeline rendering | `session-protocol.ts`, `session-broadcast.ts` | `TimelineReducer.swift`, `ChatTimelineCollectionView.swift` |
| Dictation | `dictation-manager.ts`, `stt-provider.ts` | `OppiDictationProvider.swift`, `OppiDictationSession.swift` |
