# Oppi architecture

Oppi is an Apple client plus an Oppi server for viewing, prompting, and steering Pi coding-agent sessions from iPhone, iPad, and Mac clients. The server embeds the Pi SDK for managed sessions, can mirror a live terminal-owned Pi TUI session through the Oppi Mirror extension, and exposes HTTP plus scoped WebSocket transports to Apple clients and the mirror bridge.

## Audience and scope

This page is the cross-system map. Use it when you need to understand how the Apple app, server, Pi SDK runtime, and terminal mirror runtime fit together.

For implementation details, read the split pages:

- [Server architecture](architecture-server.md) — HTTP routes, stream muxes, runtime ownership, session coordinators, storage, mirror bridge, and server boundary rules.
- [Client architecture](architecture-client.md) — Apple stores, transport coordinators, workspace navigation, chat timeline pipeline, extension UI rendering, and client boundary rules.

This page does not document every source file or operational runbook.

## Runtime topology

The Apple app is a remote control and renderer. The server is the authority for sessions, workspace access, runtime configuration, and the mobile-facing session projection. Execution can be owned either by the server's Pi SDK runtime or by a terminal Pi TUI process connected through the mirror extension.

```mermaid
graph TD
  subgraph Apple[Apple clients]
    App[iOS and macOS app]
    WorkspaceUI[Workspace home and detail]
    Timeline[UIKit chat timeline]
    Voice[Voice input and playback]
  end

  subgraph Server[Oppi server]
    HTTP[REST API]
    Streams[Focused session, app event,<br/>and audio streams]
    Router[Session runtime router]
    Sessions[Managed SessionManager]
    Mirror[Pi TUI mirror runtime]
    Bridge[Mirror bridge WebSocket]
    ExtensionUI[Pi extension UI relay]
    Storage[SQLite session store and local-session catalog]
    Project[Shared Pi session projection]
    Pi[Pi SDK AgentSession]
  end

  subgraph Workspace[Workspace runtime]
    Files[Workspace files]
    Tools[Tools and extensions]
    Sandbox[Optional sandbox runtime]
  end

  App --> HTTP
  App --> Streams
  HTTP --> Router
  HTTP --> Storage
  Streams --> Router
  Router --> Sessions
  Router --> Mirror
  Bridge --> Mirror
  Sessions --> ExtensionUI
  Sessions --> Pi
  Sessions --> Project
  Mirror --> Project
  Pi --> Tools
  Tools --> Files
  Project --> Storage
  Tools --> Sandbox
  HTTP --> WorkspaceUI
  Streams --> WorkspaceUI
  Streams --> Timeline
  Voice --> Streams
```

## Runtime ownership and projection

Oppi treats managed SDK sessions, mirrored terminal sessions, and local JSONL imports as adapters into one Pi-backed session model.

```mermaid
graph TD
  Managed[Managed SDK adapter<br/>server owns execution]
  Mirror[Mirror bridge adapter<br/>terminal Pi owns execution]
  Local[Local JSONL catalog<br/>cold read-only projection]
  Projection[Shared Pi session projection<br/>events, media, titles, summaries]
  Store[SQLite session store]
  Client[Apple clients]

  Managed --> Projection
  Mirror --> Projection
  Local --> Store
  Projection --> Store
  Store --> Client
```

The adapters differ where ownership semantics differ: start, stop, abort, remote commands, queue control, and extension UI response delivery. Shared projection code owns Pi event translation, session mutation, media materialization, title and first-message policy, summaries, and the SQLite read model. Live mirror and local JSONL import coalesce by `piSessionId` and canonical `piSessionFile`, so one terminal session appears as one Oppi row.

Persisted runtime ownership uses `Session.runtime == "oppi"` for server-owned SDK sessions and `Session.runtime == "pi-tui"` for terminal-owned mirror sessions. `SessionRuntimes` dispatches command, catch-up, pending UI, and snapshot calls by that field.

## Transport map

Oppi keeps workspace navigation HTTP-first. WebSockets carry live state where streaming is required.

| Lane                                        | Transport                   | Carries                                                                                |
| ------------------------------------------- | --------------------------- | -------------------------------------------------------------------------------------- |
| Workspace home summaries                    | HTTP                        | Workspace cards, active/stopped counts, attention and error flags                      |
| Workspace detail recent list                | HTTP                        | Recent active/stopped session summaries, attention snapshot, importable local sessions |
| Workspace archive bucket                    | HTTP                        | Older stopped/importable rows for one lazy-loaded time bucket                          |
| Workspace files and media                   | HTTP GET/HEAD               | Directory listings, raw bytes, uploads, attachments, byte-range media                  |
| Workspace quick actions and review comments | HTTP                        | Prompt-template options, selected-file preparation, review comments                    |
| Global app event stream                     | Server-to-client WebSocket  | Session row updates, extension UI attention, workspace invalidation                    |
| Focused session stream                      | Bidirectional WebSocket     | Timeline events, prompts, commands, queue sync, focused session summaries              |
| Focused session catch-up                    | HTTP GET                    | Missed durable focused-session events after reconnect                                  |
| Mirror bridge                               | Bidirectional WebSocket     | Terminal-owned session registration, takeover, commands, queue, extension UI proxying  |
| Dictation stream                            | Bidirectional JSON + binary | Dictation control frames, PCM audio, transcript events                                 |

## Prompt to pixel

Most chat work follows this path. Managed and mirror runtimes differ in the owner of execution, then converge before projection and broadcast.

```mermaid
graph TD
  Prompt[User sends prompt]
  ClientMsg[ClientMessage]
  Handler[ws-message-handler.ts]
  Router[SessionRuntimes]
  SessionMgr[SessionManager coordinators]
  Mirror[PiTuiMirrorRuntime]
  SDK[Pi SDK AgentSession]
  Terminal[Pi TUI bridge]
  Translate[Shared Pi session projection]
  Sequence[session-broadcast.ts<br/>durable sequence]
  Stream[Focused session stream]
  Route[ServerConnection.routeStreamMessage]
  Manager[ChatSessionManager]
  Coalesce[DeltaCoalescer]
  Reduce[TimelineReducer]
  Render[UIKit timeline]

  Prompt --> ClientMsg
  ClientMsg --> Handler
  Handler --> Router
  Router --> SessionMgr
  Router --> Mirror
  SessionMgr --> SDK
  Mirror --> Terminal
  SDK --> Translate
  Terminal --> Translate
  Translate --> Sequence
  Sequence --> Stream
  Stream --> Route
  Route --> Manager
  Manager --> Coalesce
  Coalesce --> Reduce
  Reduce --> Render
```

Durable session events get per-session sequence numbers and can be replayed through focused-session catch-up. High-frequency deltas such as token text, thinking deltas, and tool output are hot live traffic. If a reconnect misses them, the client resumes the live stream or reloads the full trace.

## Cross-system invariants

- Workspace navigation is HTTP-first. `/app/events/stream` keeps visible rows and attention state fresh between snapshots.
- The hot workspace recent list is time-bounded. Older stopped/importable history belongs in archive buckets.
- Workspace session-list endpoints return session summaries, not full `Session` payloads.
- Hot workspace endpoints do not reread `~/.pi/agent/sessions/*.jsonl`; importable TUI metadata comes from the cached local-session catalog and SQLite read models.
- Runtime adapters share Pi event projection. Managed SDK sessions and terminal mirror sessions use the same translation, session mutation, media materialization, title/first-message derivation, summary, and storage projection code where ownership semantics allow it.
- Mirror sessions are terminal-owned. The server does not auto-start a Pi SDK runtime for a connected or stale `runtime == "pi-tui"` session.
- Hot timeline traffic stays separate from cold workspace/session projections.
- The global app event stream is store-level only. It must not carry timeline deltas, full state, queue state, command results, dictation/audio, or raw `GitStatus` payloads.
- Reconnect repair for the global app event stream comes from HTTP snapshots, not app-event replay.
- File previews, attachments, and media playback stay on authenticated HTTP routes with byte-range support.
- Workspace quick-action discovery, selected-file prompt-template preparation, and review comments stay on HTTP routes. Only the created or focused session uses the session stream.
- Shared store updates apply exactly once per inbound live session event on the client.
- Reducers and coalescers stay UI-framework-free. UIKit-specific rendering lives under the timeline package.
- Imported TUI sessions remain resumable without mutating original JSONL traces.

## Protocol boundary

The protocol is mirrored manually on both sides:

- Server source of truth: `server/src/types/protocol.ts`, re-exported by `server/src/types.ts`
- Apple mirrors: `ClientMessage.swift`, `ServerMessage.swift`, `AppEventMessage.swift`, and `StreamMessage`
- Snapshot and Codable tests guard focused-stream and app-event drift.

When a message contract changes, update server types, Apple models, and protocol tests together. Partial protocol updates are invalid because a mismatched app/server pair can fail at the transport boundary.
