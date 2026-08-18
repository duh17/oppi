import { describe, expect, it } from "vitest";

import { composeModelId, SessionStateCoordinator } from "../src/session-state.js";
import type { PiStateSnapshot } from "../src/pi-events.js";
import type { Storage } from "../src/storage.js";
import type { Session } from "../src/types.js";

describe("composeModelId", () => {
  it("prefixes simple model ids with the provider", () => {
    expect(composeModelId("anthropic", "claude-sonnet-4-0")).toBe("anthropic/claude-sonnet-4-0");
  });

  it("preserves nested model ids while adding the provider prefix", () => {
    expect(composeModelId("openrouter", "z.ai/glm-5")).toBe("openrouter/z.ai/glm-5");
  });

  it("does not double-prefix an already qualified model id", () => {
    expect(composeModelId("anthropic", "anthropic/claude-sonnet-4-0")).toBe(
      "anthropic/claude-sonnet-4-0",
    );
  });

  it("handles local provider model ids", () => {
    expect(composeModelId("lmstudio", "glm-4.7-flash-mlx")).toBe("lmstudio/glm-4.7-flash-mlx");
  });
});

function makeSession(overrides: Partial<Session> = {}): Session {
  const now = Date.now();
  return {
    id: "s1",
    workspaceId: "w1",
    status: "ready",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
    ...overrides,
  };
}

function applySnapshot(
  session: Session,
  state: PiStateSnapshot | null | undefined,
  contextWindowResolver?: (modelId: string) => number,
): boolean {
  const coordinator = new SessionStateCoordinator({
    storage: {} as Storage,
    getContextWindowResolver: () => contextWindowResolver ?? null,
    persistSessionNow: () => {},
  });
  return coordinator.applyPiStateSnapshot(session, state);
}

describe("SessionStateCoordinator.applyPiStateSnapshot", () => {
  it("applies sessionFile", () => {
    const session = makeSession();

    const changed = applySnapshot(session, {
      sessionFile: "/tmp/pi-session.jsonl",
    });

    expect(changed).toBe(true);
    expect(session.piSessionFile).toBe("/tmp/pi-session.jsonl");
  });

  it("tracks multiple session files", () => {
    const session = makeSession();

    applySnapshot(session, { sessionFile: "/tmp/a.jsonl" });
    applySnapshot(session, { sessionFile: "/tmp/b.jsonl" });

    expect(session.piSessionFiles).toContain("/tmp/a.jsonl");
    expect(session.piSessionFiles).toContain("/tmp/b.jsonl");
  });

  it("does not write a second public identity from Pi sessionId", () => {
    const session = makeSession({ id: "s1" });

    const changed = applySnapshot(session, { sessionId: "uuid-123" });

    expect(changed).toBe(false);
    expect(session.id).toBe("s1");
    expect(session).not.toHaveProperty("piSessionId");
  });

  it("applies model with provider prefix", () => {
    const session = makeSession();

    const changed = applySnapshot(session, {
      model: { provider: "anthropic", id: "claude-sonnet-4-0" },
    });

    expect(changed).toBe(true);
    expect(session.model).toBe("anthropic/claude-sonnet-4-0");
  });

  it("recomputes stale 200k context window when snapshot confirms model", () => {
    const session = makeSession({
      model: "openai-codex/gpt-5.3-codex",
      contextWindow: 200_000,
    });
    const resolveContextWindow = (modelId: string) =>
      modelId === "openai-codex/gpt-5.3-codex" ? 272_000 : 200_000;

    const changed = applySnapshot(
      session,
      {
        model: { provider: "openai-codex", id: "gpt-5.3-codex" },
      },
      resolveContextWindow,
    );

    expect(changed).toBe(true);
    expect(session.model).toBe("openai-codex/gpt-5.3-codex");
    expect(session.contextWindow).toBe(272_000);
  });

  it("does not downgrade known model when snapshot model payload is malformed", () => {
    const session = makeSession({
      model: "openai-codex/gpt-5.3-codex",
      contextWindow: 272_000,
    });
    const resolveContextWindow = (modelId: string) =>
      modelId === "openai-codex/gpt-5.3-codex" ? 272_000 : 200_000;

    const changed = applySnapshot(
      session,
      {
        model: { provider: "GPT-5.3 Codex", id: "GPT-5.3 Codex" },
      },
      resolveContextWindow,
    );

    expect(changed).toBe(false);
    expect(session.model).toBe("openai-codex/gpt-5.3-codex");
    expect(session.contextWindow).toBe(272_000);
  });

  it("applies session name", () => {
    const session = makeSession();

    const changed = applySnapshot(session, { sessionName: "My Session" });

    expect(changed).toBe(true);
    expect(session.name).toBe("My Session");
  });

  it("applies thinking level", () => {
    const session = makeSession();

    const changed = applySnapshot(session, { thinkingLevel: "high" });

    expect(changed).toBe(true);
    expect(session.thinkingLevel).toBe("high");
  });

  it("marks a ready session busy when the SDK is still streaming", () => {
    const session = makeSession({ status: "ready" });

    const changed = applySnapshot(session, { isStreaming: true });

    expect(changed).toBe(true);
    expect(session.status).toBe("busy");
    expect(session.currentTurnStartedAt).toEqual(expect.any(Number));
  });

  it("does not revive terminal sessions from a streaming SDK snapshot", () => {
    const session = makeSession({ status: "stopped" });

    const changed = applySnapshot(session, { isStreaming: true });

    expect(changed).toBe(false);
    expect(session.status).toBe("stopped");
  });

  it("only mirrors Pi thinking level on state snapshot", () => {
    const session = makeSession({ model: "anthropic/claude-sonnet-4-0" });

    const changed = applySnapshot(session, { thinkingLevel: "high" });

    expect(changed).toBe(true);
    expect(session.thinkingLevel).toBe("high");
  });

  it("returns false for null/undefined state", () => {
    const session = makeSession();

    expect(applySnapshot(session, null)).toBe(false);
    expect(applySnapshot(session, undefined)).toBe(false);
  });

  it("returns false when nothing changed", () => {
    const session = makeSession({
      piSessionFile: "/tmp/same.jsonl",
      piSessionFiles: ["/tmp/same.jsonl"],
    });

    const changed = applySnapshot(session, {
      sessionFile: "/tmp/same.jsonl",
      sessionId: "uuid-1",
    });

    expect(changed).toBe(false);
  });

  it("ignores empty string values", () => {
    const session = makeSession();

    const changed = applySnapshot(session, {
      sessionFile: "",
      sessionId: "",
      sessionName: "",
    });

    expect(changed).toBe(false);
  });
});
