# example-board

An example Oppi plugin that ships with the server, turned off. It shows a panel:

- a tool, `example_board_add`, that puts an item on the chat's board;
- a pill above the composer and a drawer that lists the items, built with `surface()` from `oppi/v1`;
- a Done button whose tap saves the change in a pi-durable document (`defineDoc`);
- a panel that comes back after a server restart, drawn again from that document (`load`, and `surfaces` in `defineExtension`).

Each chat has its own board: a tap in one chat never changes another chat's panel.

## Turn it on

Plugins run only in durable sessions, so turn on **Server Settings → Durable Sessions** first (or `oppi config set experimental.serverDurable true` and restart the server). Then:

```bash
oppi extensions enable example-board
```

Or turn it on in **Server Settings → Extensions**. New sessions get the tool at once; an open session gets it the next time it attaches. `oppi extensions disable example-board` turns it off again.

Start a durable session and ask it to "add 'Write the release notes' to the board". The pill appears; tap it, then tap **Done**.

## Copy it

To start your own plugin from this one, copy the folder to `~/.pi/agent/plugins/<your-name>/` and rename the package, the extension, its tool, the surface `id`, and the document's `kind`. A built-in keeps its names even while it is off, so a copy that keeps them fails to load. See [Composable surfaces](../../../docs/extension-native-ui.md#composable-surfaces-version-2) and [Plugins](../../../docs/extensions.md#plugins).
