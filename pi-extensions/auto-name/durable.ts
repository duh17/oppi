import {
  AgentDoc,
  defineExtension,
  GenerationTask,
  hook,
} from "@earendil-works/pi-durable";
import { oppiHost } from "oppi/durable";
import { autoName, userText } from "./core.js";

// Durable port of `index.ts`. A hook on the generation task sees the conversation's first request,
// starts the title without awaiting it (the request must not wait for a title), and names the
// Oppi Session through the host once it is ready.

/** Conversations this process already tried; a recovered request reruns its hook. */
const tried = new Set<string>();
let warned = false;

export default defineExtension({
  name: "auto-name",
  hooks: [
    hook(GenerationTask, {
      async beforeRequest(request, api, context) {
        // The first request of a conversation: one user message, no reply yet.
        const users = request.messages.filter(
          (message) => message.role === "user",
        );
        if (
          users.length !== 1 ||
          request.messages.some((message) => message.role === "assistant")
        )
          return;
        const naming = await oppiHost().sessionName(api, context);
        if (!naming || naming.get() || tried.has(naming.sessionId)) return;
        tried.add(naming.sessionId);

        const model = (
          await api.snapshot(AgentDoc, api.conversationId, context)
        )?.model;
        const models = api.models;
        void autoName({
          firstMessage: userText(users[0]?.content),
          session: model
            ? { provider: model.provider, id: model.modelId }
            : undefined,
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
