# example-shelf

An example Oppi plugin that ships with the server, turned off. It shows a panel of tiles:

- a pill above the composer, **Shelf · N**, that opens a panel pane;
- a `tiles` node per group: the files the chat wrote or changed (pictures, PDFs, and documents first), the subagents it started, and the Godot game of its workspace;
- tiles drawn as the Pinned screen draws pins, each opening its `oppi://` link: a file or game beside the chat on an iPad, full screen on an iPhone;
- no tool and no state of its own: `oppiHost().sessionActivity` and `oppiHost().godot` read what the server already knows, and a `GenerationTask` hook draws the shelf again after each round of tool calls, publishing through `oppiHost().sessionSurfaces`.

## Turn it on

Plugins run only in durable sessions, so turn on **Server Settings → Durable Sessions** first (or `oppi config set experimental.serverDurable true` and restart the server). Then:

```bash
oppi extensions enable example-shelf
```

Or turn it on in **Server Settings → Extensions**. New sessions get the shelf at once; an open session gets it the next time it attaches. `oppi extensions disable example-shelf` turns it off again.

Start a durable session and ask it to write a file. After its tool call the pill appears; tap it, then tap a tile.

## What it does not show

The server records the files a session's `edit` and `write` calls name, and nothing else. A picture or PDF the agent makes with `bash` (a script, `sips`, a converter) is not on the shelf, and neither is a file outside the session's folder.

## Copy it

To start your own plugin from this one, copy the folder to `~/.pi/agent/plugins/<your-name>/` and rename the package, the extension, and the surface `id`. A built-in keeps its names even while it is off, so a copy that keeps them fails to load. See [Tiles](../../../docs/extension-native-ui.md#tiles) and [Plugins](../../../docs/extensions.md#plugins).
