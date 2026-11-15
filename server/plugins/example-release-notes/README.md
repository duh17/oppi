# example-release-notes

An example Oppi plugin that ships with the server, turned off. It shows a tool that runs a command and returns its output:

- `example_release_notes` reads the top of `CHANGELOG.md` in the session's working directory;
- the command runs through `api.env`, the session's environment, so the plugin works in host and sandbox sessions;
- `api.env.exec()` resolves to the exit code only, and the output arrives through `onOutput`.

## Turn it on

Plugins run only in durable sessions, so turn on **Server Settings → Durable Sessions** first (or `oppi config set experimental.serverDurable true` and restart the server). Then:

```bash
oppi extensions enable example-release-notes
```

Or turn it on in **Server Settings → Extensions**. New sessions get the tool at once; an open session gets it the next time it attaches. `oppi extensions disable example-release-notes` turns it off again.

Start a durable session (in Quick Session, tap the **Classic** pill to make it **∞ Durable**; or `oppi session create --engine durable`) in a workspace with a `CHANGELOG.md`, and ask it for "the latest release notes".

## Copy it

To start your own plugin from this one, copy the folder to `~/.pi/agent/plugins/<your-name>/` and rename the package, the extension, and its tool. A built-in keeps its names even while it is off, so a copy that keeps them fails to load. See [Plugins](../../../docs/extensions.md#plugins).
