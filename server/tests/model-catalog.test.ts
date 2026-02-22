import { describe, expect, it, vi } from "vitest";
import { ModelCatalog } from "../src/model-catalog.js";
import type { ModelRegistry } from "@mariozechner/pi-coding-agent";
import type { Storage } from "../src/storage.js";
import type { Session } from "../src/types.js";

// ─── Helpers ───

function makeRegistry(
  available: Array<{ id: string; name: string; provider: string; contextWindow: number }> = [],
  all?: Array<{ id: string; name: string; provider: string; contextWindow: number }>,
): ModelRegistry {
  return {
    refresh: vi.fn(),
    getAvailable: vi.fn(() => available),
    getAll: vi.fn(() => all ?? available),
  } as unknown as ModelRegistry;
}

function makeStorage(sessions: Session[] = []): Storage & { saved: Session[] } {
  const saved: Session[] = [];
  return {
    saved,
    saveSession: vi.fn((s: Session) => saved.push(s)),
    listSessions: vi.fn(() => sessions),
  } as unknown as Storage & { saved: Session[] };
}

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

const SONNET = {
  id: "claude-sonnet-4-20250514",
  name: "Claude Sonnet 4",
  provider: "anthropic",
  contextWindow: 200000,
};

const GPT = {
  id: "gpt-5.3-codex",
  name: "GPT-5.3 Codex",
  provider: "openai",
  contextWindow: 272000,
};

const GEMINI = {
  id: "gemini-3.0-pro",
  name: "Gemini 3.0 Pro",
  provider: "google",
  contextWindow: 2000000,
};

// ─── Tests ───

describe("ModelCatalog", () => {
  describe("refresh", () => {
    it("populates catalog from available models", () => {
      const registry = makeRegistry([SONNET, GPT]);
      const catalog = new ModelCatalog(registry, makeStorage());

      catalog.refresh();

      const models = catalog.getAll();
      expect(models).toHaveLength(2);
      expect(models[0].id).toBe("anthropic/claude-sonnet-4-20250514");
      expect(models[1].id).toBe("openai/gpt-5.3-codex");
    });

    it("falls back to all models when available is empty", () => {
      const registry = makeRegistry([], [SONNET]);
      const catalog = new ModelCatalog(registry, makeStorage());

      catalog.refresh();

      expect(catalog.getAll()).toHaveLength(1);
      expect(catalog.getAll()[0].provider).toBe("anthropic");
    });

    it("deduplicates by provider/id", () => {
      const dup = { ...SONNET };
      const registry = makeRegistry([SONNET, dup]);
      const catalog = new ModelCatalog(registry, makeStorage());

      catalog.refresh();

      expect(catalog.getAll()).toHaveLength(1);
    });

    it("sets updatedAt timestamp on success", () => {
      const catalog = new ModelCatalog(makeRegistry([SONNET]), makeStorage());
      expect(catalog.getUpdatedAt()).toBe(0);

      catalog.refresh();

      expect(catalog.getUpdatedAt()).toBeGreaterThan(0);
    });

    it("survives registry throwing", () => {
      const registry = makeRegistry();
      (registry.refresh as ReturnType<typeof vi.fn>).mockImplementation(() => {
        throw new Error("disk on fire");
      });

      const catalog = new ModelCatalog(registry, makeStorage());
      expect(() => catalog.refresh()).not.toThrow();
      expect(catalog.getAll()).toEqual([]);
    });

    it("defaults contextWindow to 200000 when SDK returns 0", () => {
      const noCtx = { ...SONNET, contextWindow: 0 };
      const catalog = new ModelCatalog(makeRegistry([noCtx]), makeStorage());

      catalog.refresh();

      expect(catalog.getAll()[0].contextWindow).toBe(200000);
    });

    it("uses model id as name when SDK name is empty", () => {
      const noName = { ...SONNET, name: "" };
      const catalog = new ModelCatalog(makeRegistry([noName]), makeStorage());

      catalog.refresh();

      expect(catalog.getAll()[0].name).toBe("claude-sonnet-4-20250514");
    });
  });

  describe("getContextWindow", () => {
    function catalogWith(...models: typeof SONNET[]) {
      const catalog = new ModelCatalog(makeRegistry(models), makeStorage());
      catalog.refresh();
      return catalog;
    }

    it("matches by exact canonical id", () => {
      const c = catalogWith(SONNET);
      expect(c.getContextWindow("anthropic/claude-sonnet-4-20250514")).toBe(200000);
    });

    it("matches by tail segment (no provider prefix)", () => {
      const c = catalogWith(GPT);
      expect(c.getContextWindow("gpt-5.3-codex")).toBe(272000);
    });

    it("matches by model name", () => {
      const c = catalogWith(GPT);
      expect(c.getContextWindow("GPT-5.3 Codex")).toBe(272000);
    });

    it("matches by normalized token (case-insensitive, punctuation-stripped)", () => {
      const c = catalogWith(GPT);
      expect(c.getContextWindow("GPT 5.3 Codex")).toBe(272000);
    });

    it("matches by tail suffix (provider/tail → tail)", () => {
      const c = catalogWith(SONNET);
      expect(c.getContextWindow("claude-sonnet-4-20250514")).toBe(200000);
    });

    it("falls back to NNNk suffix parsing", () => {
      const c = catalogWith(SONNET);
      expect(c.getContextWindow("unknown-model-128k")).toBe(128000);
      expect(c.getContextWindow("some-272k-model")).toBe(272000);
    });

    it("returns 200000 as ultimate fallback", () => {
      const c = catalogWith(SONNET);
      expect(c.getContextWindow("totally-unknown")).toBe(200000);
    });

    it("handles empty string", () => {
      const c = catalogWith(SONNET);
      expect(c.getContextWindow("")).toBe(200000);
    });

    it("trims whitespace", () => {
      const c = catalogWith(GPT);
      expect(c.getContextWindow("  gpt-5.3-codex  ")).toBe(272000);
    });

    it("matches large context windows correctly", () => {
      const c = catalogWith(GEMINI);
      expect(c.getContextWindow("gemini-3.0-pro")).toBe(2000000);
    });
  });

  describe("ensureSessionContextWindow", () => {
    it("sets context window when missing", () => {
      const storage = makeStorage();
      const catalog = new ModelCatalog(makeRegistry([GPT]), storage);
      catalog.refresh();

      const session = makeSession({ model: "gpt-5.3-codex", contextWindow: undefined });
      catalog.ensureSessionContextWindow(session);

      expect(session.contextWindow).toBe(272000);
      expect(storage.saveSession).toHaveBeenCalledWith(session);
    });

    it("sets context window when zero", () => {
      const storage = makeStorage();
      const catalog = new ModelCatalog(makeRegistry([GPT]), storage);
      catalog.refresh();

      const session = makeSession({ model: "gpt-5.3-codex", contextWindow: 0 });
      catalog.ensureSessionContextWindow(session);

      expect(session.contextWindow).toBe(272000);
    });

    it("heals stale 200k fallback to correct value", () => {
      const storage = makeStorage();
      const catalog = new ModelCatalog(makeRegistry([GPT]), storage);
      catalog.refresh();

      const session = makeSession({ model: "gpt-5.3-codex", contextWindow: 200000 });
      catalog.ensureSessionContextWindow(session);

      expect(session.contextWindow).toBe(272000);
      expect(storage.saveSession).toHaveBeenCalled();
    });

    it("does not overwrite a correct non-fallback value", () => {
      const storage = makeStorage();
      const catalog = new ModelCatalog(makeRegistry([GPT]), storage);
      catalog.refresh();

      const session = makeSession({ model: "gpt-5.3-codex", contextWindow: 272000 });
      catalog.ensureSessionContextWindow(session);

      expect(session.contextWindow).toBe(272000);
      expect(storage.saveSession).not.toHaveBeenCalled();
    });

    it("does not overwrite a custom value even if different from resolved", () => {
      const storage = makeStorage();
      const catalog = new ModelCatalog(makeRegistry([GPT]), storage);
      catalog.refresh();

      // User set 100000 manually — should be preserved (not 200k fallback)
      const session = makeSession({ model: "gpt-5.3-codex", contextWindow: 100000 });
      catalog.ensureSessionContextWindow(session);

      expect(session.contextWindow).toBe(100000);
      expect(storage.saveSession).not.toHaveBeenCalled();
    });

    it("returns the session for chaining", () => {
      const catalog = new ModelCatalog(makeRegistry([GPT]), makeStorage());
      catalog.refresh();

      const session = makeSession({ model: "gpt-5.3-codex" });
      const result = catalog.ensureSessionContextWindow(session);

      expect(result).toBe(session);
    });
  });

  describe("healPersistedSessionContextWindows", () => {
    it("heals sessions with stale fallback context windows", () => {
      const s1 = makeSession({ id: "s1", model: "gpt-5.3-codex", contextWindow: 200000 });
      const s2 = makeSession({ id: "s2", model: "gpt-5.3-codex", contextWindow: 272000 });
      const s3 = makeSession({ id: "s3", model: "gemini-3.0-pro", contextWindow: undefined });

      const storage = makeStorage([s1, s2, s3]);
      const catalog = new ModelCatalog(makeRegistry([GPT, GEMINI]), storage);
      catalog.refresh();

      catalog.healPersistedSessionContextWindows();

      // s1 healed from 200k → 272k, s3 healed from undefined → 2M
      expect(s1.contextWindow).toBe(272000);
      expect(s3.contextWindow).toBe(2000000);
      // s2 was already correct — not saved
      expect(storage.saveSession).toHaveBeenCalledTimes(2);
    });

    it("does nothing when all sessions are correct", () => {
      const s1 = makeSession({ id: "s1", model: "gpt-5.3-codex", contextWindow: 272000 });
      const storage = makeStorage([s1]);
      const catalog = new ModelCatalog(makeRegistry([GPT]), storage);
      catalog.refresh();

      catalog.healPersistedSessionContextWindows();

      expect(storage.saveSession).not.toHaveBeenCalled();
    });
  });
});
