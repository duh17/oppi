# Durable extension UI

Part of [Oppi server architecture](../architecture-server.md). The convention for durable extensions' dialogs, persistent UI, and transcript cards; it adds no slash commands, terminal components, or protocol fields.

## Requests

- Native implementations are plugins (`server/plugins/<name>/server.ts`). Inside a replay-safe tool, call `requestUI(api, request, context)` from `oppi/v1` (`server/src/oppi-v1.ts`, re-exporting `durable-extension-api.ts` and `durable-ui.ts`) with a stable id such as `durable-ui:${api.taskId}`; a replayed tool must reuse it. Methods: `ask`, `select`, `confirm`, `input`, `editor`. A relative `timeout` becomes an absolute `timeoutAt` on first publication.
- Each request is one `oppi.extension-ui` document entry (`taskId`, `request`, optional `response`). Writers are trusted in-process code; use `requestUI`, never direct `tx.doc` writes. The field allowlist guards against accidents, not hostile writers.
- `DurableUIProjection` watches the document (`watchDoc`; custom documents are not in `viewState`) and emits the same backend events as `SdkUiBridge`; the extension UI state owner sanitizes and bounds them. No relay code tests extension, tool, status, or widget identities.
- `respondToExtensionUIRequest` commits the first answer before returning success and rejects unknown, answered, terminal-owner, and abort-marked requests. The tool moves the answer into a task memo, so a crash on either side of the memo replays the same answer without a second dialog.
- `ask` answers use the existing wire format; the native ask allows one call per model turn (a replay of the same task is allowed).
- Startup restores pending UI before resuming the Harness. Abort and Stop cancel the task scope first and remove requests; they never send an ignored answer, which could start another model request. A timeout commits a cancelled response at the original deadline.

## Persistent state

`notifications` in the same document is a map of replacement slots (`setStatus`, `setWidget`, `setWorkingMessage`, `setWorkingIndicator`, `setWorkingVisible`), one per key. Clear a slot by replacing it with an empty notification of the same method and key, never by removing it, so reconnect also clears stale client state. Storage follows pi-durable's `pi.live` rule (a complete base whenever no working message shows).

- **Working words:** a background task watches `pi.live` and publishes only a working message, cleared while idle; the host ensures one task per attachment.
- **Subagent pill:** `oppi.sessions`' conversation-scoped task (`oppi.subagent-widget`, `widget.ts`) owns the children's activity-list widget. It follows documents (`oppi.subagents`, each child's `pi.live` and `oppi.extension-ui`), never a polling timer, and writes only when derived state changes; attach calls `ensureSubagentWidget` (`sessions/contract.ts`). Write cadence and invocation lifetime are explained in `widget.ts`.

## Transcript cards

An entry with no `model` and a `data.card` (`TranscriptCard`, `sanitizeTranscriptCard` from `transcript-card.ts`, so classic trace reads do not load the durable runtime) is a display card: non-empty title, millisecond `at`, optional `subtitle`, `status`, `body` (≤4096 UTF-8 bytes), up to eight `fields` (≤500 chars), `accent` (`info`, `success`, `warning`, `error`); unknown properties are dropped. History projects it as a `system` event with `presentation.kind="custom"`; live append emits a notice `entry:<entry-id>`. Cards never appear in `get_messages` or model context.

## Build and loading

- `server/plugins/` is the built-in plugin root: its `package.json` `chord.plugins` lists the built-ins in install (prompt section) order, and each folder holds a feature's facet (`server.ts`), its classic entry when it has one, and shared code. `auto-name` is not listed: it loads as an opt-in Pi package. TypeScript emits `dist/plugins/`, and `scripts/copy-plugins.mjs` copies every `package.json` and the TypeScript of Pi packages, never a `server.ts` beside the emitted `server.js`.
- Every facet loads through the plugin host (`plugin-host.ts`), never a static import, because only it resolves `oppi/v1`. What the server reads of a built-in lives in its `contract.ts`, which imports nothing from `oppi/v1`. Tests import facets through the `oppi/v1` alias in `vitest.config.ts`.
- The durable import graph stays behind the lazy backend boundary: `SessionManager` loads the Harness only when `experimental.serverDurable` is on or a stored session is bound to a conversation.

## Background jobs

- The native extension replaces CodingTools bash (durable later-wins rule) and offers `background_job start/cancel`; bash backgrounds itself after 15 s in the foreground.
- Each execution is a conversation-owned task; a memo claims it before the shell starts, so after a restart or shutdown a claimed, unfinished execution reports `interrupted` and never reruns (the report warns the old process may still run; SIGKILL cannot run cleanup).
- Reporting persists the result, then submits a follow-up under the stable `background-job:<id>` request id and finishes once admitted (pi-durable's `23-subagent-background` pattern). Stop can discard a queued report; it is never resubmitted under another id. Clients cannot use the reporter namespace for `clientTurnId`.
- A compact card in `oppi.input-cards` (generic display metadata, keyed by request id) marks the report as a generated input: excluded from the editable queue, preserved by queue replacement, rendered as a card in history, omitted from `get_messages`.
- Output (the last 64,000 characters) is saved at completion in the task-scoped `oppi.background-job-output` document, retired when the runner settles, so output stays only in the transcript. Ordinary Stop preserves background jobs.
- `background-jobs/panel.ts` owns the job panel: a session surface (`oppiHost().surfaces(env)`) whose one action is Stop. Surfaces live only in the Session's memory, so `server.ts` republishes it from `DurableJobs` after each job change and when a runner resumes; a conversation without a live Session has no panel. Stop sets `cancelRequested`, the flag `background_job cancel` sets, through a handle the runner registers while its shell runs. The classic `index.ts` cannot reach `surface()` and keeps its v1 widget.
- Crash smoke: `node --import tsx scripts/durable-background-jobs-smoke.ts` after `npm run build`, through the credential-approved tool.

## Input-card output

An input card may advertise `output: { kind: "terminal", offset, length, command?, truncated? }` (UTF-16 offsets into the submitted text, length ≤64,000). Projection publishes only `{ kind, entryId, command?, truncated? }`. `GET /workspaces/:workspaceId/sessions/:sessionId/input-card-output/:entryId` (and the control equivalent) checks ownership, visible ancestry, the receipt/card association, and bounds; anything else is 404, and reading never resumes execution. Truncation is disclosed, never claimed recoverable.

## SQLite explorer

`sql-explorer` offers read-only `sqlite_schema`/`sqlite_query` (`replay: "safe"`). Every query runs through `api.env.exec` as `sqlite3 -readonly -safe -noinit -json -- <path> <sql>` (`-noinit` because `~/.sqliterc` runs before `-safe`) with a timeout and output cap, never `node:fs`, `node:child_process`, or in-process SQLite. The tool result (a markdown table) is the whole answer, shown as an ordinary tool row; the plugin publishes no surface and writes no widget slot.

## Proof commands

From `server/`: `npm run check:server`, `npm test`, `npm run check:pack-contents` after a build. Live ask smoke: `node --import tsx scripts/durable-extension-ui-smoke.ts` after `npm run build`, through the credential-approved tool; it uses a throwaway server and never touches the owner runtime.
