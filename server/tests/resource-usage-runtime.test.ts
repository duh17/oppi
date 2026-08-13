import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it, vi } from "vitest";

import {
  ResourceUsageBackfill,
  opaqueResourceUsageSourceKey,
} from "../src/resource-usage-backfill.js";
import { SessionAgentEventCoordinator } from "../src/session-agent-events.js";
import { SessionInputCoordinator } from "../src/session-input.js";
import type { ResourceUsagePromptEvidence } from "../src/resource-usage-service.js";
import { SdkBackend } from "../src/sdk-backend.js";
import { ResourceUsageStore } from "../src/storage/resource-usage-store.js";
import { serverResourceId } from "../src/server-resource-id.js";

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
        { skills: new Map(), commands: new Map(), tools: new Map(), builtInTools: new Set() },
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

    coordinator.handlePiEvent("session-1", {
      type: "tool_execution_start",
      toolCallId: "call-1",
      toolName: "review_tool",
      args: { private: "must not be captured" },
    } as never);

    expect(captureToolInvocation).toHaveBeenCalledWith({
      session: active.session,
      runtime: "oppi",
      toolName: "review_tool",
      toolCallId: "call-1",
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
