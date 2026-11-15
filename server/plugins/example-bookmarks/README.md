# example-bookmarks

An example Oppi plugin that ships with the server, turned off. It shows a plugin with its own state:

- two tools, `example_bookmark_add` and `example_bookmark_list`;
- a pi-durable document (`defineDoc`) that holds the links, written in `api.commit` and read with `api.snapshot`;
- state that survives a server restart with no saving code of its own.

The links belong to one chat. A second chat starts with an empty list (see `scope: "session"` in [server.ts](server.ts)).

## Turn it on

Plugins run only in durable sessions, so turn on **Server Settings → Durable Sessions** first (or `oppi config set experimental.serverDurable true` and restart the server). Then:

```bash
oppi extensions enable example-bookmarks
```

Or turn it on in **Server Settings → Extensions**. New sessions get the tools at once; an open session gets them the next time it attaches. `oppi extensions disable example-bookmarks` turns it off again.

Start a durable session (in Quick Session, tap the **Classic** pill to make it **∞ Durable**; or `oppi session create --engine durable`) and ask it to "bookmark https://example.com as Example, then list my bookmarks".

## Copy it

To start your own plugin from this one, copy the folder to `~/.pi/agent/plugins/<your-name>/` and rename the package, the extension, its tools, and the document's `kind`. A built-in keeps its names even while it is off, so a copy that keeps them fails to load. See [Plugins](../../../docs/extensions.md#plugins).
