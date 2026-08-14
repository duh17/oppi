import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

import {
  ResourceUsageService,
  resourceUsageActionId,
  resourceUsageToolOccurrenceId,
} from "../src/resource-usage-service.js";
import { ResourceUsageStore } from "../src/storage/resource-usage-store.js";

const dirs: string[] = [];

function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), "oppi-resource-usage-service-"));
  dirs.push(dir);
  return dir;
}

afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

describe("ResourceUsageService exact live capture", () => {
  it("encodes provider tool IDs and ordinals injectively before action hashing", () => {
    const providerHashLikeId = resourceUsageToolOccurrenceId("call#2", 1);
    const reusedProviderId = resourceUsageToolOccurrenceId("call", 2);

    expect(providerHashLikeId).toMatch(/^tool-occurrence-v1_[a-f0-9]{64}$/);
    expect(reusedProviderId).toMatch(/^tool-occurrence-v1_[a-f0-9]{64}$/);
    expect(providerHashLikeId).not.toBe(reusedProviderId);
    for (const signal of ["tool_invocation", "skill_instruction_read"] as const) {
      expect(resourceUsageActionId("oppi", "trace-1", signal, providerHashLikeId)).not.toBe(
        resourceUsageActionId("oppi", "trace-1", signal, reusedProviderId),
      );
      expect(resourceUsageActionId("oppi", "trace-1", signal, providerHashLikeId)).toBe(
        resourceUsageActionId("pi-tui", "trace-1", signal, providerHashLikeId),
      );
    }
  });

  it("isolates bounded write failures from session/tool execution", async () => {
    const now = Date.UTC(2026, 6, 27, 12);
    const store = new ResourceUsageStore(tempDir(), { now: () => now });
    const recordBatch = store.recordBatch.bind(store);
    let shouldFail = true;
    store.recordBatch = (...args) => {
      if (shouldFail) {
        shouldFail = false;
        throw new Error("disk unavailable");
      }
      recordBatch(...args);
    };
    const service = new ResourceUsageService(store, { now: () => now });

    expect(() =>
      service.captureToolInvocation({
        session: { id: "session-1", model: "anthropic/sonnet" },
        runtime: "oppi",
        toolName: "read",
        toolCallId: "call-1",
        evidence: {
          ownerKind: "builtin",
          ownerId: "builtin",
          provider: "anthropic",
          model: "sonnet",
        },
      }),
    ).not.toThrow();
    await expect(service.flush()).resolves.toBeUndefined();

    const response = await service.getUsage({ kind: "tools" }, 7, "UTC");
    expect(response.capture).toMatchObject({ status: "degraded", failedWrites: 1 });
    await service.close();
  });

  it("records only tools with trustworthy live identity and ownership evidence", async () => {
    const now = Date.UTC(2026, 6, 27, 12);
    const store = new ResourceUsageStore(tempDir(), { now: () => now });
    const service = new ResourceUsageService(store, { now: () => now });
    const session = { id: "session-1", piSessionId: "trace-1", model: "anthropic/sonnet" };

    service.captureToolInvocation({
      session,
      runtime: "oppi",
      toolName: "read",
      toolCallId: "call-1",
      evidence: { ownerKind: "builtin", ownerId: "builtin" },
    });
    service.captureToolInvocation({
      session,
      runtime: "pi-tui",
      toolName: "mirror_tool",
      toolCallId: "mirror-call",
    });
    service.captureToolInvocation({
      session,
      runtime: "oppi",
      toolName: "missing-id",
      evidence: { ownerKind: "builtin", ownerId: "builtin" },
    });

    await service.flush();
    const tools = await service.getUsage({ kind: "tools" }, 7, "UTC");
    expect(tools.recordedActions).toBe(1);
    expect(tools.breakdown).toEqual([
      expect.objectContaining({
        signal: "tool_invocation",
        name: "read",
        ownerKind: "builtin",
        actions: 1,
      }),
    ]);
    await service.close();
  });

  it("keeps repeated Skill loads as a separate availability signal, not recorded usage", async () => {
    const now = Date.UTC(2026, 6, 27, 12);
    const store = new ResourceUsageStore(tempDir(), { now: () => now });
    const service = new ResourceUsageService(store, { now: () => now });
    const session = { id: "session-loads", piSessionId: "trace-loads", model: "anthropic/sonnet" };
    const skill = { id: "skill-testing", name: "testing", manifestRevision: "manifest-1" };

    service.captureSkillLoads({
      session,
      runtime: "oppi",
      skills: [skill],
      runtimeInstanceId: "runtime-a",
      generation: 1,
    });
    service.captureSkillLoads({
      session,
      runtime: "oppi",
      skills: [skill],
      runtimeInstanceId: "runtime-a",
      generation: 2,
    });
    service.captureSkillLoads({
      session: { ...session, model: "openai/gpt" },
      runtime: "oppi",
      skills: [{ ...skill, manifestRevision: "manifest-2" }],
      runtimeInstanceId: "runtime-b",
      generation: 1,
    });
    service.captureSkillLoads({
      session: { ...session, model: "openai/gpt" },
      runtime: "oppi",
      skills: [{ ...skill, manifestRevision: "manifest-2" }],
      runtimeInstanceId: "runtime-b",
      generation: 1,
    });

    await service.flush();
    const result = await service.getUsage({ kind: "skill", id: "skill-testing" }, 7, "UTC");
    expect(result.recordedActions).toBe(0);
    expect(result.breakdown).toEqual([]);
    expect(result.loadedSessionSignal).toMatchObject({ actions: 3, sessions: 1 });
    await service.close();
  });

  it("records accepted Skill and Extension command evidence without prompt content", async () => {
    const now = Date.UTC(2026, 6, 27, 12);
    const store = new ResourceUsageStore(tempDir(), { now: () => now });
    const service = new ResourceUsageService(store, { now: () => now });
    const session = {
      id: "session-1",
      workspaceId: "workspace-1",
      model: "anthropic/sonnet",
    };

    service.captureAcceptedPrompt({
      session,
      runtime: "oppi",
      producerId: "turn-1",
      evidence: {
        signal: "explicit_activation",
        itemName: "testing",
        ownerKind: "skill",
        ownerId: "skill_testing",
      },
    });
    service.captureAcceptedPrompt({
      session,
      runtime: "oppi",
      producerId: "turn-2",
      evidence: {
        signal: "command_invocation",
        itemName: "review",
        ownerKind: "extension",
        ownerId: "extension_review",
      },
    });

    await service.flush();
    const skill = await service.getUsage({ kind: "skill", id: "skill_testing" }, 7, "UTC");
    const extension = await service.getUsage(
      { kind: "extension", id: "extension_review" },
      7,
      "UTC",
    );
    expect(skill.breakdown).toEqual([
      expect.objectContaining({ signal: "explicit_activation", name: "testing", actions: 1 }),
    ]);
    expect(extension.breakdown).toEqual([
      expect.objectContaining({ signal: "command_invocation", name: "review", actions: 1 }),
    ]);
    expect(JSON.stringify({ skill, extension })).not.toContain("prompt");
    await service.close();
  });

  it("deduplicates the same producer identity and keeps repeated accepted actions distinct", async () => {
    const now = Date.UTC(2026, 6, 27, 12);
    const store = new ResourceUsageStore(tempDir(), { now: () => now });
    const service = new ResourceUsageService(store, { now: () => now });
    const evidence = {
      signal: "command_invocation" as const,
      itemName: "review",
      ownerKind: "extension" as const,
      ownerId: "extension_review",
    };
    const session = { id: "session-repeated", piSessionId: "trace-repeated" };

    for (const producerId of ["turn-1", "turn-1", "turn-2"]) {
      service.captureAcceptedPrompt({
        session,
        runtime: "oppi",
        producerId,
        evidence,
        occurredAt: now,
      });
    }

    await service.flush();
    const result = await service.getUsage({ kind: "extension", id: "extension_review" }, 7, "UTC");
    expect(result.recordedActions).toBe(2);
    await service.close();
  });

  it("keeps GET query-only without flushing or pruning writes", async () => {
    const now = Date.UTC(2026, 6, 27, 12);
    const store = new ResourceUsageStore(tempDir(), { now: () => now });
    const service = new ResourceUsageService(store, { now: () => now });
    const flush = vi.spyOn(service, "flush");
    const prune = vi.spyOn(store, "deleteExpired");

    await service.getUsage({ kind: "tools" }, 7, "UTC");

    expect(flush).not.toHaveBeenCalled();
    expect(prune).not.toHaveBeenCalled();
    await service.close();
  });

  it("keeps aggregation bounded to one overall and one grouped daily query", async () => {
    const now = Date.UTC(2026, 6, 27, 12);
    const store = new ResourceUsageStore(tempDir(), { now: () => now });
    const service = new ResourceUsageService(store, { now: () => now });
    const overall = vi.spyOn(store, "aggregate");
    const daily = vi.spyOn(store, "aggregateDaily");
    service.captureToolInvocation({
      session: { id: "session-aggregate", model: "anthropic/sonnet" },
      runtime: "oppi",
      toolName: "read",
      toolCallId: "call-aggregate",
      evidence: { ownerKind: "builtin", ownerId: "builtin" },
    });
    await service.getUsage({ kind: "tools" }, 90, "UTC");

    expect(overall).toHaveBeenCalledOnce();
    expect(daily).toHaveBeenCalledOnce();
    expect(daily.mock.calls[0]?.[0].ranges).toHaveLength(90);
    await service.close();
  });

  it("returns after shutdown timeout but closes the owned store when the scan settles", async () => {
    vi.useFakeTimers();
    const dir = tempDir();
    const store = new ResourceUsageStore(dir);
    const service = new ResourceUsageService(store);
    let settleScan!: () => void;
    const scanGate = new Promise<void>((resolve) => {
      settleScan = resolve;
    });
    const closeStore = vi.spyOn(store, "close");
    (service as unknown as { backfillTail: Promise<void> }).backfillTail = scanGate;

    const closing = service.close();
    await vi.advanceTimersByTimeAsync(5_000);
    await expect(closing).resolves.toBeUndefined();
    expect(closeStore).not.toHaveBeenCalled();

    settleScan();
    await vi.runAllTimersAsync();
    expect(closeStore).toHaveBeenCalledOnce();
    vi.useRealTimers();
  });

  it("persists one recording start timestamp across service restarts", async () => {
    const dir = tempDir();
    const firstNow = Date.UTC(2026, 6, 27, 12);
    const firstStore = new ResourceUsageStore(dir, { now: () => firstNow });
    const firstService = new ResourceUsageService(firstStore, { now: () => firstNow });
    expect((await firstService.getUsage({ kind: "tools" }, 7, "UTC")).recordingStartedAt).toBe(
      firstNow,
    );
    await firstService.close();

    const secondNow = firstNow + 86_400_000;
    const secondStore = new ResourceUsageStore(dir, { now: () => secondNow });
    const secondService = new ResourceUsageService(secondStore, { now: () => secondNow });
    expect((await secondService.getUsage({ kind: "tools" }, 7, "UTC")).recordingStartedAt).toBe(
      firstNow,
    );
    await secondService.close();
  });
});
