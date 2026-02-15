# Oppi Server — Agent Principles

Node.js/TypeScript server runtime for the Oppi coding agent platform.

## Commands

```bash
npm install     # Install dependencies
npm test        # Run all tests (vitest)
npm start       # Start server
npm run build   # TypeScript compile
```

## Structure

```
src/            Source code
tests/          Test files
extensions/     Built-in extensions (permission-gate)
sandbox/        Container sandbox config
docs/           Server design docs
scripts/        Server ops scripts
```

## Key Files

- `src/index.ts` — CLI entrypoint
- `src/server.ts` — HTTP/WebSocket server
- `src/types.ts` — Protocol types (shared with iOS client)
- `src/sessions.ts` — Session management
- `src/policy.ts` — Policy engine
- `src/security.ts` — Security layer

## Testing

760+ tests via vitest. Run with `npm test`.
