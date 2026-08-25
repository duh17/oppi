import { describe, expect, it, vi } from "vitest";

import {
  resolveEnabledScopedModels,
  resolveInitialScopedSessionPins,
} from "../src/session-scoped-models.js";

describe("resolveEnabledScopedModels", () => {
  it("omits scopedModels when enabledModels is missing", async () => {
    const resolve = vi.fn();

    await expect(resolveEnabledScopedModels(undefined, resolve)).resolves.toEqual({
      diagnostics: [],
    });
    expect(resolve).not.toHaveBeenCalled();
  });

  it("omits scopedModels when enabledModels is empty", async () => {
    const resolve = vi.fn();

    await expect(resolveEnabledScopedModels([], resolve)).resolves.toEqual({
      diagnostics: [],
    });
    expect(resolve).not.toHaveBeenCalled();
  });

  it("passes thinking-pinned patterns through to scopedModels", async () => {
    const scopedModels = [
      {
        model: { provider: "anthropic", id: "claude-sonnet-4-0", name: "Sonnet" },
        thinkingLevel: "high",
      },
    ];
    const resolve = vi.fn(async (patterns: string[]) => {
      expect(patterns).toEqual(["anthropic/*:high"]);
      return {
        scopedModels,
        diagnostics: [],
      };
    });

    await expect(resolveEnabledScopedModels(["anthropic/*:high"], resolve)).resolves.toEqual({
      scopedModels,
      diagnostics: [],
    });
    expect(resolve).toHaveBeenCalledOnce();
  });

  it("keeps diagnostics and omits scopedModels when nothing matches", async () => {
    const diagnostics = [
      {
        type: "warning" as const,
        code: "no-match" as const,
        message: "No models matched",
        pattern: "missing/*:high",
      },
    ];
    const resolve = vi.fn(async () => ({
      scopedModels: [],
      diagnostics,
    }));

    await expect(resolveEnabledScopedModels(["missing/*:high"], resolve)).resolves.toEqual({
      diagnostics,
    });
  });
});

const SONNET = { provider: "anthropic", id: "claude-sonnet-4-0", name: "Sonnet" };
const OPUS = { provider: "anthropic", id: "claude-opus-4-0", name: "Opus" };
const SCOPED = [
  { model: SONNET, thinkingLevel: "high" as const },
  { model: OPUS, thinkingLevel: "low" as const },
];

describe("resolveInitialScopedSessionPins", () => {
  it("applies the matching scoped thinking pin when session.model is set", () => {
    expect(
      resolveInitialScopedSessionPins({
        scopedModels: SCOPED,
        resolvedModel: OPUS,
        sessionModel: "anthropic/claude-opus-4-0",
      }),
    ).toEqual({ model: OPUS, thinkingLevel: "low" });
  });

  it("matches a bare session.model id when registry resolution failed", () => {
    expect(
      resolveInitialScopedSessionPins({
        scopedModels: SCOPED,
        sessionModel: "claude-sonnet-4-0",
      }),
    ).toEqual({ thinkingLevel: "high" });
  });

  it("seeds the first scoped model when session.model and default are unset", () => {
    expect(
      resolveInitialScopedSessionPins({
        scopedModels: SCOPED,
      }),
    ).toEqual({ model: SONNET, thinkingLevel: "high" });
  });

  it("seeds the SettingsManager default when it is later in scopedModels", () => {
    expect(
      resolveInitialScopedSessionPins({
        scopedModels: SCOPED,
        defaultProvider: "anthropic",
        defaultModel: "claude-opus-4-0",
      }),
    ).toEqual({ model: OPUS, thinkingLevel: "low" });
  });

  it("falls back to the first scoped model when the default is outside scope", () => {
    expect(
      resolveInitialScopedSessionPins({
        scopedModels: SCOPED,
        defaultProvider: "openai",
        defaultModel: "gpt-5.4",
      }),
    ).toEqual({ model: SONNET, thinkingLevel: "high" });
  });

  it("preserves an explicit session thinking level", () => {
    expect(
      resolveInitialScopedSessionPins({
        scopedModels: SCOPED,
        resolvedModel: SONNET,
        sessionModel: "anthropic/claude-sonnet-4-0",
        explicitThinkingLevel: "minimal",
      }),
    ).toEqual({ model: SONNET, thinkingLevel: "minimal" });
  });

  it("does not replace a required launch model when session.model is unset", () => {
    expect(
      resolveInitialScopedSessionPins({
        scopedModels: SCOPED,
        requiredLaunchModel: true,
      }),
    ).toEqual({ thinkingLevel: "high" });
  });

  it("does not pin thinking or seed a model for resumed transcripts", () => {
    expect(
      resolveInitialScopedSessionPins({
        scopedModels: SCOPED,
        isResume: true,
      }),
    ).toEqual({});
  });
});
