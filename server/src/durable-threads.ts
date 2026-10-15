import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { ModelRegistry, SettingsManager, getAgentDir } from "@earendil-works/pi-coding-agent";
import {
  configure,
  type Agent,
  type ConversationId,
  type Harness,
  type ModelRef,
} from "@earendil-works/pi-durable";
import type { ExecutionEnv } from "@earendil-works/pi-durable/env";
import { homedir } from "node:os";
import type {
  DurableSessionsHost,
  ResolvedSubagent,
  SubagentRequest,
} from "./durable-extension-api.js";
import { childDelegationGrant } from "./agent-launch-service.js";
import { OppiAgentDoc, resolveDurableAgent, type SavedAgent } from "./durable-agent.js";
import { DurableRuntime, hostOfEnv, type DurableHarness } from "./durable-harness.js";
import { durableStoreId } from "./session-runtime-capabilities.js";
import { DURABLE_THREAD_KEY_PREFIX } from "./reserved-launch-keys.js";
import { mintSessionId } from "./id.js";
import { resolveSessionSeedModel } from "./sdk-backend.js";
import type { Storage } from "./storage.js";
import { isThinkingLevel, type ThinkingLevel } from "./thinking-levels.js";
import type { Session, Workspace } from "./types.js";

export interface DurableThreadsDeps {
  runtime: DurableHarness;
  storage: Pick<
    Storage,
    | "findSessionByDurableConversation"
    | "findSessionByLaunchIdempotencyKey"
    | "getAgentDefinitionStore"
    | "getSession"
    | "getWorkspace"
    | "listDurableStoreConversations"
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
  private readonly materializing = new Map<string, Promise<string>>();

  constructor(private readonly deps: DurableThreadsDeps) {}

  storeIdOfEnv(env?: ExecutionEnv): string {
    return hostOfEnv(env).storeId;
  }

  sessionOf(
    conversationId: ConversationId,
    env?: ExecutionEnv,
  ): { sessionId: string; name?: string } | undefined {
    const session = this.deps.storage.findSessionByDurableConversation(
      hostOfEnv(env).storeId,
      conversationId,
    );
    return session
      ? { sessionId: session.id, ...(session.name ? { name: session.name } : {}) }
      : undefined;
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

  /**
   * `subagent spawn`'s side of the one resolver (`resolveDurableAgent`): the caller's delegation
   * grant and runtime from its documents, the saved Agent and its launch constraints, and the
   * model. The child is configured in its creating commit through `apply`.
   */
  async resolveAgent(
    request: SubagentRequest,
    caller: { conversationId: ConversationId; env?: ExecutionEnv; agent: Agent },
  ): Promise<ResolvedSubagent> {
    const host = hostOfEnv(caller.env);
    const { harness } = await host.open();
    const parentId = caller.conversationId;
    const owned =
      (await harness.commit((tx) => tx.conversation(parentId), BACKGROUND_CONTEXT))?.owner !==
      undefined;
    const parentDoc = await harness.snapshot(OppiAgentDoc, parentId, BACKGROUND_CONTEXT);
    const parentRuntime = await harness.snapshot(DurableRuntime, parentId, BACKGROUND_CONTEXT);
    const runtime = parentRuntime?.kind === "sandbox" ? "sandbox" : "host";
    // A session without the document predates it: top-level ones may spawn, children not.
    const grant = childDelegationGrant(
      {
        maySpawn: parentDoc ? parentDoc.spawn : !owned,
        grant: parentDoc?.grant === true,
        sandbox: runtime === "sandbox",
      },
      request.allowNestedDelegation === true,
    );
    const parent = this.deps.storage.findSessionByDurableConversation(host.storeId, parentId);
    const workspace = parent?.workspaceId
      ? this.deps.storage.getWorkspace(parent.workspaceId)
      : undefined;
    if (!parent || !workspace) throw new Error("Only a workspace session can spawn child sessions");

    let saved: SavedAgent | undefined;
    if (request.agent !== undefined) {
      const found = this.deps.storage.getAgentDefinitionStore().resolveAgent(request.agent);
      if (!found || found.status === "archived")
        throw new Error(`Saved Agent not found: ${request.agent}`);
      saved = { id: found.id, version: found.version, definition: found.definition };
      const constraints = found.definition.launchConstraints;
      const allowed = constraints?.allowedWorkspaceIds;
      if (
        (allowed && !allowed.includes(workspace.id)) ||
        (constraints?.requiredRuntime && constraints.requiredRuntime !== runtime)
      )
        throw new Error(
          `Agent ${found.name} cannot run in this ${runtime} workspace (${workspace.name}): it ` +
            `requires ${[
              constraints?.requiredRuntime ? `a ${constraints.requiredRuntime} workspace` : "",
              allowed ? `one of the workspaces ${allowed.join(", ")}` : "",
            ]
              .filter(Boolean)
              .join(" and ")}. Start it as a top-level session instead: ` +
            `oppi session create --agent ${found.id} --workspace <id> --prompt <task>.`,
        );
    }
    const choice = await this.modelChoice(
      request.model ?? saved?.definition.sessionDefaults?.model,
      request.thinking,
    );
    const { change, doc } = resolveDurableAgent({
      ...(saved ? { saved } : {}),
      ...choice,
      ...(parentDoc ? { inherited: parentDoc } : {}),
      runtime,
      base: caller.agent.extensions,
      loaded: this.deps.runtime.loadedPackages,
      sessions: this.deps.runtime.sessionsExtension,
      spawn: grant,
      grant,
      ...(saved
        ? {
            instructions: {
              cwd: caller.agent.cwd ?? "",
              ...(workspace.systemPrompt ? { workspacePrompt: workspace.systemPrompt } : {}),
            },
          }
        : {}),
    });
    return {
      ...(saved ? { agent: saved.definition.name } : {}),
      apply: async (tx, child) => {
        await configure(tx, child, change);
        // The child runs where its parent runs.
        const from = await tx.doc(DurableRuntime, parentId);
        const to = await tx.doc(DurableRuntime, child);
        to.kind = from.kind;
        if (from.workspaceId !== undefined) to.workspaceId = from.workspaceId;
        Object.assign(await tx.doc(OppiAgentDoc, child), structuredClone(doc));
      },
    };
  }

  /** A model and thinking level a spawn names, validated; rejects with a message for the model. */
  private async modelChoice(
    model: string | undefined,
    thinking: string | undefined,
  ): Promise<{ model?: ModelRef; thinkingLevel?: ThinkingLevel }> {
    if (thinking !== undefined && !isThinkingLevel(thinking))
      throw new Error(`Unknown thinking level: ${thinking}`);
    const thinkingLevel = thinking as ThinkingLevel | undefined;
    if (model === undefined) return { ...(thinkingLevel ? { thinkingLevel } : {}) };
    const { models } = await this.deps.runtime.ensureShared();
    const settings = SettingsManager.create(homedir(), getAgentDir(), { projectTrusted: false });
    const found = resolveSessionSeedModel(
      new ModelRegistry(models),
      model,
      settings.getEnabledModels(),
    );
    if (!found) throw new Error(`Model is unavailable: ${model}`);
    return {
      model: { provider: found.provider, modelId: found.id },
      ...(thinkingLevel ? { thinkingLevel } : {}),
    };
  }

  async materialize(
    child: { conversationId: ConversationId; name: string },
    env?: ExecutionEnv,
  ): Promise<string> {
    const storeId = hostOfEnv(env).storeId;
    const key = `${storeId}:${child.conversationId}`;
    const pending = this.materializing.get(key);
    if (pending) return pending;
    const created = this.materializeOnce(child, storeId).finally(() =>
      this.materializing.delete(key),
    );
    this.materializing.set(key, created);
    return created;
  }

  async submit(
    sessionId: string,
    input: Parameters<DurableSessionsHost["submit"]>[1],
  ): Promise<string | undefined> {
    const session = this.deps.storage.getSession(sessionId);
    const conversationId = session?.serverDurable?.conversationId as ConversationId | undefined;
    if (!session || conversationId === undefined)
      return `Session ${sessionId} has no conversation.`;
    // The session's own controller: the same request-id dedupe and failure card as its socket.
    return this.deps.runtime.withSession(session, async (harness, host) => {
      if (!(await harness.conversation(conversationId, BACKGROUND_CONTEXT)))
        return `Session ${sessionId} has no conversation.`;
      const controller = await host.controller(conversationId);
      const options = {
        requestId: input.requestId,
        ...(input.entry ? { entry: input.entry } : {}),
      };
      await (input.whenBusy === "steer"
        ? controller.steer(input.content, options)
        : controller.followUp(input.content, options));
      return undefined;
    });
  }

  async waitForIdle(sessionId: string): Promise<string | undefined> {
    const session = this.deps.storage.getSession(sessionId);
    const conversationId = session?.serverDurable?.conversationId as ConversationId | undefined;
    if (!session || conversationId === undefined)
      return `Session ${sessionId} has no conversation.`;
    return this.deps.runtime.withSession(session, async (harness, host) => {
      if (!(await harness.conversation(conversationId, BACKGROUND_CONTEXT)))
        return `Session ${sessionId} has no conversation.`;
      await (await host.controller(conversationId)).waitForPrompt();
      return undefined;
    });
  }

  private async materializeOnce(
    child: {
      conversationId: ConversationId;
      name: string;
    },
    storeId: string,
  ): Promise<string> {
    const key = `${DURABLE_THREAD_KEY_PREFIX}${storeId}:${child.conversationId}`;
    let session = this.deps.storage.findSessionByLaunchIdempotencyKey(key);
    // Only a row bound to this very conversation is ours to adopt (a crash between saving it
    // and attaching it). Clients cannot create keys in this namespace, so anything else is
    // corruption: fail the spawn rather than run the child in someone else's Session slot.
    if (
      session &&
      (session.serverDurable?.conversationId !== child.conversationId ||
        durableStoreId(session) !== storeId)
    )
      throw new Error(
        `Session ${session.id} holds the key of child conversation ${child.conversationId} but is not bound to the child conversation`,
      );
    if (!session) {
      session = await this.createSession(storeId, child.conversationId, child.name, key);
      this.deps.onCreated(session);
    }
    // A Session that exists but is not attached (a crash between the two steps, or a Stop)
    // is attached again here, so a restart finds it live and keeps its conversation.
    await this.activate(session.id);
    return session.id;
  }

  private async createSession(
    storeId: string,
    conversationId: ConversationId,
    name: string,
    key: string,
  ): Promise<Session> {
    const host = this.deps.runtime.host(storeId);
    if (!host) throw new Error(`Durable store ${storeId} is not open`);
    const { harness } = await host.open();
    const record = await harness.commit(
      (tx) => tx.conversation(conversationId),
      BACKGROUND_CONTEXT,
    );
    const ownerConversation = record?.owner?.conversationId;
    if (ownerConversation === undefined)
      throw new Error(`Durable conversation ${conversationId} is not owned by a parent`);
    const parent = this.deps.storage.findSessionByDurableConversation(storeId, ownerConversation);
    const workspace = parent?.workspaceId
      ? this.deps.storage.getWorkspace(parent.workspaceId)
      : undefined;
    if (!parent || !parent.workspaceId || !workspace)
      throw new Error("Only a workspace session can spawn child sessions");
    const conversation = await harness.conversation(conversationId, BACKGROUND_CONTEXT);
    if (!conversation) throw new Error(`Durable conversation ${conversationId} is missing`);
    // The spawn configured the child in its creating commit; the row shows what it launched as.
    const launched = await harness.snapshot(OppiAgentDoc, conversationId, BACKGROUND_CONTEXT);
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
      ...(parent.worktreeId ? { worktreeId: parent.worktreeId } : {}),
      thinkingLevel: agent.thinkingLevel,
      // Bound before anything is submitted, so a restart finds the conversation in `resumeIds`.
      serverDurable: { storeId, conversationId },
      launch: {
        source: "agent",
        ...(launched?.agent
          ? {
              agentId: launched.agent.id,
              agentVersion: launched.agent.version,
              ...(launched.agent.icon ? { agentIcon: launched.agent.icon } : {}),
            }
          : {}),
        // Write-once copy of the ownership edge; the Harness stays the source of truth.
        parentSessionId: parent.id,
        // A copy of the grant on the child's `oppi.agent` document, for `oppi session create`.
        ...(launched?.grant ? { allowsNestedDelegation: true } : {}),
        idempotencyKey: key,
        target: {
          workspaceId: parent.workspaceId,
          ...(parent.worktreeId ? { worktreeId: parent.worktreeId } : {}),
          runtime: workspace.runtime === "sandbox" ? "sandbox" : "host",
        },
        ...(model ? { model } : {}),
        thinkingLevel: agent.thinkingLevel,
        ...(launched?.tools ? { tools: launched.tools } : {}),
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
    const session = this.deps.storage.getSession(sessionId);
    const conversationId = session?.serverDurable?.conversationId as ConversationId | undefined;
    if (!session || conversationId === undefined) return undefined;
    return this.deps.runtime.withSession(session, async (harness, host) => {
      const { chain, members } = await readThread(harness, conversationId);
      const byConversation = new Map<ConversationId, string>();
      for (const { conversationId, sessionId } of this.deps.storage.listDurableStoreConversations(
        host.storeId,
      )) {
        const id = conversationId as ConversationId;
        if (!byConversation.has(id)) byConversation.set(id, sessionId);
      }
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
    });
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
