# Godot (experiment)

Oppi can play a Godot game in a **Godot pane** beside the chat. You or an agent change the game in a workspace and export it; the server finds the new export and sends it to the pane, which reloads by itself. The loop is talking to the agent next to the running game.

**Status:** experiment. This page covers the server: discovery, releases, the player link, agent tools, and publishing from other machines. It also covers how the pane hands a game to the chat. A server that serves games says so in `GET /server/info` with `capabilities.godot: { "version": 1 }`.

The server stores, checks, and announces game builds. It never runs Godot or the game, and it never builds a game for you: whatever exports the pack (an agent, the Godot editor, a Makefile, CI) only has to write it where Oppi looks.

## Put a game in a workspace

A game is any folder with Godot's `project.godot` inside one of a workspace's checkouts: the workspace folder or one of its worktrees.

- The server looks at most six folders deep. It skips hidden folders (`.godot`, `.git`), links, and dependency and build output (`node_modules`, `Pods`, `Library`, `DerivedData`, `target`, `dist`, `build`, `vendor`, `venv`), and it does not look inside a project folder for more projects. A workspace whose folder is the home folder itself is not searched.
- The game's name is `config/name` from `project.godot`, unless `oppi-godot.json` sets one.
- Each game has an id like `tide-3fa9c2b1`: the folder name and a short hash of the workspace, the checkout, and the folder. The same project in two worktrees is two games, each with its own builds.

The server looks for new projects every five minutes. Listing games (the Godot pane, `godot_status`) also starts a look when the last one is over 30 seconds old, so a new project shows up in the list after that.

## Export, and the pane reloads

From the project folder, export a pack into `build/`:

```bash
mkdir -p build
godot --headless --path . --export-pack "iOS" build/tide.pck
```

Godot does not create `build/` itself. The preset name (`"iOS"` here) is one from the project's `export_presets.cfg`. Give that preset `exclude_filter="build/*"`, so a pack never carries the packs exported before it.

The server watches the project's `build/` folder and plays its newest `.pck`. When the file changes:

1. It waits until the file has not changed for half a second, because Godot writes the pack in place for up to a second before it exits.
2. It checks that the file starts with Godot's `GDPC` header (a ZIP pack is accepted too), then copies it and computes its SHA-256.
3. Bytes it has not seen become a new **release**, which goes to every Godot pane showing the game. The same bytes saved again make no release.

A file that is not a pack makes no release; the game's log says why. The server keeps a game's five newest releases and deletes packs no kept release uses.

### `oppi-godot.json`

An optional `oppi-godot.json` next to `project.godot` changes the defaults. Every field is optional.

```json
{
  "name": "Tide",
  "pack": "build/tide.pck",
  "entry": { "scene": "res://levels/level_2.tscn", "args": ["--level=2"] },
  "reload": "scene"
}
```

| Field | Meaning |
| --- | --- |
| `name` | The name the pane and the tools show. |
| `pack` | The pack to play instead of the newest `build/*.pck`, relative to the project folder. It must stay inside the checkout, also after links are followed; a path that leaves it is ignored, and the newest `build/*.pck` plays instead. It may be a `.pck` or a `.zip`. |
| `entry` | The scene to start and extra engine arguments. Without it, the project's main scene starts. |
| `reload` | The reload hint for releases from this folder: `scripts`, `scene` (the default), or `restart`. See below. |

A field with the wrong type is ignored, and the game's log says why. The file itself must not be a link.

### How a release reloads

The device chooses how to apply a new release from what changed; the release's `reload` value is a hint, and only `restart` always wins. When `project.godot` (project settings and autoloads) changed since the last export, the server marks the release `restart`; otherwise the hint is `oppi-godot.json`'s `reload`, or `scene`. The player reports the way it used.

| Way | When | What is kept |
| --- | --- | --- |
| `scripts` | Only existing scripts changed. | Everything: the game keeps running with the new code. New `_ready` code does not run again. |
| `scene` | Scenes or resources changed. | Autoloads. The current scene starts over. |
| `restart` | Project settings or autoloads changed. | Nothing. The pane ends the game's engine and starts it again on the new release. |

The app plays one game at a time. Opening a pane on another game ends the one playing and starts the new one there; the first game's pane offers **Play** to switch back, which starts that game from the beginning.

## Hand a game to the chat

The pane can put what you see into the chat's composer as a draft. Add your words, then send it. The pane never sends it for you.

- **Ask Agent** shows on the card of an error the game raised. The draft holds the game's name and release, the error with its file, line and backtrace, and the game's last five other errors. The current frame is attached as an image.
- **More › Send Frame to Chat** in the pane's bar attaches the current frame, with the game's name and release. It shows while the game plays in that pane.

The draft goes to the chat beside the game: on iPad, the chat in the window's main pane. On iPhone, and when no pane fits beside the chat, it goes to the chat you opened the game from, and Oppi goes back to that chat, which closes the game's pane. When no chat can take the draft, neither control shows.

## For agents

A durable session has five tools for the game in the pane while its workspace has a game; a session in a workspace without one does not get them or their guideline. When a workspace gets its first game during a session, the tools appear the next time that session is opened. The tools reach only the games in the session's own workspace: a game of another workspace, or one only a publish created, is not found. Each takes an optional `project`, a game's id or name. Without it, the tools use the one game of the workspace a pane is playing, else the only game in the session's checkout, else the only one in the workspace; when they cannot tell, they list the workspace's games.

| Tool | Use |
| --- | --- |
| `godot_status` | The current release, the devices playing it with their state (`running`, `paused`, `error`) and frame rate, and the latest errors. Without a game to choose, it lists the workspace's games. |
| `godot_logs` | The game's log as the device reports it. Errors carry file, line, function, and a backtrace. Pass `since` (the `next` of the last read) to read only new lines, and `level: "error"` for errors only. |
| `godot_capture` | A screenshot of the game on the device, returned as an image you can see. It also shows in the tool row. |
| `godot_input` | Taps, drags, keys, and input actions, run in order. Points are fractions of the game view from its top-left: `{ "x": 0.5, "y": 0.5 }` is the middle. Set `capture: true` to see the screen after the last step. |
| `godot_reload` | Applies the current release again. Exports reload by themselves; use this after a failed reload, or with `tier: "scene"` to restart the scene. |

A good loop:

1. Change the project, then export it with `mkdir -p build && godot --headless --path . --export-pack`. Do not ask the owner to reload.
2. Call `godot_status` to see that the new release is running, and `godot_logs` with `level: "error"` for errors.
3. Fix the file and line an error names, then export again.
4. Use `godot_input` and `godot_capture` to try the change and look at the result.

`godot_input` steps:

```json
[
  { "kind": "tap", "at": { "x": 0.5, "y": 0.82 }, "holdMs": 80 },
  { "kind": "wait", "ms": 300 },
  { "kind": "drag", "from": { "x": 0.2, "y": 0.5 }, "to": { "x": 0.8, "y": 0.5 }, "durationMs": 400 },
  { "kind": "key", "key": "Space", "holdMs": 120 },
  { "kind": "action", "action": "jump", "holdMs": 200 }
]
```

`key` is a key name such as `Space`, `Enter`, `Escape`, `Left`, `A`, or `F1`. `action` is an input action the project defines in its input map. `godot_capture`, `godot_input`, and `godot_reload` fail with `no_player` when no Godot pane has the game open; `godot_status` then says there is no player.

## Publish from another machine

A pipeline that cannot write into a workspace, such as CI, can publish over HTTP with the owner token or a paired device's token. Upload each pack under its SHA-256, then publish a release that lists them, base first:

```bash
SHA=$(shasum -a 256 tide.pck | cut -d' ' -f1)
curl -X PUT --data-binary @tide.pck -H "Authorization: Bearer $TOKEN" \
  "$SERVER/godot/tide-ci/packs/$SHA"
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"v\":1,\"engine\":{\"name\":\"godot\",\"version\":\"4.7\"},\"packs\":[{\"sha256\":\"$SHA\"}],\"label\":\"nightly\"}" \
  "$SERVER/godot/tide-ci/releases?wait=first-frame"
```

- A project id that no workspace has creates a published game; use `name` in the release to name it. Ids are 1 to 64 letters, digits, `.`, `_`, or `-`, starting with a letter or digit.
- `HEAD .../packs/<sha256>` tells you whether the server has a pack already; uploading the same pack again does not store it twice.
- Later packs replace files in earlier ones, so a release can list a base pack and patches made with `--export-patch`.
- `?wait=first-frame` holds the answer up to 30 seconds for the first device that runs or fails the release, and returns its state as `applied`.

## Reference

Every route needs the owner token or a paired device's token; nothing is public.

| Route | Purpose |
| --- | --- |
| `GET /godot[?workspace=<id>]` | Games: discovered ones, then published ones, each with its current release (`null` for no build yet) and its players. |
| `GET /godot/{projectId}` | One game with its kept releases and `logNext`. |
| `HEAD`, `GET /godot/{projectId}/packs/{sha256}` | Pack bytes. The `ETag` is the SHA-256, and `If-None-Match` answers 304. One byte range; with `If-Range`, only when it matches the `ETag`. |
| `PUT /godot/{projectId}/packs/{sha256}` | Upload a pack. The bytes must hash to the name and start with `GDPC` or a ZIP header. |
| `POST /godot/{projectId}/releases[?wait=first-frame]` | Publish a release of uploaded packs. |
| `POST /godot/{projectId}/commands` | Send one command to one player and wait for its answer: `{ "command": { "name": "capture" } }`, with optional `player` and `timeoutMs`. |
| `GET /godot/{projectId}/logs?since=&limit=&level=` | The game's log, from the newest 2,000 entries. |
| `PUT`, `GET /godot/{projectId}/captures/{captureId}` | A player uploads a PNG or JPEG capture; controllers read it. |
| `WS /godot/{projectId}/link?role=player` or `?role=follower` | The live link. A player (the app's Godot pane) must first send `attach` naming `godot-pane:v1`; it then gets releases and commands and sends state, logs, and answers. A follower gets releases, players, and log lines. Either renews its access with `auth_renew`, as every device stream does; a link that does not closes when the token it opened with expires. |

Commands are `reload`, `run`, `stop`, `pause`, `resume`, `step`, `capture`, `input`, `pick`, `tree`, `node`, and `perf`. A command that fails answers with `ok: false` and an error code: `no_player`, `timeout`, `player_left`, `unsupported`, `failed`, `invalid`, or `not_found`. Every body and message has an example in [`protocol/godot.json`](https://github.com/duh17/oppi/blob/main/protocol/godot.json); the types are in [`server/src/types/godot.ts`](https://github.com/duh17/oppi/blob/main/server/src/types/godot.ts).

| Limit | Value |
| --- | --- |
| Releases kept per game | 5 |
| Log entries kept per game | 2,000 |
| Pack upload | 512 MB |
| Capture upload | 20 MB; the newest 20 per game are kept |
| Command answer | 5 to 30 seconds by command, plus the time `input` steps take; at most 120 seconds |
| `wait=first-frame` | 30 seconds |

## Safety

- The server checks a pack's hash, size, and header only. It never opens, runs, or builds a game.
- Only the owner and paired devices can publish, play, or read a game, its logs, and its captures.
- Discovery never follows a link out of a checkout, and a pack an `oppi-godot.json` names must stay inside the checkout.
