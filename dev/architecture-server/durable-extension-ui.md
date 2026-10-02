# Durable extension UI

Use this convention when porting a Pi extension to the experimental server-durable backend. It requires `experimental.serverDurable`. Classic Pi resource discovery and classic extension factories remain unchanged. This convention does not add slash commands, terminal components, MCP, or client protocol fields.

## Publish a request

Native implementations live at `pi-extensions/<name>/durable.ts`. Import `requestUI` from `pi-extensions/durable-ui.ts` inside a replay-safe Durable tool:

```typescript
const response = await requestUI(
  api,
  {
    id: `durable-ui:${api.taskId}`,
    method: "confirm",
    title: "Continue?",
    message: "Apply the proposed change?",
    extensionScopeId: "repo:my-extension",
    extensionDisplayName: "My Extension",
  },
  context,
);
```

The helper creates one `oppi.extension-ui` conversation document entry per stable request ID. Each entry has `taskId`, a Pi-shaped `request`, and an optional `response`. Supported blocking methods are `ask`, `select`, `confirm`, `input`, and `editor`. Request fields match the existing extension UI protocol, including question options, multi-select, custom answers, provenance, and absolute `timeoutAt`. A relative `timeout` becomes an absolute deadline on first publication. Replayed tools must reuse their request ID.

Writers of `oppi.extension-ui` are trusted in-process host code, with the same trust as classic `ctx.ui`. Use `requestUI` for blocking requests, not direct `tx.doc` writes. The host owns `harness.sqlite`; hostile co-tenant extensions are out of scope. The event-field allowlist guards against accidental overrides, not hostile writers.

`DurableUIProjection` watches this document with `watchDoc`; custom documents are not in `viewState`. It emits the same backend events as `SdkUiBridge`. The existing extension UI state owner sanitizes text and native widgets, bounds payloads, throttles notifications, and builds ServerMessages. No relay code tests extension, tool, status, or widget identities.

## Answer, cancel, and restart

`respondToExtensionUIRequest` commits the first answer before returning success. It rejects unknown, answered, terminal-owner, and abort-marked requests. The tool watches for that committed answer, stores it in a task memo, and removes its document entry. A crash before the memo write leaves the answer in the document; a crash after it leaves the answer in the memo. Safe tool replay therefore returns the same answer without publishing a second dialog. The Harness commits one tool-result entry.

`ask` responses use the existing wire format: `value` is a JSON answer map, for example `{"color":"red","extras":["tests","docs"]}`. `cancelled` returns an ignored result. The native ask tool uses the assistant-entry identity to enforce one call per model turn; a replay of the same task is allowed.

Process detach stops watchers and timers without changing documents or answering tools. Startup restores pending UI before resuming the Harness. Focused-stream reconnect uses the existing pending/persistent UI snapshot accessor. Abort and Stop cancel the task scope first and remove outstanding document requests. They must not send an ignored answer to a tool just before stopping it, because that could start another model request. Timeout commits a cancelled response at the original absolute deadline; the relay remains authoritative after restart.

## Publish persistent state

`notifications` is a map of replacement slots in the same document. Each value contains an `id`, a protocol `method`, its data, and optional provenance. Supported methods are `setStatus`, `setWidget`, `setWorkingMessage`, `setWorkingIndicator`, and `setWorkingVisible`. Use distinct slots for distinct keys and global working-row properties. A widget can carry `widgetLines`, `widgetPlacement`, and a serializable `nativeSurface` with the existing native block schema.

To clear a slot, replace its value with an empty notification of the same method and key. Keep that clear value in the document so reconnect also clears stale client state. Do not remove the slot as a clear operation. These are snapshots, not an event log; transient `notify` and composer handoffs are outside this convention.

The native working-words extension owns a background Durable task. It watches `pi.live`, writes plain working frames and status, chooses a phrase every 1.5 seconds while busy, and clears the message while idle. The host ensures one task at conversation attachment, including after an explicit Stop. Closing the Harness cancels its local timer and watcher. The classic `/working-words` preview command and terminal color styling have no Durable equivalent.

The native goal extension publishes goal status and a widget through replacement slots in the same document. Its separate `oppi.goal` document stores the latest goal; typed transcript entries retain full snapshots and continuation reasons. A conversation-owned task submits a new input after the current run settles, with a stable request ID across restart. Abort/Stop cancels that task but retains the goal; progress-only updates do not restart it. Its widget derives the active/stopped subtitle from runner liveness. Decision entries publish display-only transcript cards so reasons survive history reload without entering model context. The phone sets and inspects goals through model tools, without a new protocol or slash command. See [Goal extension](../../pi-extensions/goal/README.md#server-durable-port) for restart, compaction, and UI parity limits.

## Publish a transcript card

Append an entry with no `model` and a `data.card` object:

```typescript
{
  title: "Runner decision",
  status: "continue",
  body: "Work remains; checks are incomplete.",
  fields: [{ label: "Continuation", value: "1/5" }],
  accent: "info",
  at: Date.now(),
}
```

`TranscriptCard` and `sanitizeTranscriptCard` are available from `durable-ui.ts`. The pure helper lives in `transcript-card.ts` so classic trace reads do not load the Durable runtime. A card requires a non-empty title and a valid millisecond timestamp. Optional fields are `subtitle`, `status`, `body`, `fields`, and `accent` (`info`, `success`, `warning`, or `error`). Projection allows at most eight label/value fields, caps display fields at 500 characters and body text at 4096 UTF-8 bytes, and discards unknown properties. Keep full evidence in entry data.

History projects a valid card as the existing `system` event with `presentation.kind="custom"`, without a renderer or an extension-name check. Live append emits one ephemeral notice with ID `entry:<entry-id>`. Catch-up does not replay notices; trace reload restores the card. Cards do not appear in `get_messages` or model context. Classic entries without cards still require their live renderer.

## Build and loading

`server/extensions/durable/` contains symlinks to the canonical native implementations, the shared document helper, and ask's existing pure result helper. TypeScript follows these source paths and emits ordinary JS under `dist/extensions/durable/`, which the npm package includes. The server imports only this compiled layout. No code depends on the excluded `dist/oppi-extensions/` tree, and no Pi factory is imported.

The Dockerfile copies the canonical native ports and their pure helpers into `/opt/pi-extensions/`, beside `/opt/server/`, to keep the same relative symlink targets inside the build image. This uses the existing compiler layout without a source-generation step. The runtime uses only the emitted JS.

`npm run dev` uses tsx with `--preserve-symlinks` so native source imports resolve dependencies from `server/node_modules`. Other source-mode commands that import the native ports must use that Node option too. Compiled and packed commands need no option. The entire import graph remains behind the existing lazy durable-backend boundary; flag-off commands load no Durable modules.

## Background jobs

The native background-jobs extension replaces CodingTools bash by the Durable later-wins rule. It offers `background_job start/cancel`; the classic extension has no list/output tool actions. Durable has no `/jobs` command. Ordinary bash runs in the foreground for up to 15 seconds, then returns a job notice. A trailing `&` backgrounds immediately. A timeout of one second or less remains foreground.

Each shell execution belongs to a conversation-owned background task. A memo claims execution before the shell starts. On process restart or graceful shutdown, a claimed but unfinished execution reports `interrupted` and does not rerun. The report warns that the previous host or guest process might still run and must be confirmed dead before starting it again. Each completion persists its follow-up request ID, initially `background-job:<id>`. A receipt counts as delivered only when it is placed or done and its content matches the report. A queued receipt remains pending. A withdrawn or mismatched receipt gets a new persisted ID, `background-job:<id>:<n>`, before resubmission. Clients cannot use the native reporter namespace for `clientTurnId`. Per-job receipts take priority over classic-style single-message batching; results can cause separate model turns. There is no auto-stop hold.

The extension publishes status and a native activity-list widget through the same notification slots as other native extensions. Output is bounded to the last 64,000 characters and is saved at completion, not streamed to a live widget. Delivery clears the retained output in the same commit that marks the job delivered. Foreground bash retains its output until its starter commits the tool result. Ordinary Stop preserves background jobs, including guest execution, within the current process. Startup resumes background work from live idle sessions, but aborts all task scopes for explicitly stopped sessions before releasing the scheduler. Cancel signals the execution environment and reports cancellation; a background abort crosses the ownership boundary. A foreground bash that has not returned its notice is cancelled by Stop.

SIGKILL cannot run environment cleanup. A host shell process can outlive the killed server; reporting interruption does not prove that external side effects stopped. The smoke runner records and removes its own process group during teardown.

The opt-in crash runner is `node --import tsx scripts/durable-background-jobs-smoke.ts` after `npm run build`. Run it through the credential-approved tool. It starts a throwaway server through the local API socket, selects `anthropic/claude-haiku-4-5`, confirms shell execution, kills the server, and verifies one interrupted follow-up and one durable receipt after restart. It copies credentials into private temporary storage and preserves its receipt and server logs.

## Proof commands

From `server/`, run `npm run check:server`, `npm test`, and `npm run check:pack-contents` after a build. The durable integration suite covers SDK request-field parity, first-answer-wins, all blocking methods, reconnect, pending restart, the answer/memo crash window, one ask per turn, Abort/Stop, working state, and generic native widgets.

The opt-in live runner is `node --import tsx scripts/durable-extension-ui-smoke.ts` after `npm run build`. It uses only a throwaway server and data directory, copies Pi credentials into that private directory, selects `anthropic/claude-haiku-4-5`, kills the server with SIGKILL while ask is pending, and answers the same request after restart. Run it through the credential-approved tool. It preserves the report and server logs; it never restarts an owner runtime or installs an app.

The corresponding goal smoke is `node --import tsx scripts/durable-goal-smoke.ts` after a build. It creates a goal, lets one continuation reach a pending ask, kills the owned server, and verifies the same goal/checklist/count and dialog after restart. Answering the dialog completes the goal; history must contain one create and two submitted user inputs (the original and one continuation), plus visible goal-decision cards in trace and no `[Goal runner]` user rows. Run it only through the credential-approved tool.
