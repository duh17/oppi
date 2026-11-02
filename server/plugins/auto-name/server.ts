import { AgentDoc, GenerationTask, hook } from "@earendil-works/pi-durable";
import { defineExtension, defineFacet, Extensions, oppiHost } from "oppi/v1";
import { autoName, userText } from "./core.js";

// Durable port of `index.ts`. A hook on the generation task sees the conversation's first request,
// starts the title without awaiting it (the request must not wait for a title), and names the
// Oppi Session through the host once it is ready.

/**
 * Sessions this module already tried; a recovered request reruns its hook. A plugin reload starts
 * an empty set, which is safe: the hook asks only on a conversation's first request, skips a
 * Session that has a name, and `autoName` checks the name again before it sets one, so a reload
 * during a title in flight costs at most one more small-model request, never a second rename.
 */
const tried = new Set<string>();
let warned = false;

export const DurableAutoName = defineExtension({
  name: "auto-name",
  runtimes: ["host", "sandbox"],
  hooks: [
    hook(GenerationTask, {
      async beforeRequest(request, api, context) {
        // The first request of a conversation: one user message, no reply yet.
        const users = request.messages.filter((message) => message.role === "user");
        if (users.length !== 1 || request.messages.some((message) => message.role === "assistant"))
          return;
        const naming = await oppiHost().sessionName(api, context);
        if (!naming || naming.get() || tried.has(naming.sessionId)) return;
        tried.add(naming.sessionId);

        const model = (await api.snapshot(AgentDoc, api.conversationId, context))?.model;
        const models = api.models;
        void autoName({
          firstMessage: userText(users[0]?.content),
          session: model ? { provider: model.provider, id: model.modelId } : undefined,
          models: {
            find: (provider, id) => models.getModel(provider, id),
            available: () => models.getAvailable(),
            complete: (selected, prompt, options) =>
              models.completeSimple(selected, prompt, options),
          },
          currentName: () => naming.get(),
          setName: (title) => naming.set(title),
          warn: (problem) => {
            if (warned) return;
            warned = true;
            process.stderr.write(`[auto-name] no session title: ${problem}\n`);
          },
        });
        return;
      },
    }),
  ],
});

/** The plugin facet. An opt-in Pi package, never a built-in: the owner enables it in Pi. */
export default defineFacet((_host, self) => self.contribute(Extensions, DurableAutoName));
