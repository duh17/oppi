import { CONTROL_CONVERSATION_LAUNCH_KEY, isControlConversation } from "./control-session.js";
import { mintSessionId } from "./id.js";
import type { SessionLifecycleService } from "./session-lifecycle-service.js";
import type { Storage } from "./storage.js";
import type { Session } from "./types.js";

export class ControlConversationError extends Error {
  constructor(
    message: string,
    readonly statusCode: number,
  ) {
    super(message);
    this.name = "ControlConversationError";
  }
}

export interface ControlConversationDeps {
  storage: Pick<
    Storage,
    | "deleteSession"
    | "findSessionByLaunchIdempotencyKey"
    | "getConfig"
    | "getSession"
    | "saveSession"
  >;
  lifecycle: Pick<SessionLifecycleService, "resumeControlConversation">;
}

export interface ControlConversationOpenResult {
  /** Attached to a runtime, with `serverDurable.conversationId` bound. */
  session: Session;
  created: boolean;
}

/**
 * Find-or-create of the one durable control conversation of this data directory. The row is
 * created at server start when durable is on; `open()` still attaches it on demand.
 *
 * The Session row is saved under a reserved launch key before anything else, so a crash at
 * any point leaves at most an unbound row that the next call finds and binds. Concurrent
 * first calls in this process queue behind each other: one row, one conversation. The
 * conversation id is stored on the row (`serverDurable.conversationId`), so a server restart
 * resumes the same conversation.
 */
export class ControlConversationService {
  private tail: Promise<unknown> = Promise.resolve();

  constructor(private readonly deps: ControlConversationDeps) {}

  /** `model` and `thinking` apply only when this call creates the row. */
  open(
    options: { model?: string; thinking?: string } = {},
  ): Promise<ControlConversationOpenResult> {
    const result = this.tail.then(() => this.openOnce(options));
    this.tail = result.catch(() => undefined);
    return result;
  }

  private async openOnce(options: {
    model?: string;
    thinking?: string;
  }): Promise<ControlConversationOpenResult> {
    const { storage, lifecycle } = this.deps;
    if (storage.getConfig().experimental?.serverDurable !== true) {
      throw new ControlConversationError(
        "The control conversation is not available on this server; enable experimental.serverDurable",
        409,
      );
    }
    const ensured = ensureControlConversationSession(storage, options);
    const session = ensured.session;
    const created = ensured.created;
    try {
      const started = await lifecycle.resumeControlConversation(session);
      return { session: started.session, created };
    } catch (error) {
      // A row that never bound a conversation would keep a model that failed to start and
      // make every later open fail the same way; a retry creates it afresh instead.
      if (created && storage.getSession(session.id)?.serverDurable?.conversationId === undefined) {
        storage.deleteSession(session.id);
      }
      throw error;
    }
  }
}

/** Create the control-conversation row if this data directory has none. */
export function ensureControlConversationSession(
  storage: Pick<Storage, "findSessionByLaunchIdempotencyKey" | "saveSession">,
  options: { model?: string; thinking?: string } = {},
): { session: Session; created: boolean } {
  const existing = storage.findSessionByLaunchIdempotencyKey(CONTROL_CONVERSATION_LAUNCH_KEY);
  if (existing && !isControlConversation(existing)) {
    throw new ControlConversationError(
      `Session ${existing.id} holds the control conversation launch key but is not the control conversation`,
      409,
    );
  }
  if (existing) return { session: existing, created: false };
  const now = Date.now();
  const id = mintSessionId();
  const session: Session = {
    id,
    name: "Oppi Control",
    status: "ready",
    createdAt: now,
    lastActivity: now,
    ...(options.model ? { model: options.model } : {}),
    ...(options.thinking ? { thinkingLevel: options.thinking } : {}),
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    runtime: "oppi",
    serverDurable: { storeId: id, role: "control" },
    launch: {
      source: "human",
      target: { server: true, displayCwd: "Oppi Control" },
      ...(options.model ? { model: options.model } : {}),
      ...(options.thinking ? { thinkingLevel: options.thinking } : {}),
      idempotencyKey: CONTROL_CONVERSATION_LAUNCH_KEY,
      status: "accepted",
      promptDispatch: "not_sent",
      requestedAt: now,
      completedAt: now,
    },
  };
  storage.saveSession(session);
  return { session, created: true };
}
