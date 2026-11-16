# Plugin screens

A built-in plugin can add a sidebar entry whose pages are list screens the app draws generically. MCP Servers is one; the app has no MCP screen of its own.

## Owners

- `server/src/plugin-screens.ts` (`oppi/v1`): the `Sidebar` registry, `defineScreen` (a `local` Chord object per `{ scope, page }` with a `page` document and an `act` method), and `checkScreenPage`, the one vocabulary and budget check (64 KB a page, 200 rows a section, page ids three segments deep).
- `PluginHost` composes `Sidebar` in its core facet: built-ins' entries only, by `order`. A facet that contributes only to `Sidebar` has no extension; sessions and the extension lists never see it.
- `server/src/screens-stream.ts` owns `WS /screens/stream`: one watch per page, the first value whole, then `diffRevisions` ops against the last value sent.
- `/server/info` lists `sidebar` and `capabilities.screens.v` (`routes/identity.ts`) without waiting: its first request starts the plugins' load; the stream loads them on demand.
- An entry's `feature` names its server switch (`server-features.ts`); `ScreensStreamMux.featuresChanged` ends watches a save turns off. Scope `server` is the sidebar row; `workspace:<id>` is opened from Workspace Settings by that `feature`.
- `server/plugins/mcp-screen`: MCP Servers over `oppiHost().mcp()`.
- Apple: `PluginScreenStream`, `PluginScreenReplica` (`ChordDelta`), and `PluginScreenViewController` on `ListScreenController`; the sidebar root (`showsHost`) leads with the host row.

## Invariants

- Swift draws from protocol data only. `scripts/plugin-screen-guard.ts` fails a `PluginScreen*` file that names an entry from `protocol/screens.json`; native screens reach an entry by `ServerConnection.pluginEntry(for:scope:)`.
- One integer versions the vocabulary. A new row kind needs two real screens and a fixture; an unknown kind draws as an update notice.
- Pages are projections: nothing is persisted, and a watch has no cursor. An `act` without a result fails and is never resent; one running when its page is unwatched still finishes.

## Tests

- Server: `screens-stream.test.ts`, `mcp-screen.test.ts`, `screens-fixtures.test.ts`.
- Apple: `PluginScreenProtocolTests`, `PluginScreenViewControllerTests`.
- E2E: `PluginScreenE2ETests` against a native server (`e2e.sh --native`).
