# working-words

Oppi built-in plugin: while a durable session works, a background task rotates random working phrases and publishes them as the session's working message through the `oppi.extension-ui` document, cleared while the session is idle. The server ensures one task per attachment.

Oppi renders the message through its generic extension UI projection; it must not branch on this plugin's name.
