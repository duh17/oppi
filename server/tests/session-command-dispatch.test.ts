import { beforeEach, describe, expect, it, vi } from "vitest";

import { cmdSession } from "../src/cli/commands/session.js";
import { localApiRequest, type LocalApiConnection } from "../src/cli/local-api-client.js";
import { captureCliOutput } from "../src/cli/output.js";
import { OPPI_CALLER_SESSION_ID_ENV } from "../src/session-caller-identity.js";

vi.mock("../src/cli/local-api-client.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/cli/local-api-client.js")>();
  return { ...actual, localApiRequest: vi.fn() };
});

const request = vi.mocked(localApiRequest);
const storage = {} as LocalApiConnection;

describe("session command dispatch and output boundaries", () => {
  beforeEach(() => {
    request.mockReset();
    process.exitCode = undefined;
  });

  it("forwards trace-page pagination flags and removes redundant session metadata", async () => {
    request
      .mockResolvedValueOnce({ session: { id: "s/1", workspaceId: "ws/1" } })
      .mockResolvedValueOnce({
        session: { id: "s/1" },
        entries: [{ id: "entry" }],
        cursor: "next",
      });

    const { stdout } = await captureCliOutput(() =>
      cmdSession(storage, "trace-page", ["s/1"], {
        cursor: "prev cursor",
        "around-entry": "entry/1",
        "target-events": "50",
        "preview-bytes": "1024",
        json: "true",
      }),
    );

    expect(request).toHaveBeenNthCalledWith(1, storage, "/sessions/s%2F1", undefined);
    expect(request).toHaveBeenNthCalledWith(
      2,
      storage,
      "/workspaces/ws%2F1/sessions/s%2F1/trace-page?cursor=prev+cursor&aroundEntryId=entry%2F1&targetEvents=50&previewBytes=1024",
      undefined,
    );
    expect(JSON.parse(stdout)).toEqual({
      ok: true,
      data: { entries: [{ id: "entry" }], cursor: "next", session_id: "s/1" },
    });
  });

  it("keeps list JSON compact when the API returns partial rows", async () => {
    request.mockResolvedValue({
      sessions: [{ id: "s", status: "busy", lastModified: 5 }, { name: "partial" }],
    });

    const { stdout } = await captureCliOutput(() =>
      cmdSession(storage, "list", [], { json: "true" }),
    );

    const envelope = JSON.parse(stdout) as { data: { sessions: Array<Record<string, unknown>> } };
    expect(envelope.data.sessions).toHaveLength(2);
    expect(envelope.data.sessions[0]).toMatchObject({
      id: "s",
      status: "busy",
      last_activity: 5,
      pending_asks: 0,
    });
    expect(envelope.data.sessions[1]).toMatchObject({ id: null, name: "partial" });
  });

  it("waits for any of several session ids by default", async () => {
    request.mockImplementation(async (_storage, path) => {
      if (path.includes("/sessions/a/events")) {
        return { session: { status: "busy" }, events: [], currentSeq: 1 };
      }
      if (path.includes("/sessions/b/events")) {
        return {
          session: { status: "ready", lastMessage: "done" },
          events: [],
          currentSeq: 2,
        };
      }
      throw new Error(`unexpected path ${path}`);
    });

    const { stdout, exitCode } = await captureCliOutput(() =>
      cmdSession(storage, "wait", ["a", "b"], { for: "idle", json: "true", timeout: "1s" }),
    );

    expect(exitCode).toBe(0);
    expect(JSON.parse(stdout)).toMatchObject({
      ok: true,
      data: { session_id: "b", reason: "idle", status: "ready" },
    });
  });

  it("waits until every session is idle when --all is set", async () => {
    request.mockImplementation(async (_storage, path) => {
      if (path.includes("/sessions/a/events") || path.includes("/sessions/b/events")) {
        return { session: { status: "ready" }, events: [], currentSeq: 1 };
      }
      throw new Error(`unexpected path ${path}`);
    });

    const { stdout, exitCode } = await captureCliOutput(() =>
      cmdSession(storage, "wait", ["a", "b"], {
        for: "idle",
        all: "true",
        json: "true",
        timeout: "1s",
      }),
    );

    expect(exitCode).toBe(0);
    expect(JSON.parse(stdout)).toMatchObject({
      ok: true,
      data: {
        condition: "idle",
        sessions: [{ session_id: "a", status: "ready" }, { session_id: "b", status: "ready" }],
      },
    });
  });

  it("rejects duplicate wait session ids", async () => {
    const { stdout, exitCode } = await captureCliOutput(() =>
      cmdSession(storage, "wait", ["a", "a"], { json: "true" }),
    );

    expect(exitCode).toBe(1);
    expect(JSON.parse(stdout)).toMatchObject({
      ok: false,
      error: { message: "session ids must be unique" },
    });
    expect(request).not.toHaveBeenCalled();
  });

  it("maps malformed API failures to a stable nonzero JSON envelope", async () => {
    request.mockRejectedValue(Object.assign(new Error("bad response"), { status: 502 }));

    const { stdout, exitCode } = await captureCliOutput(() =>
      cmdSession(storage, "get", ["s"], { json: "true" }),
    );

    expect(exitCode).toBe(1);
    expect(process.exitCode).toBeUndefined();
    expect(JSON.parse(stdout)).toEqual({
      ok: false,
      error: { message: "bad response", status: 502 },
    });
  });

  it.each([
    {
      action: "inspect",
      positional: ["s"],
      flags: { turn: "1", turns: "2", json: "true" },
      message: "Conflicting flags: --turn and --turns",
    },
    {
      action: "search",
      positional: ["text"],
      flags: { workspace: "ws", all: "true", json: "true" },
      message: "--workspace and --all cannot be used together",
    },
    {
      action: "inspect",
      positional: ["s"],
      flags: { limit: "2", json: "true" },
      message: "Unsupported flag for 'session inspect': --limit",
    },
    {
      action: "wait",
      positional: ["s"],
      flags: { poll: "2s", interval: "2s", json: "true" },
      message: "Conflicting flags: --interval and --poll",
    },
  ])(
    "rejects conflicting command input: $action",
    async ({ action, positional, flags, message }) => {
      const { stdout, exitCode } = await captureCliOutput(() =>
        cmdSession(storage, action, positional, flags),
      );

      expect(exitCode).toBe(1);
      expect(process.exitCode).toBeUndefined();
      const envelope = JSON.parse(stdout) as { ok: boolean; error: { message: string } };
      expect(envelope.ok).toBe(false);
      expect(envelope.error.message).toContain(message);
      expect(request).not.toHaveBeenCalled();
    },
  );

  it("attributes create prompts with the caller session id", async () => {
    request
      .mockResolvedValueOnce({ workspace: { id: "ws-1", name: "Oppi" } })
      .mockResolvedValueOnce({ session: { id: "child-1", workspaceId: "ws-1" } });

    await captureCliOutput(() =>
      cmdSession(
        storage,
        "create",
        [],
        {
          workspace: "ws-1",
          prompt: "This is a message: Own the remaining review findings.",
          json: "true",
        },
        process.cwd(),
        { callerSessionId: "parent-1" },
      ),
    );

    expect(request).toHaveBeenNthCalledWith(2, storage, "/workspaces/ws-1/sessions", {
      method: "POST",
      body: {
        prompt: "This is a message from session parent-1: Own the remaining review findings.",
        parentSessionId: "parent-1",
      },
    });
  });

  it("leaves unaffiliated create prompts unchanged", async () => {
    request
      .mockResolvedValueOnce({ workspace: { id: "ws-1", name: "Oppi" } })
      .mockResolvedValueOnce({ session: { id: "child-1", workspaceId: "ws-1" } });

    await withCallerSessionEnv(undefined, async () => {
      await captureCliOutput(() =>
        cmdSession(storage, "create", [], {
          workspace: "ws-1",
          prompt: "Inspect the failing CLI test",
          json: "true",
        }),
      );
    });

    expect(request).toHaveBeenNthCalledWith(2, storage, "/workspaces/ws-1/sessions", {
      method: "POST",
      body: { prompt: "Inspect the failing CLI test" },
    });
  });

  it("attributes send text with the caller session id", async () => {
    request.mockResolvedValue({ messages: [] });

    await captureCliOutput(() =>
      cmdSession(
        storage,
        "send",
        ["child-1"],
        { text: "This is a message: Focus on the failing test", json: "true" },
        process.cwd(),
        { callerSessionId: "parent-1" },
      ),
    );

    expect(request).toHaveBeenCalledWith(storage, "/sessions/child-1/command", {
      method: "POST",
      body: {
        type: "prompt",
        message: "This is a message from session parent-1: Focus on the failing test",
        streamingBehavior: "steer",
      },
    });
  });

  it("leaves unaffiliated send text unchanged", async () => {
    request.mockResolvedValue({ messages: [] });

    await withCallerSessionEnv(undefined, async () => {
      await captureCliOutput(() =>
        cmdSession(storage, "send", ["child-1"], {
          text: "Focus on the failing test",
          json: "true",
        }),
      );
    });

    expect(request).toHaveBeenCalledWith(storage, "/sessions/child-1/command", {
      method: "POST",
      body: {
        type: "prompt",
        message: "Focus on the failing test",
        streamingBehavior: "steer",
      },
    });
  });

  it("posts workspace tool policy from Pi create flags", async () => {
    request
      .mockResolvedValueOnce({ workspace: { id: "ws-1", name: "Oppi" } })
      .mockResolvedValueOnce({ session: { id: "child-1", workspaceId: "ws-1" } });

    await withCallerSessionEnv(undefined, async () => {
      await captureCliOutput(() =>
        cmdSession(storage, "create", [], {
          workspace: "ws-1",
          prompt: "Inspect the repo",
          tools: "read, grep",
          "exclude-tools": "bash",
          "no-builtin-tools": "true",
          json: "true",
        }),
      );
    });

    expect(request).toHaveBeenNthCalledWith(2, storage, "/workspaces/ws-1/sessions", {
      method: "POST",
      body: {
        prompt: "Inspect the repo",
        tools: ["read", "grep"],
        excludeTools: ["bash"],
        noTools: "builtin",
      },
    });
  });

  it("posts saved-Agent overrides for tools and thinking", async () => {
    request
      .mockResolvedValueOnce({ workspace: { id: "ws-1", name: "Oppi" } })
      .mockResolvedValueOnce({ session: { id: "child-1", workspaceId: "ws-1" } });

    await withCallerSessionEnv(undefined, async () => {
      await captureCliOutput(() =>
        cmdSession(storage, "create", [], {
          agent: "reviewer",
          workspace: "ws-1",
          prompt: "Review this",
          tools: "read",
          thinking: "high",
          json: "true",
        }),
      );
    });

    expect(request).toHaveBeenNthCalledWith(2, storage, "/agents/reviewer/sessions", {
      method: "POST",
      body: {
        prompt: { text: "Review this" },
        target: { workspaceId: "ws-1" },
        overrides: {
          tools: ["read"],
          thinkingLevel: "high",
        },
      },
    });
  });

  it("applies --model :thinking and lets --thinking win", async () => {
    request
      .mockResolvedValueOnce({ workspace: { id: "ws-1", name: "Oppi" } })
      .mockResolvedValueOnce({
        models: [
          {
            id: "openai/gpt-5.3-codex",
            name: "GPT-5.3 Codex",
            provider: "openai",
          },
        ],
      })
      .mockResolvedValueOnce({ session: { id: "suffix-1", workspaceId: "ws-1" } })
      .mockResolvedValueOnce({ workspace: { id: "ws-1", name: "Oppi" } })
      .mockResolvedValueOnce({
        models: [
          {
            id: "openai/gpt-5.3-codex",
            name: "GPT-5.3 Codex",
            provider: "openai",
          },
        ],
      })
      .mockResolvedValueOnce({ session: { id: "override-1", workspaceId: "ws-1" } });

    await withCallerSessionEnv(undefined, async () => {
      await captureCliOutput(() =>
        cmdSession(storage, "create", [], {
          workspace: "ws-1",
          prompt: "suffix only",
          model: "gpt-5.3-codex:high",
          json: "true",
        }),
      );
      await captureCliOutput(() =>
        cmdSession(storage, "create", [], {
          workspace: "ws-1",
          prompt: "explicit thinking wins",
          model: "gpt-5.3-codex:high",
          thinking: "low",
          json: "true",
        }),
      );
    });

    expect(request).toHaveBeenNthCalledWith(3, storage, "/workspaces/ws-1/sessions", {
      method: "POST",
      body: {
        prompt: "suffix only",
        model: "openai/gpt-5.3-codex",
        thinking: "high",
      },
    });
    expect(request).toHaveBeenNthCalledWith(6, storage, "/workspaces/ws-1/sessions", {
      method: "POST",
      body: {
        prompt: "explicit thinking wins",
        model: "openai/gpt-5.3-codex",
        thinking: "low",
      },
    });
  });

  it("rejects combining --no-tools with --no-builtin-tools", async () => {
    const { stdout, exitCode } = await captureCliOutput(() =>
      cmdSession(storage, "create", [], {
        workspace: "ws-1",
        prompt: "nope",
        "no-tools": "true",
        "no-builtin-tools": "true",
        json: "true",
      }),
    );

    expect(exitCode).toBe(1);
    expect(JSON.parse(stdout)).toMatchObject({
      ok: false,
      error: { message: "--no-tools and --no-builtin-tools cannot be used together" },
    });
    expect(request).not.toHaveBeenCalled();
  });

  it("uses the human output callback for an empty list", async () => {
    request.mockResolvedValue({ sessions: [] });
    const log = vi.spyOn(console, "log").mockImplementation(() => {});

    await cmdSession(storage, "list", [], {});

    expect(log.mock.calls.flat().join("\n")).toContain("Sessions (0)");
    expect(log.mock.calls.flat().join("\n")).toContain("No sessions found.");
    log.mockRestore();
  });
});

async function withCallerSessionEnv(
  callerSessionId: string | undefined,
  run: () => Promise<void>,
): Promise<void> {
  const previous = process.env[OPPI_CALLER_SESSION_ID_ENV];
  if (callerSessionId === undefined) {
    delete process.env[OPPI_CALLER_SESSION_ID_ENV];
  } else {
    process.env[OPPI_CALLER_SESSION_ID_ENV] = callerSessionId;
  }
  try {
    await run();
  } finally {
    if (previous === undefined) {
      delete process.env[OPPI_CALLER_SESSION_ID_ENV];
    } else {
      process.env[OPPI_CALLER_SESSION_ID_ENV] = previous;
    }
  }
}
