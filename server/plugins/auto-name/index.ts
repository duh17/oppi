import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

import { autoName } from "./core.js";

/**
 * Names an unnamed session from its first message with a small model. Turn it on and off with
 * Pi's extension toggle; `~/.pi/agent/auto-name.json` picks the model.
 */
export default function autoNameExtension(pi: ExtensionAPI): void {
  let closed = false;
  let warned = false;

  // The terminal owns stderr, so a TUI gets one muted notice; other modes log to stderr.
  const warnOnce = (ctx: ExtensionContext, problem: string): void => {
    if (warned || closed) return;
    warned = true;
    try {
      if (ctx.mode === "tui") ctx.ui.notify(`Auto-name: ${problem}`, "warning");
      else process.stderr.write(`[auto-name] no session title: ${problem}\n`);
    } catch {
      // The session this ran for is gone.
    }
  };

  pi.on("session_start", () => {
    closed = false;
    warned = false;
  });
  pi.on("session_shutdown", () => {
    closed = true;
  });

  pi.on("before_agent_start", (event, ctx) => {
    if (event.messageType !== "user" || pi.getSessionName()) return;
    // Only a session's first message names it: a resumed session that already talked stays as it is.
    const talked = ctx.sessionManager
      .getBranch()
      .some((entry) => entry.type === "message" && entry.message.role === "user");
    if (talked) return;

    const registry = ctx.modelRegistry;
    // Not awaited: the title must not hold the turn.
    void autoName({
      firstMessage: event.prompt,
      session: ctx.model ? { provider: ctx.model.provider, id: ctx.model.id } : undefined,
      models: {
        find: (provider, id) => registry.find(provider, id),
        available: () => registry.getAvailable(),
        complete: (model, context, options) =>
          registry.streamSimple(model, context, options).result(),
      },
      currentName: () => pi.getSessionName(),
      setName: (title) => {
        if (!closed) pi.setSessionName(title);
      },
      warn: (problem) => warnOnce(ctx, problem),
    });
  });
}
