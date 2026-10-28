# auto-name

A Pi extension that names an unnamed session from its first message. A small model writes a 2–6 word title (`Fix WebSocket Reconnect Drift`) and the extension calls Pi's `setSessionName()`, so the name shows in Oppi's session list and header, and in terminal Pi's session picker.

- **When:** on the first user message of a session that has no name. A session that already has a name, set by you, Oppi, or another extension, is never renamed, including when a name arrives while the title is generating. A resumed session that already has messages is left as it is. A first message under 15 characters gets no title.
- **Where:** terminal Pi, Oppi sessions, and Oppi durable sessions (`durable.ts`; durable sessions need `experimental.serverDurable`).
- **Quiet:** the title never holds the turn. If no title can be made (the model is missing or unauthenticated, the request times out after 15 seconds, the reply is not a title), the session stays unnamed and the reason is logged once: to stderr, or as one muted notice in terminal Pi.

## Turn it on

Link the package where Pi discovers extensions, and Pi loads it for every session:

```bash
ln -sfn "$PWD/pi-extensions/auto-name" ~/.pi/agent/extensions/auto-name
```

Oppi's npm package carries the same package under `extensions/pi/auto-name/`, and `oppi serve` links it for you when you upgrade from the old built-in Auto-Name with it turned on ([migration](../../docs/extensions.md#auto-name)). Turn it off, globally or for one workspace, with the extension's toggle in Oppi's **Server Settings → Extensions** or a workspace's **Extensions** list, or with `pi config`. Durable sessions follow the global setting.

## Choose the model

`~/.pi/agent/auto-name.json`:

```json
{ "model": "anthropic/claude-haiku-4-5" }
```

`model` is `provider/model-id`, read at each title so an edit applies to the next session. Without the file, the extension uses the cheapest small model (an id containing `haiku`, `flash`, `mini`, `nano`, `lite`, or `small`; non-reasoning first) of the session's own provider, and the session's own model when that provider has none. A configured model that is not available logs once and names nothing; the extension does not fall back to a model you did not name.

## The title contract

`core.ts` holds the model instructions, the first-message prompt, and `normalizeTitle()`. `session-title.json` pins all three; `server/tests/auto-name-extension.test.ts` checks `core.ts` against it. Change both together.
