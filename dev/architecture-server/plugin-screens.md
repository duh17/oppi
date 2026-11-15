# Plugin screens

A built-in plugin can add a sidebar entry whose pages are list screens the app draws generically. Spike scope: built-in plugins only, the server-wide scope only, behind the app's Plugin Sidebar experiment.

## Owners

- `server/src/plugin-screens.ts` (`oppi/v1`): the `Sidebar` registry, `defineScreen` (a `local` Chord object per `{ scope, page }` with a `page` document and an `act` method), and `checkScreenPage`, the one vocabulary and budget check (64 KB a page, 200 rows a section, page ids three segments deep).
- `PluginHost` composes `Sidebar` in its core facet: only built-ins' entries, by `order`; an owner plugin's entry is a reported conflict.
- `server/src/screens-stream.ts` owns `WS /screens/stream`: one watch per page, the first value whole, then `diffRevisions` ops against the last value sent. A refused value is `failed` and never repaired.
- `/server/info` lists `sidebar` and `capabilities.screens.v` (`routes/identity.ts`). It lists the loaded entries and never waits: its first request starts the plugins' load (`loadedScreens`); the stream loads them on demand.
- An entry's `feature` names its server switch (`server-features.ts`): `/server/info` leaves it out while off, a watch ends `off`, and `ScreensStreamMux.featuresChanged` ends open watches when a save turns it off.
- `oppiHost().mcp()` is the MCP management port; the slot is `mcp-service.ts`'s, set by the newest `McpService`.
- Apple: `PluginScreenStream` (one socket per connection while a page watches), `PluginScreenReplica` (`ChordDelta` over the page), and `PluginScreenViewController` on `ListScreenController`.

## Invariants

- Swift draws from protocol data only. `scripts/plugin-screen-guard.ts` (in the iOS architecture check) fails a `PluginScreen*` file that names an entry from `protocol/screens.json`.
- One integer versions the whole vocabulary. A new row kind needs two real screens and a fixture; an unknown kind draws as an update notice.
- Pages are projections: nothing is persisted, and a watch has no cursor. A reconnect watches again; an `act` without a result fails and is never resent.
- A page's document starts as a loading page until the plugin's first write.
- A plugin's sidebar facet still contributes an extension (the plugin host requires one), which sessions select.

## Tests

- Server: `screens-stream.test.ts` (registry, `/server/info` while loading and with a feature off, watch, act, budget, watch limit, a switch ending watches), `mcp-screen.test.ts` (the MCP plugin over a fake port), `screens-fixtures.test.ts`.
- Apple: `PluginScreenProtocolTests`, `PluginScreenViewControllerTests`.
- E2E: `PluginScreenE2ETests` against a native server (`e2e.sh --native`).
