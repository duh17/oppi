import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { ModelRegistry, SettingsManager, getAgentDir } from "@earendil-works/pi-coding-agent";
import {
  AgentDoc,
  configure,
  type Agent,
  type ConversationId,
  type Harness,
  type ModelRef,
} from "@earendil-works/pi-durable";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import type {
  Activated,
  DurableSessionsHost,
  ResolvedSubagent,
  SessionSender,
  SubagentRequest,
  SubagentWorktreePlan,
  SubagentWorktreeRequest,
} from "./durable-extension-api.js";
import { childDelegationGrant } from "./agent-launch-service.js";
import {
  OppiAgentDoc,
  resolveDurableAgent,
  retargetInstructions,
  type SavedAgent,
} from "./durable-agent.js";
import { DurableRuntime, type DurableHarness, type SessionHost } from "./durable-harness.js";
import { durableStoreId } from "./session-runtime-capabilities.js";
import { DURABLE_THREAD_KEY_PREFIX } from "./reserved-launch-keys.js";
import { mintSessionId } from "./id.js";
import { safeErrorMessage } from "./log-utils.js";
import { resolveSessionSeedModel } from "./sdk-backend.js";
import type { Storage } from "./storage.js";
import { isThinkingLevel, type ThinkingLevel } from "./thinking-levels.js";
import type { SubagentWorktree } from "../extensions/durable/sessions/contract.js";
import { resolveSessionWorkRoot } from "./session-work-root.js";
import type { Session, Workspace } from "./types.js";
import {
  availableWorktreeBranch,
  ensureWorkspaceWorktree,
  headCommit,
  listWorkspaceWorktrees,
  resolveCreateBase,
  resolveWorkspaceWorktree,
  subagentWorktreeBranch,
  workspaceGitRoot,
  worktreeProgress,
} from "./worktrees.js";

export interface DurableThreadsDeps {
  runtime: DurableHarness;
  storage: Pick<
    Storage,
    | "findSessionByDurableConversation"
    | "findSessionByLaunchIdempotencyKey"
    | "getAgentDefinitionStore"
    | "getDataDir"
    | "getSession"
    | "getWorkspace"
    | "listAllWorkspaceSessionSnapshots"
    | "listDurableStoreConversations"
    | "saveSession"
  >;
  /**
   * Attach a session and run `submit`, the commit delivering work to it, while the session
   * counts that incoming work: a child stops once it settles with nothing pending
   * (`launch.autoStop`), and this keeps it, or waits out a stop already under way.
   */
  withIncomingWork<T>(
    sessionId: string,
    workspace: Workspace | undefined,
    submit: () => Promise<T>,
  ): Promise<{ attached: true; value: T } | { attached: false; error: unknown; closing: boolean }>;
  /** A Session row exists for a new child; clients learn about it. */
  onCreated(session: Session): void;
}

/**
 * Oppi's side of durable threads. Ownership lives in the Harness: a child conversation is
 * owned by a task of its parent's conversation, and that edge is the only record of who
 * spawned whom. This class gives each owned child its Oppi Session, bound by conversation
 * id, and reads the thread tree back from the ownership edges.
 */
/** Owner edges a subtree check follows at most; spawning nests far less deep. */
const MAX_THREAD_DEPTH = 64;

/** A `"new"` branch a spawn planned but never provisioned is free again after this. */
const HELD_BRANCH_MAX_AGE_MS = 10 * 60_000;

export class DurableThreads {
  /** Concurrent materializations of one child (tool rerun, reporter) share one result. */
  private readonly materializing = new Map<string, Promise<string>>();
  /**
   * `"new"` worktree branches held from planning until provisioning, keyed by the tool call that
   * asked: two spawns can plan at once, and neither may take the other's branch. Entries older
   * than a call that never provisioned are dropped at the next plan.
   */
  private readonly heldBranches = new Map<string, { branch: string; at: number }>();

  constructor(private readonly deps: DurableThreadsDeps) {}

  /**
   * What `oppiHost().sessions(env)` gives the conversation `caller` of `host`'s store. It takes
   * only Sessions bound to conversations the caller owns, its own children, as `subagent`
   * addresses them by name; any other Session, of this store or another, is refused.
   */
  forCaller(host: SessionHost, caller: ConversationId): DurableSessionsHost {
    /** Undefined when `sessionId` is bound to a child of the caller, otherwise why not. */
    const refuse = async (sessionId: string): Promise<string | undefined> => {
      const session = this.deps.storage.getSession(sessionId);
      const conversationId = session?.serverDurable?.conversationId as ConversationId | undefined;
      if (
        session &&
        conversationId !== undefined &&
        durableStoreId(session) === host.storeId &&
        (await ownerOf(host, conversationId)) === caller
      )
        return undefined;
      return `Session ${sessionId} is not a child of this session.`;
    };
    return {
      storeId: host.storeId,
      sender: () => this.sessionOf(host.storeId, caller),
      materialize: async (child) => {
        if ((await ownerOf(host, child.conversationId)) !== caller)
          throw new Error(`Conversation ${child.conversationId} is not a child of this session`);
        return this.materialize(child, host.storeId);
      },
      pendingWakers: async (child) => {
        if ((await ownerOf(host, child)) !== caller)
          throw new Error(`Conversation ${child} is not a child of this session`);
        return host.pendingWakers(child);
      },
      waitForIdle: async (sessionId, signal) =>
        (await refuse(sessionId)) ?? this.waitForIdle(sessionId, signal),
      activate: async (sessionId, submit) => {
        const refused = await refuse(sessionId);
        if (refused !== undefined) throw new Error(refused);
        return this.activate(sessionId, submit);
      },
      resolveAgent: (request, agent) => this.resolveAgent(request, host, caller, agent),
      planWorktree: (request, name, call) => this.planWorktree(request, name, call, host, caller),
      provisionWorktree: (plan, options) => this.provisionWorktree(plan, options, host, caller),
      worktreeState: (worktree) => this.worktreeState(worktree),
    };
  }

  /**
   * Whether conversation `ancestor` of `host`'s store owns `id`, directly or through the children
   * it owns: `id` is in its subtree. Walks owner edges up from `id`, the edge `forCaller` checks.
   */
  async ownsWithin(
    host: SessionHost,
    ancestor: ConversationId,
    id: ConversationId,
  ): Promise<boolean> {
    let current = id;
    for (let depth = 0; depth < MAX_THREAD_DEPTH; depth += 1) {
      const owner = await ownerOf(host, current);
      if (owner === undefined) return false;
      if (owner === ancestor) return true;
      current = owner;
    }
    return false;
  }

  private sessionOf(storeId: string, conversationId: ConversationId): SessionSender | undefined {
    const session = this.deps.storage.findSessionByDurableConversation(storeId, conversationId);
    return session
      ? { sessionId: session.id, ...(session.name ? { name: session.name } : {}) }
      : undefined;
  }

  private async activate<T>(sessionId: string, submit: () => Promise<T>): Promise<Activated<T>> {
    const session = this.deps.storage.getSession(sessionId);
    if (!session) throw new Error(`Session not found: ${sessionId}`);
    const workspace = session.workspaceId
      ? this.deps.storage.getWorkspace(session.workspaceId)
      : undefined;
    const result = await this.deps.withIncomingWork(sessionId, workspace, submit);
    return result.attached
      ? { submitted: result.value }
      : { failed: safeErrorMessage(result.error), shuttingDown: result.closing };
  }

  /**
   * `subagent spawn`'s side of the one resolver (`resolveDurableAgent`): the caller's delegation
   * grant and runtime from its documents, the saved Agent and its launch constraints, and the
   * model. The child is configured in its creating commit through `apply`.
   */
  private async resolveAgent(
    request: SubagentRequest,
    host: SessionHost,
    parentId: ConversationId,
    agent: Agent,
  ): Promise<ResolvedSubagent> {
    const { harness } = await host.open();
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
      base: agent.extensions,
      loaded: this.deps.runtime.loadedPackages,
      classic: this.deps.runtime.classicExtensions,
      enabled: (name) => this.deps.runtime.isExtensionEnabled(name),
      sessions: this.deps.runtime.sessionsExtension,
      spawn: grant,
      // Children report to their parent; only top-level sessions notify the user.
      notify: this.deps.runtime.notifyExtension,
      notifies: false,
      grant,
      // Narrow-only: a spawn may take tools away from its child, never add one.
      ...(request.tools !== undefined ||
      request.excludeTools !== undefined ||
      request.readOnly !== undefined
        ? {
            narrow: {
              parentTools: agent.tools.map((tool) => tool.name),
              ...(request.tools !== undefined ? { tools: request.tools } : {}),
              ...(request.excludeTools !== undefined ? { excludeTools: request.excludeTools } : {}),
              ...(request.readOnly !== undefined ? { readOnly: request.readOnly } : {}),
            },
          }
        : {}),
      ...(saved
        ? {
            instructions: {
              cwd: agent.cwd ?? "",
              ...(workspace.systemPrompt ? { workspacePrompt: workspace.systemPrompt } : {}),
            },
          }
        : {}),
    });
    const icon = saved?.definition.icon;
    return {
      ...(saved ? { agent: saved.definition.name } : {}),
      ...(icon?.kind === "emoji" ? { icon: icon.value } : {}),
      apply: async (tx, child, worktree) => {
        await configure(tx, child, change);
        // The child runs where its parent runs, unless its spawn gave it a worktree of its own.
        const from = await tx.doc(DurableRuntime, parentId);
        const to = await tx.doc(DurableRuntime, child);
        to.kind = from.kind;
        if (from.workspaceId !== undefined) to.workspaceId = from.workspaceId;
        if (worktree) to.worktreeId = worktree.id;
        Object.assign(await tx.doc(OppiAgentDoc, child), structuredClone(doc));
        if (!worktree) return;
        // Its `pi.agent` cwd is where the Harness runs it: the worktree, and the instructions
        // say so too (a child copies its parent's, which names the parent's checkout).
        const agentDoc = await tx.doc(AgentDoc, child);
        agentDoc.cwd = worktree.path;
        const instructions = retargetInstructions(agentDoc.instructions, worktree.path);
        if (instructions !== undefined) agentDoc.instructions = instructions;
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

  /** The spawning conversation's Session, workspace, and runtime documents. */
  private async worktreeCaller(
    host: SessionHost,
    caller: ConversationId,
  ): Promise<{
    parent: Session;
    workspace: Workspace;
    runtime: { kind: "host" | "sandbox"; worktreeId?: string } | undefined;
  }> {
    const { harness } = await host.open();
    const runtime = await harness.snapshot(DurableRuntime, caller, BACKGROUND_CONTEXT);
    const parent = this.deps.storage.findSessionByDurableConversation(host.storeId, caller);
    const workspace = parent?.workspaceId
      ? this.deps.storage.getWorkspace(parent.workspaceId)
      : undefined;
    if (!parent || !workspace) throw new Error("Only a workspace session can spawn child sessions");
    return { parent, workspace, runtime };
  }

  /** Worktree ids a Session of this workspace still references: reusing one would move history. */
  private reservedWorktreeIds(workspaceId: string): Set<string> {
    const ids = new Set<string>();
    for (const session of this.deps.storage.listAllWorkspaceSessionSnapshots(workspaceId)) {
      const id = session.worktreeId?.trim();
      if (id) ids.add(id);
    }
    return ids;
  }

  /**
   * What a spawn's `worktree` asks for, checked before anything runs: a host workspace that is a
   * git repository, and an adopted id that is one of its worktrees. A `"new"` branch stays held
   * for `call` until `provisionWorktree` settles, so a concurrent spawn plans another one.
   * Reads only.
   */
  private async planWorktree(
    request: SubagentWorktreeRequest,
    name: string,
    call: string,
    host: SessionHost,
    caller: ConversationId,
  ): Promise<SubagentWorktreePlan> {
    const { parent, workspace, runtime } = await this.worktreeCaller(host, caller);
    if (runtime?.kind === "sandbox")
      throw new Error(
        "A sandbox session cannot spawn a worktree child: worktrees need the host's git repository",
      );
    await workspaceGitRoot(workspace);
    const dataDir = this.deps.storage.getDataDir();
    if (typeof request !== "string" && "id" in request) {
      const worktree = await resolveWorkspaceWorktree(workspace, request.id, { dataDir });
      if (!worktree || worktree.isMain)
        throw new Error(`Worktree ${request.id} is not a worktree of workspace ${workspace.name}`);
      return { mode: "adopt", id: worktree.id };
    }
    const root = await resolveSessionWorkRoot(parent, workspace, dataDir, { create: false });
    if (root.kind !== "ok")
      throw new Error(
        `The spawning session's checkout is unavailable (${root.kind}); a worktree child needs one`,
      );
    const base = await resolveCreateBase(
      workspace,
      root.root,
      typeof request === "string" ? undefined : request.base,
    );
    if (request === "new") {
      const branch = await this.holdBranch(workspace, call, subagentWorktreeBranch(name), dataDir);
      return { mode: "create", branch, base };
    }
    const branch = typeof request === "string" ? "" : request.branch.trim();
    if (!branch) throw new Error('worktree needs a branch name or "new"');
    return { mode: "create", branch, base };
  }

  /**
   * Create the planned worktree, or take the one `adopt` allows: an explicit branch creates or
   * adopts it, while a `"new"` branch never adopts one, so a checkout another spawn made is a
   * clear refusal instead of a shared checkout.
   */
  private async provisionWorktree(
    plan: SubagentWorktreePlan,
    options: { call: string; adopt: boolean },
    host: SessionHost,
    caller: ConversationId,
  ): Promise<SubagentWorktree> {
    try {
      const { workspace } = await this.worktreeCaller(host, caller);
      const dataDir = this.deps.storage.getDataDir();
      if (plan.mode === "adopt") {
        const worktree = await resolveWorkspaceWorktree(workspace, plan.id, { dataDir });
        if (!worktree) throw new Error(`Worktree ${plan.id} is no longer available`);
        return {
          id: worktree.id,
          path: worktree.path,
          branch: worktree.branch,
          // An adopted worktree has no base of ours: its own HEAD is where this child starts.
          base: (await headCommit(worktree.path)) ?? "",
        };
      }
      const existing = (await listWorkspaceWorktrees(workspace, { dataDir })).find(
        (worktree) => !worktree.isMain && worktree.branch === plan.branch,
      );
      if (existing && !options.adopt)
        throw new Error(
          `Worktree branch ${plan.branch} appeared while this spawn was planning; retry it`,
        );
      const worktree =
        existing ??
        (await ensureWorkspaceWorktree(
          workspace,
          { branch: plan.branch, base: plan.base },
          {
            dataDir,
            reservedWorktreeIds: this.reservedWorktreeIds(workspace.id),
            adoptExistingBranch: options.adopt,
          },
        ));
      return {
        id: worktree.id,
        path: worktree.path,
        branch: worktree.branch,
        base: plan.base,
      };
    } finally {
      // Released only once the create settles: a spawn planning meanwhile must not take it.
      this.heldBranches.delete(options.call);
    }
  }

  /**
   * The first free branch from `base` this call may take, held until it provisions. The claim is
   * synchronous and comes first, so two spawns planning at once cannot both choose one branch;
   * the git check then only moves the claim on when the checkout already has that name.
   */
  private async holdBranch(
    workspace: Workspace,
    call: string,
    base: string,
    dataDir: string,
  ): Promise<string> {
    const now = Date.now();
    for (const [key, held] of this.heldBranches)
      if (key !== call && now - held.at > HELD_BRANCH_MAX_AGE_MS) this.heldBranches.delete(key);
    let start = base;
    for (let round = 0; round < 99; round += 1) {
      const claimed = this.claimBranch(call, start);
      const free = await availableWorktreeBranch(workspace, claimed, {
        dataDir,
        reservedWorktreeIds: this.reservedWorktreeIds(workspace.id),
      });
      if (free === claimed) return free;
      // The checkout already has that name: claim the one the check moved on to.
      start = free;
    }
    throw new Error(`No free branch name for ${base}`);
  }

  /** Claim the next branch from `start` no other call holds, synchronously. */
  private claimBranch(call: string, start: string): string {
    for (let attempt = 1; attempt <= 99; attempt += 1) {
      const candidate = attempt === 1 ? start : `${start}-${attempt}`;
      const holder = [...this.heldBranches].find(
        ([key, held]) => key !== call && held.branch === candidate,
      );
      if (holder) continue;
      this.heldBranches.set(call, { branch: candidate, at: Date.now() });
      return candidate;
    }
    throw new Error(`No free branch name for ${start}`);
  }

  /** One compact line of where a child's worktree stands: branch, id, path, ahead, clean/dirty. */
  private async worktreeState(worktree: SubagentWorktree): Promise<string | undefined> {
    if (!existsSync(worktree.path))
      return `${worktree.branch ?? "detached"} \u00b7 ${worktree.id} \u00b7 gone`;
    const { ahead, dirty } = await worktreeProgress(worktree.path, worktree.base || undefined);
    return [
      worktree.branch ?? "detached",
      worktree.id,
      worktree.path,
      ahead === 1 ? "1 commit ahead" : `${ahead} commits ahead`,
      dirty ? "dirty" : "clean",
    ].join(" \u00b7 ");
  }

  /** The Session bound to `child`, a conversation of `storeId`; created and attached on first use. */
  async materialize(
    child: { conversationId: ConversationId; name: string },
    storeId: string,
  ): Promise<string> {
    const key = `${storeId}:${child.conversationId}`;
    const pending = this.materializing.get(key);
    if (pending) return pending;
    const created = this.materializeOnce(child, storeId).finally(() =>
      this.materializing.delete(key),
    );
    this.materializing.set(key, created);
    return created;
  }

  async waitForIdle(sessionId: string, signal?: AbortSignal): Promise<string | undefined> {
    const session = this.deps.storage.getSession(sessionId);
    const conversationId = session?.serverDurable?.conversationId as ConversationId | undefined;
    if (!session || conversationId === undefined)
      return `Session ${sessionId} has no conversation.`;
    return this.deps.runtime.withSession(session, async (harness, host) => {
      if (!(await harness.conversation(conversationId, BACKGROUND_CONTEXT)))
        return `Session ${sessionId} has no conversation.`;
      await (await host.controller(conversationId)).waitForPrompt(signal);
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
    // Whatever submits to the child attaches it first (`activate`), so a Session is attached
    // only while it has work, and a restart before that leaves nothing to resume.
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
    // A worktree spawn bound the child's worktree on its runtime document, so the row (and a
    // crash re-bind that reaches this without new arguments) reads it from there.
    const childRuntime = await harness.snapshot(DurableRuntime, conversationId, BACKGROUND_CONTEXT);
    const worktreeId = childRuntime?.worktreeId ?? parent.worktreeId;
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
      ...(worktreeId ? { worktreeId } : {}),
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
        // An idle conversation costs nothing and takes messages later: the child detaches once
        // it settles with no pending wake, and `activate` attaches it again for new work.
        autoStop: true,
        target: {
          workspaceId: parent.workspaceId,
          ...(worktreeId ? { worktreeId } : {}),
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

/** The conversation whose task owns `id` in `host`'s store; undefined for an ownerless one. */
async function ownerOf(host: SessionHost, id: ConversationId): Promise<ConversationId | undefined> {
  const { harness } = await host.open();
  const record = await harness.commit((tx) => tx.conversation(id), BACKGROUND_CONTEXT);
  return record?.owner?.conversationId;
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
