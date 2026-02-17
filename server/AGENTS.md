# Oppi Server

Node.js/TypeScript server that manages pi CLI sessions, policy, and iOS push.

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
