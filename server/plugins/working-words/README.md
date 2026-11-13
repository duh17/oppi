# working-words

Oppi built-in plugin: while a durable session works, a background task publishes a working phrase for what the agent is doing (thinking, reading, running a command, and so on) as the session's working message through the `oppi.extension-ui` document, cleared while the session is idle. The phrase is picked per run and activity, and the message is written only when that changes. It carries no elapsed time: Oppi's working row shows the turn's time itself. The server ensures one task per attachment.

Oppi renders the message through its generic extension UI projection; it must not branch on this plugin's name.
