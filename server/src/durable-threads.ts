import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { ModelRegistry, SettingsManager, getAgentDir } from "@earendil-works/pi-coding-agent";
import { AgentDoc, type ConversationId, type Harness } from "@earendil-works/pi-durable";
import { homedir } from "node:os";
import type { DurableSessionsHost } from "../extensions/durable/sessions/durable.js";
import { DurableRuntime, type DurableHarness } from "./durable-harness.js";
import { DURABLE_MCP_EXTENSION_PREFIX } from "./durable-mcp.js";
import { DURABLE_THREAD_KEY_PREFIX } from "./reserved-launch-keys.js";
import { mintSessionId } from "./id.js";
import { resolveSessionSeedModel } from "./sdk-backend.js";
import type { Storage } from "./storage.js";
import { isThinkingLevel, type ThinkingLevel } from "./thinking-levels.js";
import type { Session, Workspace } from "./types.js";

export interface DurableThreadsDeps {
  owner: DurableHarness;
  storage: Pick<
    Storage,
    | "findSessionByLaunchIdempotencyKey"
    | "getSession"
    | "getWorkspace"
    | "listSessions"
    | "saveSession"
  >;
  startSession(sessionId: string, workspace?: Workspace): Promise<Session>;
  isActive(sessionId: string): boolean;
  /** A Session row exists for a new child; clients learn about it. */
  onCreated(session: Session): void;
}

/**
 * Oppi's side of durable threads. Ownership lives in the Harness: a child conversation is
 * owned by a task of its parent's conversation, and that edge is the only record of who
 * spawned whom. This class gives each owned child its Oppi Session, bound by conversation
 * id, and reads the thread tree back from the ownership edges.
 */
export class DurableThreads implements DurableSessionsHost {
  /** Concurrent materializations of one child (tool rerun, reporter) share one result. */
  private readonly materializing = new Map<ConversationId, Promise<string>>();

  constructor(private readonly deps: DurableThreadsDeps) {}

  conversationOf(sessionId: string): ConversationId | undefined {
    return this.deps.storage.getSession(sessionId)?.serverDurable?.conversationId as
      ConversationId | undefined;
  }

  private sessionOf(conversationId: ConversationId): Session | undefined {
    return this.deps.storage
      .listSessions()
      .find((session) => session.serverDurable?.conversationId === conversationId);
  }

  async refuseReach(caller: ConversationId, target: ConversationId): Promise<string | undefined> {
    const { harness } = await this.deps.owner.open();
    const from = await harness.snapshot(DurableRuntime, caller, BACKGROUND_CONTEXT);
    if (from?.kind !== "sandbox") return undefined;
    const to = await harness.snapshot(DurableRuntime, target, BACKGROUND_CONTEXT);
    if (to?.kind === "sandbox" && to.workspaceId === from.workspaceId) return undefined;
    return "A sandbox session can only reach sessions in its own sandbox workspace.";
  }

  async activate(sessionId: string): Promise<void> {
    if (this.deps.isActive(sessionId)) return;
    const session = this.deps.storage.getSession(sessionId);
    if (!session) throw new Error(`Session not found: ${sessionId}`);
    const workspace = session.workspaceId
      ? this.deps.storage.getWorkspace(session.workspaceId)
      : undefined;
    await this.deps.startSession(sessionId, workspace);
  }

  async resolveAgent(options: {
    model?: string;
    thinking?: string;
  }): ReturnType<DurableSessionsHost["resolveAgent"]> {
    if (options.thinking !== undefined && !isThinkingLevel(options.thinking))
      throw new Error(`Unknown thinking level: ${options.thinking}`);
    const thinkingLevel = options.thinking as ThinkingLevel | undefined;
    if (options.model === undefined) return { ...(thinkingLevel ? { thinkingLevel } : {}) };
    const { models } = await this.deps.owner.open();
    const settings = SettingsManager.create(homedir(), getAgentDir(), { projectTrusted: false });
    const found = resolveSessionSeedModel(
      new ModelRegistry(models),
      options.model,
      settings.getEnabledModels(),
    );
    if (!found) throw new Error(`Model is unavailable: ${options.model}`);
    return {
      model: { provider: found.provider, modelId: found.id },
      ...(thinkingLevel ? { thinkingLevel } : {}),
    };
  }

  materialize(child: { conversationId: ConversationId; name: string }): Promise<string> {
    const pending = this.materializing.get(child.conversationId);
    if (pending) return pending;
    const created = this.materializeOnce(child).finally(() =>
      this.materializing.delete(child.conversationId),
    );
    this.materializing.set(child.conversationId, created);
    return created;
  }

  private async materializeOnce(child: {
    conversationId: ConversationId;
    name: string;
  }): Promise<string> {
    const key = `${DURABLE_THREAD_KEY_PREFIX}${child.conversationId}`;
    let session = this.deps.storage.findSessionByLaunchIdempotencyKey(key);
    // Only a row bound to this very conversation is ours to adopt (a crash between saving it
    // and attaching it). Clients cannot create keys in this namespace, so anything else is
    // corruption: fail the spawn rather than run the child in someone else's Session slot.
    if (session && session.serverDurable?.conversationId !== child.conversationId)
      throw new Error(
        `Session ${session.id} holds the key of child conversation ${child.conversationId} but is not bound to the child conversation`,
      );
    if (!session) {
      session = await this.createSession(child.conversationId, child.name, key);
      this.deps.onCreated(session);
    }
    // A Session that exists but is not attached (a crash between the two steps, or a Stop)
    // is attached again here, so a restart finds it live and keeps its conversation.
    await this.activate(session.id);
    return session.id;
  }

  private async createSession(
    conversationId: ConversationId,
    name: string,
    key: string,
  ): Promise<Session> {
    const { harness } = await this.deps.owner.open();
    const record = await harness.commit(
      (tx) => tx.conversation(conversationId),
      BACKGROUND_CONTEXT,
    );
    const ownerConversation = record?.owner?.conversationId;
    if (ownerConversation === undefined)
      throw new Error(`Durable conversation ${conversationId} is not owned by a parent`);
    const parent = this.sessionOf(ownerConversation);
    const workspace = parent?.workspaceId
      ? this.deps.storage.getWorkspace(parent.workspaceId)
      : undefined;
    if (!parent || !parent.workspaceId || !workspace)
      throw new Error("Only a workspace session can spawn child sessions");
    const conversation = await harness.conversation(conversationId, BACKGROUND_CONTEXT);
    if (!conversation) throw new Error(`Durable conversation ${conversationId} is missing`);
    // The child runs where its parent runs. The Harness copies the parent's agent into an
    // owned conversation, but not the runtime boundary, and the copied selection names the
    // parent's MCP extension, which the child attaches its own of.
    await conversation.commit(async (tx) => {
      const parentRuntime = await tx.doc(DurableRuntime, ownerConversation);
      const runtime = await tx.doc(DurableRuntime, conversationId);
      runtime.kind = parentRuntime.kind;
      if (parentRuntime.workspaceId !== undefined) runtime.workspaceId = parentRuntime.workspaceId;
      const agent = await tx.doc(AgentDoc, conversationId);
      const own = (extension: string): boolean =>
        !extension.startsWith(DURABLE_MCP_EXTENSION_PREFIX);
      if (Array.isArray(agent.extensions)) agent.extensions = agent.extensions.filter(own);
      else if (agent.extensions?.add) agent.extensions.add = agent.extensions.add.filter(own);
    }, BACKGROUND_CONTEXT);
    const agent = await conversation.agent(BACKGROUND_CONTEXT);
    const model = agent.model ? `${agent.model.provider}/${agent.model.modelId}` : parent.model;
    const now = Date.now();
    const session: Session = {
      id: mintSessionId(),
      name,
      status: "ready",
      createdAt: now,
      lastActivity: now,
      ...(model ? { model } : {}),
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
      runtime: "oppi",
      workspaceId: parent.workspaceId,
      ...(parent.workspaceName ? { workspaceName: parent.workspaceName } : {}),
      ...(parent.worktreeId ? { worktreeId: parent.worktreeId } : {}),
      thinkingLevel: agent.thinkingLevel,
      // Bound before anything is submitted, so a restart finds the conversation in `resumeIds`.
      serverDurable: { conversationId },
      launch: {
        source: "agent",
        ...(parent.launch?.agentId ? { agentId: parent.launch.agentId } : {}),
        ...(parent.launch?.agentVersion !== undefined
          ? { agentVersion: parent.launch.agentVersion }
          : {}),
        // Write-once copy of the ownership edge; the Harness stays the source of truth.
        parentSessionId: parent.id,
        idempotencyKey: key,
        target: {
          workspaceId: parent.workspaceId,
          ...(parent.worktreeId ? { worktreeId: parent.worktreeId } : {}),
          runtime: workspace.runtime === "sandbox" ? "sandbox" : "host",
        },
        ...(model ? { model } : {}),
        thinkingLevel: agent.thinkingLevel,
        ...(parent.launch?.tools ? { tools: parent.launch.tools } : {}),
        status: "accepted",
        promptDispatch: "delivered",
        requestedAt: now,
        completedAt: now,
      },
    };
    this.deps.storage.saveSession(session);
    return session;
  }

  /**
   * The Sessions of the thread containing `sessionId`: the topmost owner and every
   * conversation it owns, transitively, read from the Harness ownership edges.
   */
  async threadSessions(
    sessionId: string,
  ): Promise<{ rootSessionId: string; sessionIds: Set<string> } | undefined> {
    const conversationId = this.conversationOf(sessionId);
    if (conversationId === undefined) return undefined;
    const { harness } = await this.deps.owner.open();
    const { chain, members } = await readThread(harness, conversationId);
    const byConversation = new Map(
      this.deps.storage
        .listSessions()
        .flatMap((session) =>
          session.serverDurable?.conversationId === undefined
            ? []
            : [[session.serverDurable.conversationId as ConversationId, session.id] as const],
        ),
    );
    // The harness root may have lost its Session (deleted). The thread then roots at the
    // nearest remaining ancestor: the topmost conversation above `sessionId` that has one.
    const rootConversation = chain.filter((id) => byConversation.has(id)).at(-1);
    const rootSessionId = rootConversation && byConversation.get(rootConversation);
    if (rootSessionId === undefined) return undefined;
    const sessionIds = new Set<string>();
    for (const member of members) {
      const id = byConversation.get(member);
      if (id !== undefined) sessionIds.add(id);
    }
    return { rootSessionId, sessionIds };
  }
}

/**
 * Walk owner edges up to the root, then down through `ownerConversationId`, in one read.
 * `chain` is the path from `id` up to the root, nearest first.
 */
function readThread(
  harness: Harness,
  id: ConversationId,
): Promise<{ chain: ConversationId[]; members: ConversationId[] }> {
  return harness.commit(async (tx) => {
    const chain: ConversationId[] = [id];
    const seen = new Set<ConversationId>(chain);
    let root = id;
    for (;;) {
      const parent = (await tx.conversation(root))?.owner?.conversationId;
      if (parent === undefined || seen.has(parent)) break;
      seen.add(parent);
      chain.push(parent);
      root = parent;
    }
    const members: ConversationId[] = [root];
    const known = new Set<ConversationId>(members);
    // Array iteration also visits children pushed during the walk.
    for (const member of members) {
      let cursor;
      do {
        const page = await tx.scanConversations({ ownerConversationId: member }, 100, cursor);
        for (const child of page.items)
          if (!known.has(child.id)) {
            known.add(child.id);
            members.push(child.id);
          }
        cursor = page.next;
      } while (cursor);
    }
    return { chain, members };
  }, BACKGROUND_CONTEXT);
}
