# auto-name

A Pi extension that names an unnamed session from its first message. A small model writes a 2–6 word title (`Fix WebSocket Reconnect Drift`) and the extension calls Pi's `setSessionName()`, so the name shows in Oppi's session list and header, and in terminal Pi's session picker.

- **When:** on the first user message of a session that has no name. A session that already has a name, set by you, Oppi, or another extension, is never renamed, including when a name arrives while the title is generating. A resumed session that already has messages is left as it is. A first message under 15 characters gets no title.
- **Where:** terminal Pi, Oppi sessions, and Oppi durable sessions (the plugin `server.ts`; durable sessions need `experimental.serverDurable`).
- **Quiet:** the title never holds the turn. If no title can be made (the model is missing or unauthenticated, the request times out after 15 seconds, the reply is not a title), the session stays unnamed and the reason is logged once: to stderr, or as one muted notice in terminal Pi.

## Turn it on

In Oppi, the first `oppi serve` lists the package as an off extension: turn **Auto-Name** on in **Server Settings → Extensions** (every session, durable ones included) or in a workspace's **Extensions** list (that workspace's classic sessions). A server that had the old built-in Auto-Name on keeps it on ([upgrade](../../docs/extensions.md#auto-name)).

In terminal Pi, or from a checkout, link the package where Pi discovers extensions, and Pi loads it for every session; `pi config` turns it off:

```bash
ln -sfn "$PWD/server/plugins/auto-name" ~/.pi/agent/extensions/auto-name
```

## Choose the model

`~/.pi/agent/auto-name.json`:

```json
{ "model": "anthropic/claude-haiku-5-5" }
```

`model` is `provider/model-id`, read at each title so an edit applies to the next session. Without the file, the extension uses the cheapest small model of the session's provider (an id with `haiku`, `flash`, `mini`, `nano`, `lite`, or `small` as a whole part, non-reasoning first; on OpenRouter only the session model's own vendor, never a `:batch` variant), and the session's own model when that provider has none. OpenAI Codex models cannot answer a plain completion: a Codex session names nothing by default and logs once that you should set this file. A configured model that is not available logs once and names nothing; the extension does not fall back to a model you did not name.

## The title contract

`core.ts` holds the model instructions, the first-message prompt, and `normalizeTitle()`. `session-title.json` pins all three; `server/tests/auto-name-extension.test.ts` checks `core.ts` against it. Change both together.
