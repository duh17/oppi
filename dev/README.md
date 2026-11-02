# Contributor docs

In-repo guides for people and agents changing Oppi. Public user docs live in [`docs/`](../docs/index.md).

- [Architecture](architecture.md): cross-system map
- [Server architecture](architecture-server.md): routes, streams, runtime ownership, storage, protocol boundary
- [Client architecture](architecture-client.md): Apple stores, transports, chat timeline
- [Networking](networking.md): HTTPS/WSS routing, pairing trust, embedded Tailscale
- [Telemetry](telemetry.md): diagnostics policy, catalog, storage, review commands
- [Testing](testing/README.md): server, Apple, simulator, E2E, coverage, and gate commands

## What belongs in dev/

Every sentence here must pass one test: would an agent changing this area tomorrow need it to avoid breaking something?

- **Architecture docs** record only owners (which type or module owns what), boundaries (what may depend on what), invariants and rules (with the crash or bug that taught them, in one clause, a commit ref at most), and the entry points an agent needs to find code. Each item is a sentence or two naming the owning type or file.
- **Testing docs** record commands, schemes, selectors, gotchas that bite, and how to read gate output.
- **Everything else** (telemetry, networking) passes the same test.
- **Not here:** feature behaviour, UI details, step-by-step flows, history, per-slice narratives, and past investigations. Put a non-obvious *why* in a short comment at the owning type, and behaviour in tests.

`scripts/dev-docs-guard.ts` enforces a word budget per file and a 1,200-character limit per paragraph or list item; generated regions count toward neither. Budgets live in `dev/doc-budgets.json` as `{ words, reason }` per doc (headroom max(15%, 100 words)), and that reason is the one place a budget is justified: a new doc adds an entry, and raising a budget rewrites its reason to name the new rules that need the room. First try moving narrative into code comments and tests. The guard runs in the pre-push gate whenever `dev/**/*.md`, the budget file, or the guard changes.
