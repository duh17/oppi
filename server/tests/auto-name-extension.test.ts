import { readFileSync } from "node:fs";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Api, AssistantMessage, Model } from "@earendil-works/pi-ai";

import {
  autoName,
  chooseModel,
  normalizeTitle,
  pickSmallModel,
  readConfig,
  TITLE_INSTRUCTIONS,
  type AutoNameJob,
  type TitleModels,
} from "../../pi-extensions/auto-name/core.js";
import autoNameExtension from "../../pi-extensions/auto-name/index.js";

// ─── The title contract (pi-extensions/auto-name/session-title.json) ───

interface TitleContract {
  instructions: string;
  prompts: Array<{ name: string; firstMessage: string; prompt: string }>;
  normalize: Array<{ name: string; raw: string; expected: string | null }>;
}

const contract = JSON.parse(
  readFileSync(
    new URL("../../pi-extensions/auto-name/session-title.json", import.meta.url),
    "utf8",
  ),
) as TitleContract;

describe("title contract", () => {
  it("sends the contract's instructions", () => {
    expect(TITLE_INSTRUCTIONS).toBe(contract.instructions);
  });

  it.each(contract.normalize)("normalizes: $name", ({ raw, expected }) => {
    expect(normalizeTitle(raw)).toBe(expected);
  });

  it.each(contract.prompts)("prompts the model with the first message: $name", async (entry) => {
    const complete = vi.fn(async () => reply("Fix Bug"));
    await autoName(job({ models: models({ complete }), firstMessage: entry.firstMessage }));

    // Short contract messages are skipped before the model is asked.
    if (entry.firstMessage.trim().length < 15) return expect(complete).not.toHaveBeenCalled();
    const [, context] = complete.mock.calls[0] as unknown as [
      unknown,
      { systemPrompt: string; messages: unknown[] },
    ];
    expect(context.systemPrompt).toBe(contract.instructions);
    expect(context.messages).toHaveLength(1);
    expect(context.messages[0]).toMatchObject({ role: "user", content: entry.prompt });
  });
});

// ─── The job ───

function model(overrides: Partial<Model<Api>> & { id: string }): Model<Api> {
  return {
    provider: "anthropic",
    name: overrides.id,
    api: "anthropic-messages",
    baseUrl: "",
    reasoning: false,
    input: ["text"],
    cost: { input: 1, output: 5, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 100_000,
    maxTokens: 8_000,
    ...overrides,
  } as Model<Api>;
}

function reply(
  text: string,
  stopReason: AssistantMessage["stopReason"] = "stop",
): AssistantMessage {
  return { role: "assistant", content: [{ type: "text", text }], stopReason } as AssistantMessage;
}

const HAIKU = model({
  id: "claude-haiku-5",
  cost: { input: 1, output: 5, cacheRead: 0, cacheWrite: 0 },
});
const SONNET = model({
  id: "claude-sonnet-5",
  cost: { input: 3, output: 15, cacheRead: 0, cacheWrite: 0 },
});

function models(overrides: Partial<TitleModels> = {}): TitleModels {
  const catalog = [HAIKU, SONNET];
  return {
    find: (provider, id) => catalog.find((m) => m.provider === provider && m.id === id),
    available: () => catalog,
    complete: async () => reply("Fix WebSocket Reconnect Drift"),
    ...overrides,
  };
}

/** A job over an unnamed session. `names` collects what the job set. */
function job(overrides: Partial<AutoNameJob> & { names?: string[] } = {}): AutoNameJob {
  const { names = [], ...rest } = overrides;
  let name: string | undefined;
  return {
    models: models(),
    firstMessage: "fix the websocket reconnect state drift",
    session: { provider: "anthropic", id: "claude-sonnet-5" },
    currentName: () => name,
    setName: (title) => {
      name = title;
      names.push(title);
    },
    warn: () => {},
    config: {},
    ...rest,
  };
}

describe("autoName", () => {
  it("names an unnamed session with the model's normalized title", async () => {
    const names: string[] = [];
    await autoName(
      job({ names, models: models({ complete: async () => reply('Title: "Fix Drift."') }) }),
    );
    expect(names).toEqual(["Fix Drift"]);
  });

  it("never overwrites a name set while the title was generating", async () => {
    const names: string[] = [];
    let named: string | undefined;
    await autoName(
      job({
        names,
        currentName: () => named,
        models: models({
          complete: async () => {
            named = "Set By The User"; // the user renames while the model works
            return reply("Fix Drift");
          },
        }),
      }),
    );
    expect(names).toEqual([]);
  });

  it("asks nothing of a session that already has a name", async () => {
    const complete = vi.fn(async () => reply("Fix Drift"));
    await autoName(job({ currentName: () => "Mine", models: models({ complete }) }));
    expect(complete).not.toHaveBeenCalled();
  });

  it("leaves a first message too short to title unnamed, without asking the model", async () => {
    const complete = vi.fn(async () => reply("Hello"));
    await autoName(job({ firstMessage: "hi there", models: models({ complete }) }));
    expect(complete).not.toHaveBeenCalled();
  });

  it.each([
    [
      "a reply that runs out of tokens (the model answered)",
      () => reply("I can't see the attach", "length"),
    ],
    ["a reply with no text", () => reply("")],
  ])("fails quietly on %s", async (_name, response) => {
    const names: string[] = [];
    const warn = vi.fn();
    await autoName(job({ names, warn, models: models({ complete: async () => response() }) }));
    expect(names).toEqual([]);
    expect(warn).toHaveBeenCalledTimes(1);
  });

  it("fails quietly when the model request throws", async () => {
    const warn = vi.fn();
    await autoName(
      job({
        warn,
        models: models({
          complete: async () => {
            throw new Error("401 unauthorized");
          },
        }),
      }),
    );
    expect(warn).toHaveBeenCalledWith("401 unauthorized");
  });

  it("does not fall back to another model when the configured one is missing", async () => {
    const complete = vi.fn(async () => reply("Fix Drift"));
    const warn = vi.fn();
    await autoName(
      job({ warn, config: { model: "anthropic/gone" }, models: models({ complete }) }),
    );
    expect(complete).not.toHaveBeenCalled();
    expect(warn).toHaveBeenCalledWith("model anthropic/gone is not available");
  });

  it("asks the configured model", async () => {
    const complete = vi.fn(async () => reply("Fix Drift"));
    await autoName(
      job({ config: { model: "anthropic/claude-sonnet-5" }, models: models({ complete }) }),
    );
    expect(complete.mock.calls[0]?.[0]).toBe(SONNET);
  });
});

const ANTHROPIC_SESSION = { provider: "anthropic", id: "claude-sonnet-5" };

describe("default model", () => {
  it("is a small model of the session's provider, not the session's own", async () => {
    expect(
      await chooseModel(models(), undefined, { provider: "anthropic", id: "claude-sonnet-5" }),
    ).toBe(HAIKU);
  });

  it("prefers a non-reasoning small model, then the cheapest", () => {
    const thinker = model({
      id: "mini-thinker",
      reasoning: true,
      cost: { input: 0.1, output: 0.1, cacheRead: 0, cacheWrite: 0 },
    });
    const cheap = model({
      id: "flash-cheap",
      cost: { input: 0.2, output: 0.5, cacheRead: 0, cacheWrite: 0 },
    });
    expect(pickSmallModel([thinker, HAIKU, cheap, SONNET], ANTHROPIC_SESSION)).toBe(cheap);
    expect(pickSmallModel([thinker], ANTHROPIC_SESSION)).toBe(thinker);
  });

  it("never picks another provider's model", () => {
    const local = model({
      id: "mini",
      provider: "omlx",
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    });
    expect(pickSmallModel([local, SONNET], ANTHROPIC_SESSION)).toBeUndefined();
  });

  it("falls back to the session's own model when its provider has no small one", async () => {
    const only = models({ available: () => [SONNET] });
    expect(
      await chooseModel(only, undefined, { provider: "anthropic", id: "claude-sonnet-5" }),
    ).toBe(SONNET);
  });

  it("has no model without a configured one or a session model", async () => {
    expect(await chooseModel(models(), undefined, undefined)).toMatchObject({
      problem: expect.any(String),
    });
  });
  it("matches a size word as a whole part of the id, and skips batch variants", () => {
    const notSmall = model({ id: "minimax-m2" });
    const batch = model({ id: "claude-haiku-5:batch" });
    const nova = model({ id: "nova-lite-v1" });
    expect(pickSmallModel([notSmall, batch], ANTHROPIC_SESSION)).toBeUndefined();
    expect(pickSmallModel([notSmall, batch, nova], ANTHROPIC_SESSION)).toBe(nova);
  });

  it("skips models that take the same id shape but are not for a title", () => {
    const image = model({ id: "gemini-3.1-flash-lite-image" });
    const live = model({ id: "gemini-3.1-flash-live-preview" });
    expect(pickSmallModel([image, live], ANTHROPIC_SESSION)).toBeUndefined();
  });

  it("names nothing, with a pointer to auto-name.json, for a provider that cannot title by default", async () => {
    const result = await chooseModel(models(), undefined, {
      provider: "openai-codex",
      id: "gpt-6-sol",
    });
    expect(result).toMatchObject({ problem: expect.stringContaining("auto-name.json") });
    // A model the user names is still used.
    expect(
      await chooseModel(models(), "anthropic/claude-haiku-5", {
        provider: "openai-codex",
        id: "gpt-6-sol",
      }),
    ).toBe(HAIKU);
  });
});

// The default over pi-ai's own catalogs, which is what a real session's registry lists.
describe("default model over pi-ai's catalogs", () => {
  async function catalog(file: string, exportName: string): Promise<Model<Api>[]> {
    const module = (await import(`@earendil-works/pi-ai/providers/${file}.models`)) as Record<
      string,
      Record<string, Model<Api>>
    >;
    return Object.values(module[exportName] as Record<string, Model<Api>>);
  }

  it("is a Haiku for an Anthropic session", async () => {
    const picked = pickSmallModel(await catalog("anthropic", "ANTHROPIC_MODELS"), {
      provider: "anthropic",
      id: "claude-sonnet-5",
    });
    expect(picked?.id).toMatch(/haiku/);
  });

  it("is a Flash-Lite for a Google session, never an image or live model", async () => {
    const picked = pickSmallModel(await catalog("google", "GOOGLE_MODELS"), {
      provider: "google",
      id: "gemini-3.1-pro-preview",
    });
    expect(picked?.id).toMatch(/flash-lite/);
    expect(picked?.id).not.toMatch(/image|live/);
  });

  it("is a cheap non-reasoning mini or nano for an OpenAI session", async () => {
    const picked = pickSmallModel(await catalog("openai", "OPENAI_MODELS"), {
      provider: "openai",
      id: "gpt-5.5",
    });
    expect(picked?.id).toMatch(/mini|nano/);
    expect(picked?.reasoning).toBe(false);
  });

  it("stays with the session model's vendor on OpenRouter, and never takes a :batch variant", async () => {
    const openrouter = await catalog("openrouter", "OPENROUTER_MODELS");
    const claude = pickSmallModel(openrouter, {
      provider: "openrouter",
      id: "anthropic/claude-sonnet-5",
    });
    expect(claude?.id).toMatch(/^~?anthropic\/.*haiku/);
    expect(claude?.id).not.toContain(":batch");

    const mistral = openrouter.find((m) => m.id.startsWith("mistralai/"));
    if (mistral) {
      const picked = pickSmallModel(openrouter, { provider: "openrouter", id: mistral.id });
      expect(picked === undefined || picked.id.startsWith("mistralai/")).toBe(true);
    }
    // A vendor with no small model gets none, not another vendor's.
    const withoutSmallClaude = openrouter.filter(
      (m) => !(/^~?anthropic\//.test(m.id) && SMALL.test(m.id)),
    );
    expect(
      pickSmallModel(withoutSmallClaude, { provider: "openrouter", id: "anthropic/claude-opus-5" }),
    ).toBeUndefined();
  });

  it("has no default for an OpenAI Codex session, and says to set auto-name.json", async () => {
    const codex = await catalog("openai-codex", "OPENAI_CODEX_MODELS");
    const result = await chooseModel(
      models({
        available: () => codex,
        find: (provider, id) => codex.find((m) => m.provider === provider && m.id === id),
      }),
      undefined,
      { provider: "openai-codex", id: "gpt-6-sol" },
    );
    expect(result).toMatchObject({ problem: expect.stringContaining("auto-name.json") });
  });
});

const SMALL = /(^|[-/.:])(haiku|flash|mini|nano|lite|small)($|[-/.:])/i;

describe("config file", () => {
  let dir: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "auto-name-config-"));
  });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it("reads the model from auto-name.json", () => {
    writeFileSync(
      join(dir, "auto-name.json"),
      JSON.stringify({ model: " anthropic/claude-haiku-5 " }),
    );
    expect(readConfig(dir)).toEqual({ model: "anthropic/claude-haiku-5" });
  });

  it.each([
    "not json",
    JSON.stringify({ model: 3 }),
    JSON.stringify({ model: " " }),
    JSON.stringify(null),
  ])("treats %s as the default configuration", (content) => {
    writeFileSync(join(dir, "auto-name.json"), content);
    expect(readConfig(dir)).toEqual({});
  });

  it("treats a missing file as the default configuration", () => {
    expect(readConfig(dir)).toEqual({});
  });
});

// ─── The classic entry ───

type Handler = (event: unknown, ctx: unknown) => unknown;

/** The extension loaded into a stand-in for Pi, with a session whose name and history the test sets. */
function classic(
  options: {
    name?: string;
    history?: unknown[];
    mode?: string;
    complete?: TitleModels["complete"];
  } = {},
) {
  const handlers = new Map<string, Handler>();
  const state = { name: options.name, history: options.history ?? [] };
  const pi = {
    on: (event: string, handler: Handler) => handlers.set(event, handler),
    getSessionName: () => state.name,
    setSessionName: vi.fn((name: string) => {
      state.name = name;
    }),
  };
  const notify = vi.fn();
  const registry = {
    find: (provider: string, id: string) =>
      provider === "anthropic" && id === "claude-haiku-5" ? HAIKU : undefined,
    getAvailable: () => [HAIKU, SONNET],
    streamSimple: (selected: Model<Api>, context: unknown, opts: unknown) => ({
      result: () =>
        (options.complete ?? (async () => reply("Fix WebSocket Reconnect Drift")))(
          selected,
          context as never,
          opts as never,
        ),
    }),
  };
  const ctx = {
    mode: options.mode ?? "rpc",
    ui: { notify },
    model: SONNET,
    modelRegistry: registry,
    sessionManager: { getBranch: () => state.history },
  };
  autoNameExtension(pi as never);
  const start = () =>
    handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, ctx);
  const prompt = (text: string, messageType = "user") =>
    handlers.get("before_agent_start")?.(
      { type: "before_agent_start", messageType, prompt: text },
      ctx,
    );
  const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
  return { pi, state, notify, start, prompt, settle };
}

const FIRST = "fix the websocket reconnect state drift";

describe("classic entry", () => {
  // The entry reads auto-name.json at each title: keep it away from the real ~/.pi/agent.
  let agentDir: string;
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  beforeEach(() => {
    agentDir = mkdtempSync(join(tmpdir(), "auto-name-agent-"));
    process.env.PI_CODING_AGENT_DIR = agentDir;
  });
  afterEach(() => {
    rmSync(agentDir, { recursive: true, force: true });
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
  });

  it("names an unnamed session on its first message without holding the turn", async () => {
    const { pi, prompt, settle, state } = classic();
    expect(prompt(FIRST)).toBeUndefined();
    await settle();
    expect(pi.setSessionName).toHaveBeenCalledExactlyOnceWith("Fix WebSocket Reconnect Drift");
    expect(state.name).toBe("Fix WebSocket Reconnect Drift");
  });

  it("names a session once", async () => {
    const { pi, prompt, settle, state } = classic();
    prompt(FIRST);
    await settle();
    state.history = [{ type: "message", message: { role: "user" } }];
    prompt("and also the heartbeat timer please");
    await settle();
    expect(pi.setSessionName).toHaveBeenCalledTimes(1);
  });

  it("leaves a named session alone", async () => {
    const { pi, prompt, settle } = classic({ name: "Mine" });
    prompt(FIRST);
    await settle();
    expect(pi.setSessionName).not.toHaveBeenCalled();
  });

  it("leaves a resumed session that already has messages alone", async () => {
    const { pi, prompt, settle } = classic({
      history: [{ type: "message", message: { role: "user" } }],
    });
    prompt(FIRST);
    await settle();
    expect(pi.setSessionName).not.toHaveBeenCalled();
  });

  it("does not name from a custom message", async () => {
    const { pi, prompt, settle } = classic();
    prompt(FIRST, "custom");
    await settle();
    expect(pi.setSessionName).not.toHaveBeenCalled();
  });

  it("does not overwrite a name set during generation", async () => {
    let rename: () => void = () => {};
    const slow = classic({
      complete: async () => {
        rename();
        return reply("Fix Drift");
      },
    });
    rename = () => {
      slow.state.name = "Set By Another Extension";
    };
    slow.prompt(FIRST);
    await slow.settle();
    expect(slow.pi.setSessionName).not.toHaveBeenCalled();
    expect(slow.state.name).toBe("Set By Another Extension");
  });

  it("logs a failure once to stderr and names nothing", async () => {
    const warn = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    const failing = classic({ complete: async () => reply("", "length") });
    failing.prompt(FIRST);
    await failing.settle();
    expect(failing.pi.setSessionName).not.toHaveBeenCalled();
    expect(warn).toHaveBeenCalledTimes(1);
    expect(failing.notify).not.toHaveBeenCalled();
    warn.mockRestore();
  });

  it("gives terminal Pi one muted notice instead of stderr output", async () => {
    const warn = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    const failing = classic({ mode: "tui", complete: async () => reply("", "length") });
    failing.prompt(FIRST);
    await failing.settle();
    expect(failing.notify).toHaveBeenCalledTimes(1);
    expect(warn).not.toHaveBeenCalled();
    warn.mockRestore();
  });
});
