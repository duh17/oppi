import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

import { describe, expect, it, vi } from "vitest";
import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";

import {
  ResourceUsageBackfill,
  opaqueResourceUsageSourceKey,
} from "../src/resource-usage-backfill.js";
import { SessionAgentEventCoordinator } from "../src/session-agent-events.js";
import { SessionInputCoordinator } from "../src/session-input.js";
import {
  ResourceUsageService,
  type ResourceUsagePromptEvidence,
} from "../src/resource-usage-service.js";
import { SdkBackend } from "../src/sdk-backend.js";
import { ResourceUsageStore } from "../src/storage/resource-usage-store.js";
import { canonicalServerResourcePath, serverResourceId } from "../src/server-resource-id.js";
import { createSandboxSkillBindingToken } from "../src/sandbox-resource-paths.js";

function piSdkSessionEntries(path: string | undefined): Array<Record<string, unknown>> {
  if (!path) return [];
  return readFileSync(path, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as Record<string, unknown>);
}

function session() {
  return {
    id: "session-1",
    workspaceId: "workspace-opaque",
    runtime: "oppi" as const,
    status: "ready" as const,
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    model: "anthropic/sonnet",
  };
}

function runtimeCoordinator(input: {
  backend: SdkBackend;
  session?: ReturnType<typeof session>;
  resourceUsage?: {
    captureToolInvocation: (...args: never[]) => unknown;
    captureSkillInstructionRead?: (...args: never[]) => unknown;
  };
}) {
  const active = {
    session: input.session ?? session(),
    sdkBackend: input.backend,
    subscribers: new Set(),
    partialResults: new Map(),
    streamedAssistantText: "",
    hasStreamedThinking: false,
    streamedThinkingContentIndexes: new Set(),
    toolNames: new Map(),
    toolArgs: new Map(),
    shellPreviewLastSent: new Map(),
    streamingToolUpdatesSeen: new Map(),
    toolFullOutputPaths: new Map(),
    pendingUIRequests: new Map(),
    cacheMissTracker: {},
    showCacheMissNotices: false,
  };
  return new SessionAgentEventCoordinator({
    getActiveSession: () => active as never,
    eventProcessor: {
      translationContext: () => ({
        sessionId: "session-1",
        partialResults: new Map(),
        streamedAssistantText: "",
        hasStreamedThinking: false,
        streamedThinkingContentIndexes: new Set(),
        toolNames: new Map(),
        toolArgs: new Map(),
        shellPreviewLastSent: new Map(),
        streamingToolUpdatesSeen: new Map(),
      }),
      updateSessionFromEvent: () => {},
    } as never,
    stopCoordinator: { finishPendingStopOnAgentEnd: () => {} },
    turnCoordinator: { markNextTurnStarted: () => {} } as never,
    broadcast: () => {},
    resetIdleTimer: () => {},
    resourceUsage: input.resourceUsage as never,
  });
}

describe("resource usage runtime capture", () => {
  it("resolves loaded Skill, Extension tool/command, and active model evidence", () => {
    const skill = {
      name: "testing",
      description: "Tests",
      filePath: "/tmp/testing/SKILL.md",
      baseDir: "/tmp/testing",
      disableModelInvocation: false,
      sourceInfo: {
        path: "/tmp/testing/SKILL.md",
        source: "local",
        scope: "user",
        origin: "top-level",
      },
    };
    const registeredTool = {
      definition: { name: "review_tool" },
      sourceInfo: {
        path: "/tmp/review-extension/index.ts",
        source: "local",
        scope: "user",
        origin: "top-level",
      },
    };
    const registeredCommand = {
      name: "review",
      invocationName: "review",
      handler: vi.fn(),
      sourceInfo: registeredTool.sourceInfo,
    };
    const extension = {
      path: "/tmp/review-extension",
      tools: new Map([["review_tool", registeredTool]]),
      commands: new Map([["review", registeredCommand]]),
    };
    const backend = Object.create(SdkBackend.prototype) as SdkBackend;
    (backend as unknown as { runtime: unknown }).runtime = {
      session: {
        model: { provider: "anthropic", id: "sonnet" },
        resourceLoader: {
          getSkills: () => ({ skills: [skill], diagnostics: [] }),
          getExtensions: () => ({ extensions: [extension], errors: [] }),
        },
        extensionRunner: {
          getAllRegisteredTools: () => [registeredTool],
          getRegisteredCommands: () => [registeredCommand],
        },
      },
      services: {},
    };

    expect(backend.resourceUsageSkillLoadEvidence()).toEqual([
      expect.objectContaining({
        id: serverResourceId("skill", "/tmp/testing/SKILL.md"),
        name: "testing",
        provider: "anthropic",
        model: "sonnet",
        manifestRevision: expect.any(String),
      }),
    ]);
    expect(backend.resourceUsageToolEvidence("review_tool")).toEqual(
      expect.objectContaining({
        ownerKind: "extension",
        ownerId: serverResourceId("extension", "/tmp/review-extension"),
        provider: "anthropic",
        model: "sonnet",
      }),
    );
    expect(backend.resourceUsageToolEvidence("read")).toEqual(
      expect.objectContaining({ ownerKind: "builtin", ownerId: "builtin" }),
    );
    expect(backend.resourceUsagePromptEvidence("/skill:testing run tests")).toEqual(
      expect.objectContaining({
        signal: "explicit_activation",
        ownerId: serverResourceId("skill", "/tmp/testing/SKILL.md"),
      }),
    );
    expect(backend.resourceUsagePromptEvidence("/review now")).toBeUndefined();
  });

  it("counts a throwing Extension command at dispatch with stable invocation identity", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-resource-command-"));
    const extensionDir = join(cwd, ".pi", "extensions");
    mkdirSync(extensionDir, { recursive: true });
    writeFileSync(
      join(extensionDir, "throw-command.ts"),
      [
        "export default function (pi) {",
        "  pi.registerCommand('throw-command', {",
        "    description: 'Throws',",
        "    handler: async () => { throw new Error('command failed'); },",
        "  });",
        "}",
      ].join("\n"),
    );
    const backend = await SdkBackend.create({
      session: session(),
      workspace: { id: "workspace-opaque", name: "Command", hostMount: cwd } as never,
      onEvent: vi.fn(),
      onEnd: vi.fn(),
    });
    const capture = vi.fn();
    backend.onResourceUsageCommandInvoked = capture;

    try {
      await backend.prompt("/throw-command", { resourceUsageProducerId: "turn-command-1" });
      expect(capture).toHaveBeenCalledWith({
        producerId: "turn-command-1",
        evidence: expect.objectContaining({
          signal: "command_invocation",
          itemName: "throw-command",
          ownerKind: "extension",
        }),
      });
    } finally {
      await backend.dispose();
      rmSync(cwd, { recursive: true, force: true });
    }
  });

  it("persists two identical accepted commands through the coordinator and SDK", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-resource-repeat-production-"));
    const extensionDir = join(cwd, ".pi", "extensions");
    mkdirSync(extensionDir, { recursive: true });
    writeFileSync(
      join(extensionDir, "repeat-command.ts"),
      [
        "export default function (pi) {",
        "  pi.registerCommand('repeat-command', {",
        "    description: 'Repeatable',",
        "    handler: async () => {},",
        "  });",
        "}",
      ].join("\n"),
    );
    const backend = await SdkBackend.create({
      session: { ...session(), ephemeral: false },
      workspace: { id: "workspace-opaque", name: "Repeat", hostMount: cwd } as never,
      onEvent: vi.fn(),
      onEnd: vi.fn(),
    });
    const captureAcceptedPrompt = vi.fn();
    backend.onResourceUsageCommandInvoked = ({ producerId, evidence }) => ({
      version: 2,
      actionId: producerId === "turn-1" ? "a".repeat(64) : "b".repeat(64),
      producerId,
      ...evidence,
    });
    const active = {
      session: session(),
      sdkBackend: backend,
      currentTurnClientId: undefined,
      clientTurnFingerprints: new Map(),
      pendingTurnIntents: new Map(),
    };
    const coordinator = new SessionInputCoordinator({
      config: { dataDir: cwd } as never,
      getActiveSession: () => active as never,
      turnCoordinator: {
        isDuplicateTurnIntent: () => false,
        beginTurnIntent: (_key, _active, _kind, _payload, clientTurnId) => ({
          duplicate: false,
          clientTurnId,
        }),
        markTurnDispatched: () => {},
      },
      sendCommand: (_key, command, _permit, onPreflightAccepted) =>
        backend.prompt(command.message as string, {
          resourceUsageProducerId: command.clientTurnId as string,
          onPreflightAccepted,
        }),
      resourceUsage: { captureAcceptedPrompt } as never,
    });

    try {
      await coordinator.sendPrompt("session-1", "/repeat-command", { clientTurnId: "turn-1" });
      await coordinator.sendPrompt("session-1", "/repeat-command", { clientTurnId: "turn-2" });
      await new Promise((resolve) => setImmediate(resolve));
      const entries = backend.session.sessionManager.getEntries() as unknown as Array<
        Record<string, unknown>
      >;
      const markers = entries.filter(
        (entry) => entry.type === "custom" && entry.customType === "oppi-resource-usage",
      );
      expect(markers).toHaveLength(2);
      expect(markers.map((entry) => (entry.data as { producerId: string }).producerId)).toEqual([
        "turn-1",
        "turn-2",
      ]);
      expect(markers.map((entry) => (entry.data as { actionId: string }).actionId)).toEqual([
        "a".repeat(64),
        "b".repeat(64),
      ]);

      const trace = backend.session.exportToJsonl(join(cwd, "accepted-commands.jsonl"));
      const store = new ResourceUsageStore(cwd, {
        dbPath: join(cwd, "accepted-commands.db"),
      });
      await new ResourceUsageBackfill(store).run(
        [
          {
            sourceKey: opaqueResourceUsageSourceKey(trace),
            path: trace,
            sessionId: "session-1",
            workspaceId: "workspace-opaque",
            runtime: "oppi",
          },
        ],
        {
          skills: new Map(),
          skillPrimaryFiles: new Map(),
          commands: new Map(),
          tools: new Map(),
          builtInTools: new Set(),
        },
      );
      expect(
        store.queryEvents({
          subject: {
            kind: "extension",
            id: (markers[0]?.data as { ownerId: string }).ownerId,
          },
          sinceMs: 0,
          untilMs: Infinity,
        }),
      ).toHaveLength(2);
      store.close();
    } finally {
      await backend.dispose();
      rmSync(cwd, { recursive: true, force: true });
    }
  });

  it("captures Skill usage only after the real read execution succeeds while preserving Tool Activity", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-resource-read-success-"));
    const skillDir = join(cwd, ".pi", "skills", "testing");
    mkdirSync(skillDir, { recursive: true });
    const primary = join(skillDir, "SKILL.md");
    writeFileSync(primary, "---\nname: testing\ndescription: Tests\n---\n# Testing\n");
    const backend = await SdkBackend.create({
      session: session(),
      workspace: { id: "workspace-opaque", name: "Read", hostMount: cwd } as never,
      onEvent: vi.fn(),
      onEnd: vi.fn(),
    });
    const dir = mkdtempSync(join(tmpdir(), "oppi-resource-read-store-"));
    const store = new ResourceUsageStore(dir);
    const service = new (await import("../src/resource-usage-service.js")).ResourceUsageService(
      store,
    );
    const definition = backend.session.getToolDefinition("read");
    const toolCallId = "read-primary-success";

    try {
      const result = await definition?.execute(
        toolCallId,
        { path: primary },
        undefined,
        undefined,
        {
          model: backend.session.model,
        } as never,
      );
      const coordinator = runtimeCoordinator({
        backend,
        resourceUsage: service,
      });
      coordinator.handlePiEvent("session-1", {
        type: "tool_execution_start",
        toolCallId,
        toolName: "read",
        args: { path: primary },
      } as never);
      coordinator.handlePiEvent("session-1", {
        type: "tool_execution_end",
        toolCallId,
        toolName: "read",
        result,
        isError: false,
      } as never);
      await service.flush();

      const skillUsage = await service.getUsage(
        { kind: "skill", id: serverResourceId("skill", primary) },
        7,
        "UTC",
      );
      const tools = await service.getUsage({ kind: "tools" }, 7, "UTC");
      expect(skillUsage.recordedActions).toBe(1);
      expect(skillUsage.breakdown).toEqual([
        expect.objectContaining({ signal: "skill_instruction_read", name: "testing", actions: 1 }),
      ]);
      expect(tools.breakdown).toEqual([
        expect.objectContaining({ signal: "tool_invocation", name: "read", actions: 1 }),
      ]);
      expect(skillUsage.breakdown[0]?.actions + tools.breakdown[0]!.actions).toBe(2);
    } finally {
      await backend.dispose();
      await service.close();
      rmSync(cwd, { recursive: true, force: true });
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it.each([
    "absolute",
    "relative",
    "leading-at",
    "file-url",
    "unicode-space",
    "nfd",
    "curly-quote",
    "tilde",
  ] as const)(
    "captures a successful %s path with the same normalization as Pi read",
    async (pathKind) => {
      const cwd =
        pathKind === "tilde"
          ? mkdtempSync(join(homedir(), ".oppi-resource-live-read-"))
          : mkdtempSync(join(tmpdir(), "oppi-resource-live-read-"));
      const directoryName =
        pathKind === "unicode-space"
          ? "Skill 10 AM."
          : pathKind === "nfd"
            ? "Cafe\u0301"
            : pathKind === "curly-quote"
              ? "Tester’s Guide"
              : "testing";
      const skillDir = join(cwd, ".pi", "skills", directoryName);
      mkdirSync(skillDir, { recursive: true });
      const primary = join(skillDir, "SKILL.md");
      writeFileSync(primary, `---\nname: ${directoryName}\ndescription: Tests\n---\n# Testing\n`);
      const readPath = (() => {
        switch (pathKind) {
          case "absolute":
            return primary;
          case "relative":
            return join(".pi", "skills", "testing", "SKILL.md");
          case "leading-at":
            return `@${primary}`;
          case "file-url":
            return pathToFileURL(primary).href;
          case "unicode-space":
            return join(cwd, ".pi", "skills", "Skill 10\u202fAM.", "SKILL.md");
          case "nfd":
            return join(cwd, ".pi", "skills", "Café", "SKILL.md");
          case "curly-quote":
            return join(cwd, ".pi", "skills", "Tester's Guide", "SKILL.md");
          case "tilde":
            return `~/${primary.slice(homedir().length + 1)}`;
        }
      })();
      const backend = await SdkBackend.create({
        session: session(),
        workspace: { id: "workspace-opaque", name: "Read", hostMount: cwd } as never,
        onEvent: vi.fn(),
        onEnd: vi.fn(),
      });
      try {
        expect(backend.resourceUsageSkillReadEvidence(readPath)).toEqual(
          expect.objectContaining({ name: directoryName }),
        );
      } finally {
        await backend.dispose();
        rmSync(cwd, { recursive: true, force: true });
      }
    },
  );

  it.each(["failure", "cancelled"] as const)(
    "does not capture a %s primary Skill read from dispatch or tool start",
    async (outcome) => {
      const cwd = mkdtempSync(join(tmpdir(), "oppi-resource-read-failure-"));
      const skillDir = join(cwd, ".pi", "skills", "testing");
      mkdirSync(skillDir, { recursive: true });
      const primary = join(skillDir, "SKILL.md");
      writeFileSync(primary, "---\nname: testing\ndescription: Tests\n---\n# Testing\n");
      const backend = await SdkBackend.create({
        session: session(),
        workspace: { id: "workspace-opaque", name: "Read", hostMount: cwd } as never,
        onEvent: vi.fn(),
        onEnd: vi.fn(),
      });
      const capture = vi.fn();
      const definition = backend.session.getToolDefinition("read");
      const toolCallId = `read-primary-${outcome}`;
      const coordinator = runtimeCoordinator({
        backend,
        resourceUsage: { captureToolInvocation: vi.fn(), captureSkillInstructionRead: capture },
      });

      try {
        coordinator.handlePiEvent("session-1", {
          type: "tool_execution_start",
          toolCallId,
          toolName: "read",
          args: { path: primary },
        } as never);
        expect(capture).not.toHaveBeenCalled();
        if (outcome === "failure") {
          await expect(
            definition?.execute(
              toolCallId,
              { path: join(skillDir, "missing.md") },
              undefined,
              undefined,
              {} as never,
            ),
          ).rejects.toThrow();
        } else {
          const controller = new AbortController();
          controller.abort();
          await expect(
            definition?.execute(
              toolCallId,
              { path: primary },
              controller.signal,
              undefined,
              {} as never,
            ),
          ).rejects.toThrow("aborted");
        }
        coordinator.handlePiEvent("session-1", {
          type: "tool_execution_end",
          toolCallId,
          toolName: "read",
          result: { content: [] },
          isError: true,
        } as never);
        await new Promise((resolve) => setImmediate(resolve));
        expect(capture).not.toHaveBeenCalled();
      } finally {
        await backend.dispose();
        rmSync(cwd, { recursive: true, force: true });
      }
    },
  );

  it("keeps two reused tool IDs distinct and pairs interleaved successful reads FIFO", async () => {
    const captureToolInvocation = vi.fn();
    const captureSkillInstructionRead = vi.fn();
    const skills = new Map([
      ["/alpha/SKILL.md", { id: "skill_alpha", name: "alpha" }],
      ["/beta/SKILL.md", { id: "skill_beta", name: "beta" }],
      ["/gamma/SKILL.md", { id: "skill_gamma", name: "gamma" }],
      ["/delta/SKILL.md", { id: "skill_delta", name: "delta" }],
    ]);
    const backend = {
      resourceUsageToolEvidence: () => ({ ownerKind: "builtin", ownerId: "builtin" }),
      resourceUsageSkillReadEvidence: (path: string) => skills.get(path),
    } as unknown as SdkBackend;
    const coordinator = runtimeCoordinator({
      backend,
      resourceUsage: { captureToolInvocation, captureSkillInstructionRead },
    });
    const eventIds = ["a", "b", "c", "d"].map((value) => `trace-event-v1_${value.repeat(64)}`);
    let startIndex = 0;
    const start = (toolCallId: string, path: string) =>
      coordinator.handlePiEvent("session-1", {
        type: "tool_execution_start",
        toolCallId,
        toolName: "read",
        args: { path },
        resourceUsageEventId: eventIds[startIndex++],
      } as never);
    const end = (toolCallId: string) =>
      coordinator.handlePiEvent("session-1", {
        type: "tool_execution_end",
        toolCallId,
        toolName: "read",
        result: { content: [] },
        isError: false,
      } as never);

    start("reused-a", "/alpha/SKILL.md");
    start("reused-b", "/beta/SKILL.md");
    start("reused-a", "/gamma/SKILL.md");
    start("reused-b", "/delta/SKILL.md");
    end("reused-b");
    end("reused-a");
    end("reused-b");
    end("reused-a");
    await new Promise((resolve) => setImmediate(resolve));

    expect(captureToolInvocation.mock.calls.map(([input]) => input.toolCallId)).toEqual(eventIds);
    expect(
      captureSkillInstructionRead.mock.calls.map(([input]) => [input.toolCallId, input.skill.id]),
    ).toEqual([
      [eventIds[1], "skill_beta"],
      [eventIds[0], "skill_alpha"],
      [eventIds[3], "skill_delta"],
      [eventIds[2], "skill_gamma"],
    ]);
    expect(
      (coordinator as unknown as { resourceUsageState: Map<string, unknown> }).resourceUsageState
        .size,
    ).toBe(0);
  });

  it.each(["bash-first", "read-first"] as const)(
    "pairs same-ID read/bash results by tool name when %s",
    async (order) => {
      const captureSkillInstructionRead = vi.fn();
      const backend = {
        resourceUsageToolEvidence: () => ({ ownerKind: "builtin", ownerId: "builtin" }),
        resourceUsageSkillReadEvidence: () => ({ id: "skill_testing", name: "testing" }),
      } as unknown as SdkBackend;
      const coordinator = runtimeCoordinator({
        backend,
        resourceUsage: {
          captureToolInvocation: vi.fn(),
          captureSkillInstructionRead,
        },
      });
      const readEventId = `trace-event-v1_${"e".repeat(64)}`;
      const send = (type: "tool_execution_start" | "tool_execution_end", toolName: string) =>
        coordinator.handlePiEvent("session-1", {
          type,
          toolCallId: "same-provider-id",
          toolName,
          ...(type === "tool_execution_start"
            ? {
                args: toolName === "read" ? { path: "/testing/SKILL.md" } : {},
                resourceUsageEventId:
                  toolName === "read" ? readEventId : `trace-event-v1_${"f".repeat(64)}`,
              }
            : { result: { content: [] }, isError: false }),
        } as never);

      send("tool_execution_start", "read");
      send("tool_execution_start", "bash");
      const eventOrder = order === "bash-first" ? ["bash", "read"] : ["read", "bash"];
      send("tool_execution_end", eventOrder[0]!);
      await new Promise((resolve) => setImmediate(resolve));
      expect(captureSkillInstructionRead).toHaveBeenCalledTimes(order === "read-first" ? 1 : 0);
      send("tool_execution_end", eventOrder[1]!);
      await new Promise((resolve) => setImmediate(resolve));

      expect(captureSkillInstructionRead).toHaveBeenCalledTimes(1);
      expect(captureSkillInstructionRead.mock.calls[0]?.[0].toolCallId).toBe(readEventId);
    },
  );

  it.each(["failed", "cancelled"] as const)(
    "consumes but does not prove a same-ID %s read result",
    async (outcome) => {
      const captureSkillInstructionRead = vi.fn();
      const backend = {
        resourceUsageToolEvidence: () => ({ ownerKind: "builtin", ownerId: "builtin" }),
        resourceUsageSkillReadEvidence: () => ({ id: "skill_testing", name: "testing" }),
      } as unknown as SdkBackend;
      const coordinator = runtimeCoordinator({
        backend,
        resourceUsage: { captureToolInvocation: vi.fn(), captureSkillInstructionRead },
      });
      coordinator.handlePiEvent("session-1", {
        type: "tool_execution_start",
        toolCallId: "same-provider-id",
        toolName: "read",
        args: { path: "/testing/SKILL.md" },
      } as never);
      coordinator.handlePiEvent("session-1", {
        type: "tool_execution_start",
        toolCallId: "same-provider-id",
        toolName: "bash",
        args: {},
      } as never);
      coordinator.handlePiEvent("session-1", {
        type: "tool_execution_end",
        toolCallId: "same-provider-id",
        toolName: "bash",
        result: { content: [] },
        isError: false,
      } as never);
      await new Promise((resolve) => setImmediate(resolve));
      expect(captureSkillInstructionRead).not.toHaveBeenCalled();
      coordinator.handlePiEvent("session-1", {
        type: "tool_execution_end",
        toolCallId: "same-provider-id",
        toolName: "read",
        result: {
          content: [],
          ...(outcome === "cancelled" ? { details: { cancelled: true } } : {}),
        },
        isError: true,
      } as never);
      await new Promise((resolve) => setImmediate(resolve));
      expect(captureSkillInstructionRead).not.toHaveBeenCalled();
    },
  );

  it("propagates journal identities through Pi's managed subscriber path across restart", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-resource-sdk-restart-"));
    const cwd = join(root, "workspace");
    const agentDir = join(root, "agent");
    const dataDir = join(root, "data");
    const skillDir = join(cwd, ".pi", "skills", "testing");
    const primary = join(skillDir, "SKILL.md");
    const dbPath = join(dataDir, "resource-usage.db");
    mkdirSync(skillDir, { recursive: true });
    mkdirSync(agentDir, { recursive: true });
    mkdirSync(dataDir, { recursive: true });
    writeFileSync(primary, "---\nname: testing\ndescription: Tests\n---\n# Testing\n");
    writeFileSync(join(agentDir, "auth.json"), "{}");
    const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const managedSession = session();
    const liveToolProducerIds: string[] = [];
    const liveSkillProducerIds: string[] = [];
    const forwardedToolStarts: AgentSessionEvent[] = [];
    let tracePath: string | undefined;

    try {
      for (const phase of [0, 1]) {
        const store = new ResourceUsageStore(dataDir, { dbPath });
        const service = new ResourceUsageService(store);
        let coordinator: SessionAgentEventCoordinator | undefined;
        const backend = await SdkBackend.create({
          session: managedSession,
          workspace: {
            id: "workspace-opaque",
            name: "Managed identity restart",
            runtime: "host",
            hostMount: cwd,
          } as never,
          onEvent: (event) => {
            if (event.type === "tool_execution_start") forwardedToolStarts.push(event);
            coordinator?.handlePiEvent("session-1", event);
          },
          onEnd: vi.fn(),
        });
        coordinator = runtimeCoordinator({
          backend,
          session: managedSession,
          resourceUsage: {
            captureToolInvocation: ((
              input: Parameters<ResourceUsageService["captureToolInvocation"]>[0],
            ) => {
              liveToolProducerIds.push(input.toolCallId ?? "");
              service.captureToolInvocation(input);
            }) as never,
            captureSkillInstructionRead: ((
              input: Parameters<ResourceUsageService["captureSkillInstructionRead"]>[0],
            ) => {
              liveSkillProducerIds.push(input.toolCallId ?? "");
              service.captureSkillInstructionRead(input);
            }) as never,
          },
        });
        const handleAgentEvent = (
          backend.session as unknown as {
            _handleAgentEvent: (event: AgentSessionEvent) => Promise<void>;
          }
        )._handleAgentEvent.bind(backend.session);
        const genericCallId = "provider-generic-reused";
        const readCallId = "provider-read-reused";
        const timestamp = Date.now() + phase;

        await handleAgentEvent({
          type: "message_end",
          message: {
            role: "assistant",
            content: [
              {
                type: "toolCall",
                id: genericCallId,
                name: "bash",
                arguments: { command: "true" },
              },
              {
                type: "toolCall",
                id: readCallId,
                name: "read",
                arguments: { path: primary },
              },
            ],
            provider: "test",
            model: "test-model",
            usage: {
              input: 0,
              output: 0,
              cacheRead: 0,
              cacheWrite: 0,
              cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
            },
            stopReason: "toolUse",
            timestamp,
          },
        } as AgentSessionEvent);
        await handleAgentEvent({
          type: "tool_execution_start",
          toolCallId: genericCallId,
          toolName: "bash",
          args: { command: "true" },
        });
        await handleAgentEvent({
          type: "tool_execution_start",
          toolCallId: readCallId,
          toolName: "read",
          args: { path: primary },
        });
        await handleAgentEvent({
          type: "tool_execution_end",
          toolCallId: readCallId,
          toolName: "read",
          result: { content: [{ type: "text", text: "skill" }], details: {} },
          isError: false,
        });
        await handleAgentEvent({
          type: "message_end",
          message: {
            role: "toolResult",
            toolCallId: readCallId,
            toolName: "read",
            content: [{ type: "text", text: "skill" }],
            details: {},
            isError: false,
            timestamp,
          },
        } as AgentSessionEvent);
        await handleAgentEvent({
          type: "tool_execution_end",
          toolCallId: genericCallId,
          toolName: "bash",
          result: { content: [{ type: "text", text: "done" }], details: {} },
          isError: false,
        });
        await handleAgentEvent({
          type: "message_end",
          message: {
            role: "toolResult",
            toolCallId: genericCallId,
            toolName: "bash",
            content: [{ type: "text", text: "done" }],
            details: {},
            isError: false,
            timestamp,
          },
        } as AgentSessionEvent);
        await new Promise((resolve) => setImmediate(resolve));
        await service.close();
        tracePath = backend.session.sessionManager.getSessionFile();
        await backend.dispose();
      }

      const lifecycleStarts = piSdkSessionEntries(tracePath).filter(
        (entry) =>
          entry.type === "custom" &&
          entry.customType === "oppi-lifecycle" &&
          (entry.data as { event?: string } | undefined)?.event === "tool_execution_start",
      );
      const markerIds = lifecycleStarts.map((entry) => (entry.data as { eventId: string }).eventId);
      expect(markerIds).toHaveLength(4);
      expect(new Set(markerIds)).toHaveLength(4);
      expect(
        forwardedToolStarts.map(
          (event) =>
            (event as AgentSessionEvent & { resourceUsageEventId?: string }).resourceUsageEventId,
        ),
      ).toEqual(markerIds);
      expect(liveToolProducerIds).toEqual(markerIds);
      expect(liveSkillProducerIds).toEqual(
        lifecycleStarts.flatMap((entry) =>
          (entry.data as { toolName?: string }).toolName === "read"
            ? [(entry.data as { eventId: string }).eventId]
            : [],
        ),
      );

      const store = new ResourceUsageStore(dataDir, { dbPath });
      const sourceKey = opaqueResourceUsageSourceKey(tracePath!);
      const beforeReplay = {
        skills: store.queryEvents({
          subject: { kind: "skill", id: serverResourceId("skill", primary) },
          sinceMs: 0,
          untilMs: Infinity,
        }).length,
        tools: store.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
      };
      expect(beforeReplay.skills).toBe(2);
      expect(beforeReplay.tools.filter((event) => event.itemName === "read")).toHaveLength(2);
      expect(beforeReplay.tools.filter((event) => event.itemName === "bash")).toHaveLength(2);

      await new ResourceUsageBackfill(store).run(
        [
          {
            sourceKey,
            path: tracePath!,
            sessionId: managedSession.id,
            workspaceId: managedSession.workspaceId,
            runtime: "oppi",
          },
        ],
        {
          skills: new Map(),
          skillPrimaryFiles: new Map([
            [primary, { id: serverResourceId("skill", primary), name: "testing" }],
          ]),
          commands: new Map(),
          tools: new Map(),
          builtInTools: new Set(["bash", "read"]),
        },
      );
      const afterReplay = {
        skills: store.queryEvents({
          subject: { kind: "skill", id: serverResourceId("skill", primary) },
          sinceMs: 0,
          untilMs: Infinity,
        }).length,
        tools: store.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
      };
      expect(afterReplay.skills).toBe(2);
      expect(afterReplay.tools.filter((event) => event.itemName === "read")).toHaveLength(2);
      expect(afterReplay.tools.filter((event) => event.itemName === "bash")).toHaveLength(2);
      store.close();
    } finally {
      if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("keeps managed correlation overflow replay-neutral beyond 1024 pending starts", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-resource-sdk-overflow-"));
    const cwd = join(root, "workspace");
    const agentDir = join(root, "agent");
    const dataDir = join(root, "data");
    const skillDir = join(cwd, ".pi", "skills", "testing");
    const primary = join(skillDir, "SKILL.md");
    const dbPath = join(dataDir, "resource-usage.db");
    mkdirSync(skillDir, { recursive: true });
    mkdirSync(agentDir, { recursive: true });
    mkdirSync(dataDir, { recursive: true });
    writeFileSync(primary, "---\nname: testing\ndescription: Tests\n---\n# Testing\n");
    writeFileSync(join(agentDir, "auth.json"), "{}");
    const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const managedSession = session();
    const store = new ResourceUsageStore(dataDir, { dbPath });
    const service = new ResourceUsageService(store);
    const liveToolProducerIds: string[] = [];
    const liveSkillProducerIds: string[] = [];
    let coordinator: SessionAgentEventCoordinator | undefined;
    let backend: SdkBackend | undefined;

    try {
      backend = await SdkBackend.create({
        session: managedSession,
        workspace: {
          id: "workspace-opaque",
          name: "Managed overflow",
          runtime: "host",
          hostMount: cwd,
        } as never,
        onEvent: (event) => coordinator?.handlePiEvent("session-1", event),
        onEnd: vi.fn(),
      });
      coordinator = runtimeCoordinator({
        backend,
        session: managedSession,
        resourceUsage: {
          captureToolInvocation: ((
            input: Parameters<ResourceUsageService["captureToolInvocation"]>[0],
          ) => {
            liveToolProducerIds.push(input.toolCallId ?? "");
            service.captureToolInvocation(input);
          }) as never,
          captureSkillInstructionRead: ((
            input: Parameters<ResourceUsageService["captureSkillInstructionRead"]>[0],
          ) => {
            liveSkillProducerIds.push(input.toolCallId ?? "");
            service.captureSkillInstructionRead(input);
          }) as never,
        },
      });
      const handleAgentEvent = (
        backend.session as unknown as {
          _handleAgentEvent: (event: AgentSessionEvent) => Promise<void>;
        }
      )._handleAgentEvent.bind(backend.session);
      const emitSubscriberEvent = (
        backend.session as unknown as { _emit: (event: AgentSessionEvent) => void }
      )._emit.bind(backend.session);
      const starts: Array<Extract<AgentSessionEvent, { type: "tool_execution_start" }>> = [];
      const total = 1_026;
      const timestamp = Date.now();

      for (let index = 0; index < total; index += 1) {
        const toolCallId = `provider-overflow-${index}`;
        await handleAgentEvent({
          type: "message_end",
          message: {
            role: "assistant",
            content: [
              {
                type: "toolCall",
                id: toolCallId,
                name: "read",
                arguments: { path: primary },
              },
            ],
            provider: "test",
            model: "test-model",
            usage: {
              input: 0,
              output: 0,
              cacheRead: 0,
              cacheWrite: 0,
              cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
            },
            stopReason: "toolUse",
            timestamp: timestamp + index,
          },
        } as AgentSessionEvent);
        const start = {
          type: "tool_execution_start" as const,
          toolCallId,
          toolName: "read",
          args: { path: primary },
        };
        starts.push(start);
        await backend.session.extensionRunner.emit(start);
      }

      const lifecycleStarts = backend.session.sessionManager
        .getEntries()
        .filter(
          (entry) =>
            entry.type === "custom" &&
            entry.customType === "oppi-lifecycle" &&
            (entry.data as { event?: string } | undefined)?.event === "tool_execution_start",
        );
      const markerIds = lifecycleStarts.map((entry) => (entry.data as { eventId: string }).eventId);
      expect(markerIds).toHaveLength(total);
      expect(new Set(markerIds)).toHaveLength(total);

      for (const start of starts) emitSubscriberEvent(start);
      for (const [index, start] of starts.entries()) {
        await handleAgentEvent({
          type: "tool_execution_end",
          toolCallId: start.toolCallId,
          toolName: start.toolName,
          result: { content: [{ type: "text", text: "skill" }], details: {} },
          isError: false,
        });
        await handleAgentEvent({
          type: "message_end",
          message: {
            role: "toolResult",
            toolCallId: start.toolCallId,
            toolName: start.toolName,
            content: [{ type: "text", text: "skill" }],
            details: {},
            isError: false,
            timestamp: timestamp + total + index,
          },
        } as AgentSessionEvent);
      }
      await new Promise((resolve) => setImmediate(resolve));
      await service.flush();

      expect(liveToolProducerIds).toEqual(markerIds.slice(-2));
      expect(liveSkillProducerIds).toEqual(markerIds.slice(-2));
      expect(
        store.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
      ).toHaveLength(2);
      expect(
        store.queryEvents({
          subject: { kind: "skill", id: serverResourceId("skill", primary) },
          sinceMs: 0,
          untilMs: Infinity,
        }),
      ).toHaveLength(2);

      const tracePath = backend.session.sessionManager.getSessionFile();
      expect(tracePath).toEqual(expect.any(String));
      await new ResourceUsageBackfill(store).run(
        [
          {
            sourceKey: opaqueResourceUsageSourceKey(tracePath!),
            path: tracePath!,
            sessionId: managedSession.id,
            workspaceId: managedSession.workspaceId,
            runtime: "oppi",
          },
        ],
        {
          skills: new Map(),
          skillPrimaryFiles: new Map([
            [
              canonicalServerResourcePath(primary),
              { id: serverResourceId("skill", primary), name: "testing" },
            ],
          ]),
          commands: new Map(),
          tools: new Map(),
          builtInTools: new Set(["read"]),
        },
      );

      expect(
        store.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
      ).toHaveLength(total);
      expect(
        store.queryEvents({
          subject: { kind: "skill", id: serverResourceId("skill", primary) },
          sinceMs: 0,
          untilMs: Infinity,
        }),
      ).toHaveLength(total);
    } finally {
      if (backend) await backend.dispose();
      await service.close();
      if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("keeps rotated sandbox bindings replay-neutral with reused provider IDs", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-resource-process-restart-"));
    const dbPath = join(dir, "usage.db");
    const trace = join(dir, "trace.jsonl");
    const eventIds = [`trace-event-v1_${"a".repeat(64)}`, `trace-event-v1_${"b".repeat(64)}`];
    const bindingTokens = [createSandboxSkillBindingToken(), createSandboxSkillBindingToken()];
    expect(new Set(bindingTokens)).toHaveLength(2);
    const markers: Array<Record<string, unknown>> = [];

    for (const index of [0, 1]) {
      const store = new ResourceUsageStore(dir, { dbPath, now: () => 10_000 + index });
      const service = new ResourceUsageService(store, { now: () => 10_000 + index });
      const backend = {
        resourceUsageToolEvidence: () => ({ ownerKind: "builtin", ownerId: "builtin" }),
        resourceUsageSkillReadEvidence: () => ({
          id: "skill_testing",
          name: "testing",
          bindingToken: bindingTokens[index],
        }),
        appendResourceUsageSkillReadMarker: (marker: Record<string, unknown>) =>
          markers.push(marker),
      } as unknown as SdkBackend;
      const coordinator = runtimeCoordinator({ backend, resourceUsage: service });
      coordinator.handlePiEvent("session-1", {
        type: "tool_execution_start",
        toolCallId: "provider-reused",
        toolName: "read",
        args: { path: "/workspace/private/.pi/skills/testing/SKILL.md" },
        resourceUsageEventId: eventIds[index],
      } as never);
      coordinator.handlePiEvent("session-1", {
        type: "tool_execution_end",
        toolCallId: "provider-reused",
        toolName: "read",
        result: { content: [] },
        isError: false,
      } as never);
      await new Promise((resolve) => setImmediate(resolve));
      await service.close();
    }

    expect(markers.map((marker) => marker.producerId)).toEqual(eventIds);
    const entries: Array<Record<string, unknown>> = [
      {
        type: "session",
        id: "session-1",
        timestamp: new Date(10_000).toISOString(),
        cwd: "/workspace/private",
      },
    ];
    for (const [index, marker] of markers.entries()) {
      entries.push(
        {
          type: "message",
          id: `assistant-${index}`,
          timestamp: new Date(10_001 + index * 4).toISOString(),
          message: {
            role: "assistant",
            content: [
              {
                type: "toolCall",
                id: "provider-reused",
                name: "read",
                arguments: { path: "/workspace/private/.pi/skills/testing/SKILL.md" },
              },
            ],
          },
        },
        {
          type: "custom",
          id: `lifecycle-${index}`,
          timestamp: new Date(10_002 + index * 4).toISOString(),
          customType: "oppi-lifecycle",
          data: {
            version: 2,
            event: "tool_execution_start",
            toolCallId: "provider-reused",
            toolName: "read",
            eventId: eventIds[index],
          },
        },
        {
          type: "message",
          id: `result-${index}`,
          timestamp: new Date(10_003 + index * 4).toISOString(),
          message: {
            role: "toolResult",
            toolCallId: "provider-reused",
            toolName: "read",
            content: [],
            isError: false,
          },
        },
        {
          type: "custom",
          id: `skill-marker-${index}`,
          timestamp: new Date(10_004 + index * 4).toISOString(),
          customType: "oppi-resource-usage",
          data: marker,
        },
      );
    }
    writeFileSync(trace, `${entries.map((entry) => JSON.stringify(entry)).join("\n")}\n`);

    const store = new ResourceUsageStore(dir, { dbPath, now: () => 20_000 });
    const sourceKey = opaqueResourceUsageSourceKey(trace);
    store.mergeBackfillSkillBindings({
      sourceKey,
      sessionId: "session-1",
      workspaceId: "workspace-opaque",
      bindings: bindingTokens.map((bindingToken) => ({
        bindingToken,
        skillId: "skill_testing",
        skillName: "testing",
      })),
    });
    const beforeReplay = {
      skills: store.queryEvents({
        subject: { kind: "skill", id: "skill_testing" },
        sinceMs: 0,
        untilMs: Infinity,
      }).length,
      tools: store.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity })
        .length,
    };
    await new ResourceUsageBackfill(store, { now: () => 20_000 }).run(
      [
        {
          sourceKey,
          path: trace,
          sessionId: "session-1",
          workspaceId: "workspace-opaque",
          runtime: "oppi",
          sandboxSkillBindings: store.getBackfillSkillBindings(sourceKey),
        },
      ],
      {
        skills: new Map(),
        skillPrimaryFiles: new Map(),
        commands: new Map(),
        tools: new Map(),
        builtInTools: new Set(["read"]),
      },
    );
    const afterReplay = {
      skills: store.queryEvents({
        subject: { kind: "skill", id: "skill_testing" },
        sinceMs: 0,
        untilMs: Infinity,
      }).length,
      tools: store.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity })
        .length,
    };
    expect(beforeReplay).toEqual({ skills: 2, tools: 2 });
    expect(afterReplay).toEqual(beforeReplay);
    store.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it("releases pending occurrence state on definitive session removal", async () => {
    const captureSkillInstructionRead = vi.fn();
    const backend = {
      resourceUsageToolEvidence: () => ({ ownerKind: "builtin", ownerId: "builtin" }),
      resourceUsageSkillReadEvidence: () => ({ id: "skill_testing", name: "testing" }),
    } as unknown as SdkBackend;
    const coordinator = runtimeCoordinator({
      backend,
      resourceUsage: { captureToolInvocation: vi.fn(), captureSkillInstructionRead },
    });
    coordinator.handlePiEvent("session-1", {
      type: "tool_execution_start",
      toolCallId: "pending-read",
      toolName: "read",
      args: { path: "/testing/SKILL.md" },
      resourceUsageEventId: `trace-event-v1_${"e".repeat(64)}`,
    } as never);

    (
      coordinator as unknown as {
        releaseResourceUsageSession: (session: ReturnType<typeof session>) => void;
      }
    ).releaseResourceUsageSession(session());
    coordinator.handlePiEvent("session-1", {
      type: "tool_execution_end",
      toolCallId: "pending-read",
      toolName: "read",
      result: { content: [] },
      isError: false,
    } as never);
    await new Promise((resolve) => setImmediate(resolve));

    expect(captureSkillInstructionRead).not.toHaveBeenCalled();
  });

  it("records every tool start with action-time managed owner/model evidence", () => {
    const captureToolInvocation = vi.fn();
    const active = {
      session: session(),
      sdkBackend: {
        resourceUsageToolEvidence: () => ({
          ownerKind: "extension" as const,
          ownerId: "extension_review",
          provider: "anthropic",
          model: "sonnet",
          manifestRevision: "manifest-1",
        }),
      },
      subscribers: new Set(),
      partialResults: new Map(),
      streamedAssistantText: "",
      hasStreamedThinking: false,
      streamedThinkingContentIndexes: new Set(),
      toolNames: new Map(),
      toolArgs: new Map(),
      shellPreviewLastSent: new Map(),
      streamingToolUpdatesSeen: new Map(),
      toolFullOutputPaths: new Map(),
      pendingUIRequests: new Map(),
      cacheMissTracker: {},
      showCacheMissNotices: false,
    };
    const coordinator = new SessionAgentEventCoordinator({
      getActiveSession: () => active as never,
      eventProcessor: {
        translationContext: () => ({
          sessionId: "session-1",
          partialResults: new Map(),
          streamedAssistantText: "",
          hasStreamedThinking: false,
          streamedThinkingContentIndexes: new Set(),
          toolNames: new Map(),
          toolArgs: new Map(),
          shellPreviewLastSent: new Map(),
          streamingToolUpdatesSeen: new Map(),
        }),
        updateSessionFromEvent: () => {},
      } as never,
      stopCoordinator: { finishPendingStopOnAgentEnd: () => {} },
      turnCoordinator: { markNextTurnStarted: () => {} } as never,
      broadcast: () => {},
      resetIdleTimer: () => {},
      resourceUsage: { captureToolInvocation } as never,
    });

    const eventId = `trace-event-v1_${"9".repeat(64)}`;
    coordinator.handlePiEvent("session-1", {
      type: "tool_execution_start",
      toolCallId: "call-1",
      toolName: "review_tool",
      args: { private: "must not be captured" },
      resourceUsageEventId: eventId,
    } as never);

    expect(captureToolInvocation).toHaveBeenCalledWith({
      session: active.session,
      runtime: "oppi",
      toolName: "review_tool",
      toolCallId: eventId,
      evidence: expect.objectContaining({
        ownerKind: "extension",
        ownerId: "extension_review",
        provider: "anthropic",
        model: "sonnet",
      }),
    });
    expect(JSON.stringify(captureToolInvocation.mock.calls)).not.toContain("must not be captured");
  });

  it("measurement failures cannot fail tool projection", () => {
    const active = {
      session: session(),
      sdkBackend: { resourceUsageToolEvidence: () => undefined },
      subscribers: new Set(),
      partialResults: new Map(),
      streamedAssistantText: "",
      hasStreamedThinking: false,
      streamedThinkingContentIndexes: new Set(),
      toolNames: new Map(),
      toolArgs: new Map(),
      shellPreviewLastSent: new Map(),
      streamingToolUpdatesSeen: new Map(),
      toolFullOutputPaths: new Map(),
      pendingUIRequests: new Map(),
      cacheMissTracker: {},
      showCacheMissNotices: false,
    };
    const coordinator = new SessionAgentEventCoordinator({
      getActiveSession: () => active as never,
      eventProcessor: {
        translationContext: () => ({
          sessionId: "session-1",
          partialResults: new Map(),
          streamedAssistantText: "",
          hasStreamedThinking: false,
          streamedThinkingContentIndexes: new Set(),
          toolNames: new Map(),
          toolArgs: new Map(),
          shellPreviewLastSent: new Map(),
          streamingToolUpdatesSeen: new Map(),
        }),
        updateSessionFromEvent: () => {},
      } as never,
      stopCoordinator: { finishPendingStopOnAgentEnd: () => {} },
      turnCoordinator: { markNextTurnStarted: () => {} } as never,
      broadcast: () => {},
      resetIdleTimer: () => {},
      resourceUsage: {
        captureToolInvocation: () => {
          throw new Error("measurement unavailable");
        },
      } as never,
    });

    expect(() =>
      coordinator.handlePiEvent("session-1", {
        type: "tool_execution_start",
        toolCallId: "call-1",
        toolName: "read",
        args: {},
      } as never),
    ).not.toThrow();
  });

  it("records Skill activation only after prompt preflight acceptance", async () => {
    const evidence: ResourceUsagePromptEvidence = {
      signal: "explicit_activation",
      itemName: "testing",
      ownerKind: "skill",
      ownerId: "skill_testing",
    };
    const captureAcceptedPrompt = vi.fn().mockReturnValue({
      version: 2,
      producerId: "turn-1",
      actionId: "a".repeat(64),
      ...evidence,
    });
    const active = {
      session: session(),
      sdkBackend: {
        resourceUsagePromptEvidence: () => evidence,
        appendResourceUsageHistoryMarker: vi.fn(),
      },
      currentTurnClientId: undefined,
      clientTurnFingerprints: new Map(),
      pendingTurnIntents: new Map(),
    };
    const coordinator = new SessionInputCoordinator({
      config: { dataDir: "/tmp/oppi-resource-usage-runtime-test" } as never,
      getActiveSession: () => active as never,
      turnCoordinator: {
        isDuplicateTurnIntent: () => false,
        beginTurnIntent: () => ({ duplicate: false }),
        markTurnDispatched: () => {},
      },
      sendCommand: (_key, _command, _permit, onPreflightAccepted) => {
        expect(captureAcceptedPrompt).not.toHaveBeenCalled();
        onPreflightAccepted?.();
      },
      resourceUsage: { captureAcceptedPrompt } as never,
    });

    await coordinator.sendPrompt("session-1", "/skill:testing run focused tests", {
      clientTurnId: "turn-1",
    });

    expect(captureAcceptedPrompt).toHaveBeenCalledWith({
      session: active.session,
      runtime: "oppi",
      evidence,
      producerId: "turn-1",
      occurredAt: expect.any(Number),
    });
    expect(active.sdkBackend.appendResourceUsageHistoryMarker).toHaveBeenCalledOnce();
  });
});
