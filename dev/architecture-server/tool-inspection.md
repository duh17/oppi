# Oppi server architecture: Tool inspection

Part of [Oppi server architecture](../architecture-server.md); same standard (owners, boundaries, invariants, entry points).

## Tool inspection facts

- `MobileRendererRegistry` owns tool identity, matching Pi's exact tool name; modules own segments (`mobile-renderer-segments.ts`), facts (`mobile-renderer-facts.ts`), display (`mobile-renderer-display.ts`), and availability (`mobile-renderer-availability.ts`). There is no second registry. Built-ins and sidecars declare facts (`inputPresentation.fields` roles, `outputPresentation.kind`); projection and trace replay consume them and keep no shell-name list. History resolves facts from the current registry.
- File roles: `filePath`, `fileContent`, `edits`, `lineOffset`/`lineLimit`; outputs `fileContent`/`diffOfEdits` carry `provenance: requested | result` (write content and args-derived previews are requested). Apple models tolerate unknown fields.
- Explicit result `details.outputPresentation` and `details.expandedText` override the declaration; unknown kinds degrade to structured output. With no producer facts at all, only the client's compatibility resolver synthesizes facts for exact `bash`, `read`, `write`, `edit`, `ask`, and never availability or setting authority.
- `outputPresentation.settingEffect: "voiceReplyMode"` is declaration-owned: result details cannot grant themselves a setting effect. `statusHeader` is a declared regex (≤200 chars) clients anchor at the start and search only in the first 512 characters; copy and raw keep the header.

## Full output and snapshot lifetime

- `outputAvailability` is `{ complete, totalBytes?, source? }` where `source` is `"sidecar"`, never a path. Live and history publication strip `details.fullOutputPath` and path-bearing members; the server keeps the originals for lookup. A source fact allows reads by tool-call id but does not promise the file survives a stopped session.
- `ToolOutputSnapshots` (`tool-output-sidecar.ts`) owns each runtime's uncut in-memory output and the tool-end-to-trace handoff, kept until `turn_end`. A Pi-truncated snapshot is a delta baseline and is never served as full output; truncated trace text never substitutes for a missing Pi file.
- Terminal preview (kind `terminal`, never a tool name): ANSI stripped; under 8 KiB only the new suffix; past it a replace of the last 80 lines capped at 16 KiB, at most every 150 ms; a finished result replaces the preview. No byte cursor or live VT owner on the row.

## Outlines

Trace outlines carry facts, display metadata, and budgeted path/command/range/edit arguments so clients never classify raw names; file contents and code blobs are excluded. Arguments and details share a 64 KiB per-request budget with an 8 KiB per-object cap, omitted (never truncated) when over; summaries cap at 160 characters. Compaction is its own entry, not a synthetic tool. Neither runtime captures Pi TUI render snapshots.
