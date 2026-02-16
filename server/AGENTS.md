# Oppi Server — Agent Principles

Node.js/TypeScript server runtime for the Oppi coding agent platform.

## Commands

```bash
npm install     # Install dependencies
npm test        # Run all tests (vitest)
npm start       # Start server
npm run build   # TypeScript compile
npm run check   # typecheck + lint + format check
```

## Structure

```
src/            Source code
tests/          Test files (vitest)
extensions/     Built-in extensions (permission-gate)
sandbox/        Container sandbox config
docs/           Server design docs
scripts/        Server ops scripts
```

## Key Files

- `src/index.ts` — CLI entrypoint
- `src/server.ts` — HTTP/WebSocket server + model catalog
- `src/types.ts` — Protocol types (shared with iOS client)
- `src/sessions.ts` — Session lifecycle + RPC bridge
- `src/policy.ts` — Layered policy engine
- `src/gate.ts` — Permission gate (TCP per-session)
- `src/sandbox.ts` — Apple container orchestration
- `src/auth-proxy.ts` — Credential-isolating reverse proxy
- `src/push.ts` — APNs push notification client
- `src/storage.ts` — Persistent config + session + workspace storage
- `src/stream.ts` — Multiplexed WebSocket streams
- `src/skills.ts` — Skill registry with file watcher
- `src/extension-loader.ts` — Host extension discovery + resolution

## Testing

Comprehensive vitest suite. Run with `npm test`.
