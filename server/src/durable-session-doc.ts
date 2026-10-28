import { defineDoc } from "@earendil-works/pi-durable";

/**
 * The Oppi Session a conversation belongs to. Hooks and tasks of a durable extension know their
 * conversation id, which is only unique within its store; this is how they reach the Session
 * (`oppiSessionId` in `oppi/durable`). Written when the server binds the conversation.
 */
export const DurableSessionDoc = defineDoc<{ sessionId?: string }>({
  kind: "oppi.session",
  version: 1,
  scope: "conversation",
  history: "latest",
  // A fork is another Session: it writes its own id when it binds.
  fork: "initial",
  initial: () => ({}),
  // Written when the conversation binds; a Session id never changes.
  checkpointWhen: () => false,
});
