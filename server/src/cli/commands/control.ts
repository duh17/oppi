import { randomUUID } from "node:crypto";

import type { Session } from "../../types.js";
import { createLocalApiCommandContext, handleModelResolvingCliError } from "../command-support.js";
import { resolveThinkingFromFlags } from "../launch-flags.js";
import type { LocalApiConnection } from "../local-api-client.js";
import { attributeManagedSessionMessage } from "../managed-session-message.js";
import { resolveModelFlagForCli } from "../model-resolution.js";
import { codeValue, printDetails, writeHumanLine } from "../output.js";
import { assertNoCommandError, sendSessionInput } from "./session-interactions.js";
import { resolvePromptInput } from "./session.js";

export interface ControlCliCallerContext {
  callerSessionId?: string;
  signal?: AbortSignal;
}

const CONTROL_FLAGS: Record<string, readonly string[]> = {
  open: ["json", "model", "thinking"],
  send: ["json", "model", "thinking"],
};

type ControlConversationResponse = { session: Session };

/** `oppi control open|send`: the data directory's one durable control conversation. */
export async function cmdControl(
  storage: LocalApiConnection,
  action: string | undefined,
  positional: string[],
  flags: Record<string, string>,
  callerContext: ControlCliCallerContext = {},
): Promise<void> {
  const jsonOutput = flags.json === "true";
  const { call, output } = createLocalApiCommandContext(
    storage,
    jsonOutput,
    callerContext.signal,
    callerContext.callerSessionId,
  );

  try {
    const allowed = action ? CONTROL_FLAGS[action] : undefined;
    if (!action || !allowed) throw new Error("Usage: oppi control open|send");
    const unsupported = Object.keys(flags).filter((flag) => !allowed.includes(flag));
    if (unsupported.length > 0) {
      throw new Error(
        `Unsupported flag for 'control ${action}': --${unsupported.sort().join(", --")}`,
      );
    }

    // Validate and read the text first: a bad `send` must not create the conversation.
    const text =
      action === "send"
        ? attributeManagedSessionMessage(
            resolvePromptInput(positional[0], "--text"),
            callerContext.callerSessionId,
          )
        : undefined;
    if (action === "open" && positional.length > 0) {
      throw new Error("Usage: oppi control open [--model <id>] [--thinking <level>] [--json]");
    }
    if (action === "send" && positional.length !== 1) {
      throw new Error("Usage: oppi control send <text|@-> [--json]");
    }

    const resolvedModel = await resolveModelFlagForCli(storage, flags.model);
    const thinking = resolveThinkingFromFlags(flags, resolvedModel?.thinkingLevel);
    const opened = await call<ControlConversationResponse>("/control-conversation", {
      method: "POST",
      body: {
        ...(resolvedModel ? { model: resolvedModel.canonicalId } : {}),
        ...(thinking ? { thinking } : {}),
      },
    });
    const session = opened.session;
    const conversationId = session.serverDurable?.conversationId ?? null;

    if (text === undefined) {
      output(
        {
          session_id: session.id,
          conversation_id: conversationId,
          status: session.status,
        },
        () =>
          printDetails("Control conversation", [
            ["Session", codeValue(session.id)],
            ["Conversation", codeValue(conversationId)],
            ["Status", session.status],
          ]),
      );
      return;
    }

    const turnId = randomUUID();
    const result = await sendSessionInput(session.id, "prompt", text, call, turnId);
    assertNoCommandError(result, true);
    output({ session_id: session.id, conversation_id: conversationId, turn_id: turnId }, () =>
      writeHumanLine(`prompt sent → ${session.id} (turn ${turnId})`),
    );
  } catch (err: unknown) {
    if (callerContext.signal?.aborted) throw err;
    handleModelResolvingCliError(err, jsonOutput);
  }
}
