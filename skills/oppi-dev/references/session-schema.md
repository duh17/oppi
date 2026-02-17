# Pi Remote Session Schema

## Session Metadata JSON

Stored at `~/.config/oppi-server/sessions/<userId>/<sessionId>.json`.

```typescript
{
  session: {
    id: string
    userId: string
    status: "ready" | "busy" | "streaming" | "error" | "stopped"
    createdAt: number        // epoch ms
    lastActivity: number     // epoch ms
    model: string
    messageCount: number
    tokens: { input: number, output: number }
    cost: number
    workspaceId: string
    workspaceName: string
    runtime: "host" | "container"
    contextWindow: number
    contextTokens: number
    piSessionFile: string    // current JSONL trace path
    piSessionFiles: string[] // all JSONL paths (compaction/fork history)
    piSessionId: string      // UUID of current pi session
    lastMessage: string
    warnings: string[]
  }
  messages: SessionMessage[] // user/assistant/system only (no tool calls)
}
```

## JSONL Trace Events

Each line in the JSONL file is a trace event. Types:

| type | key fields |
|------|-----------|
| `user` | `text` |
| `assistant` | `text` |
| `system` | `text` |
| `toolCall` | `tool`, `args` (object with typed values) |
| `toolResult` | `toolCallId`, `output` |
| `thinking` | `text` |
| `error` | `message` |

## JSONL File Locations

| Runtime | Path |
|---------|------|
| Host | `~/.pi/agent/sessions/--Users-chenda--/<timestamp>_<uuid>.jsonl` |
| Container | `~/.oppi-server/sandboxes/<userId>/<sessionId>/agent/sessions/<workspace>/<timestamp>_<uuid>.jsonl` |

## REST API Endpoints

Server runs at `localhost:7749`. All endpoints require `Authorization: Bearer <token>` header.

| Endpoint | Returns |
|----------|---------|
| `GET /health` | `{ ok: true }` |
| `GET /sessions` | `{ sessions: Session[] }` |
| `GET /sessions/:id` | `{ session, messages }` |
| `GET /sessions/:id/trace` | `{ session, trace: TraceEvent[] }` |

User tokens stored in `~/.config/oppi-server/users.json`.
