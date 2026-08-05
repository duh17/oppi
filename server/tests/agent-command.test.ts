import { beforeEach, describe, expect, it, vi } from "vitest";

import { cmdAgent } from "../src/cli/commands/agent.js";
import { parseCliArgs } from "../src/cli/args.js";
import { localApiRequest, type LocalApiConnection } from "../src/cli/local-api-client.js";
import { resolveHelpTopic, renderHelpTopic } from "../src/cli/help.js";
import { captureCliOutput } from "../src/cli/output.js";

vi.mock("../src/cli/local-api-client.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/cli/local-api-client.js")>();
  return { ...actual, localApiRequest: vi.fn() };
});

const storage = {} as LocalApiConnection;
const request = vi.mocked(localApiRequest);
const response = {
  agents: [
    {
      id: "agent-1",
      name: "Sensei",
      icon: { kind: "emoji", value: "🧘" },
      status: "active",
      version: 2,
      createdAt: 1,
      updatedAt: 2,
    },
  ],
};

describe("agent command", () => {
  beforeEach(() => {
    request.mockReset();
    request.mockResolvedValue(response);
  });

  it("shows saved icons in human list output", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    try {
      await cmdAgent(storage, "list", [], {});
      expect(log.mock.calls.flat().join("\n")).toContain("icon emoji 🧘");
    } finally {
      log.mockRestore();
    }
  });

  it("preserves saved icons in JSON list output", async () => {
    const { stdout } = await captureCliOutput(() =>
      cmdAgent(storage, "list", [], { json: "true" }),
    );

    expect(JSON.parse(stdout)).toMatchObject({
      ok: true,
      data: { agents: [{ id: "agent-1", icon: { kind: "emoji", value: "🧘" } }] },
    });
  });

  it("threads expected version through Agent update", async () => {
    request.mockResolvedValueOnce({
      agent: { id: "agent-1", name: "Sensei", version: 4 },
    } as never);

    await captureCliOutput(() =>
      cmdAgent(storage, "update", ["agent-1"], {
        json: "true",
        "definition-json": JSON.stringify({ description: "Updated" }),
        "expected-version": "3",
      }),
    );

    expect(request).toHaveBeenCalledWith(storage, "/agents/agent-1?expectedVersion=3", {
      method: "PATCH",
      body: { description: "Updated" },
    });
  });

  it("preserves structured Agent version conflicts in JSON errors", async () => {
    request.mockRejectedValueOnce(
      Object.assign(new Error("Agent version conflict: expected 3, current 4"), {
        status: 409,
        code: "AGENT_VERSION_CONFLICT",
        expectedVersion: 3,
        currentVersion: 4,
      }),
    );

    const captured = await captureCliOutput(() =>
      cmdAgent(storage, "update", ["agent-1"], {
        json: "true",
        "definition-json": JSON.stringify({ description: "Updated" }),
        "expected-version": "3",
      }),
    );

    expect(captured.exitCode).toBe(1);
    expect(JSON.parse(captured.stdout)).toEqual({
      ok: false,
      error: {
        message: "Agent version conflict: expected 3, current 4",
        status: 409,
        code: "AGENT_VERSION_CONFLICT",
        expectedVersion: 3,
        currentVersion: 4,
      },
    });
  });

  it("does not forward unrelated API error codes as Agent conflict fields", async () => {
    request.mockRejectedValueOnce(
      Object.assign(new Error("connect failed"), { status: 500, code: "ECONNREFUSED" }),
    );

    const captured = await captureCliOutput(() =>
      cmdAgent(storage, "update", ["agent-1"], {
        json: "true",
        "definition-json": JSON.stringify({ description: "Updated" }),
      }),
    );

    expect(JSON.parse(captured.stdout)).toEqual({
      ok: false,
      error: { message: "connect failed", status: 500 },
    });
  });

  it.each(["", "true", "0", "-1", "1.5", "9007199254740992"])(
    "rejects malformed --expected-version value %s",
    async (expectedVersion) => {
      const captured = await captureCliOutput(() =>
        cmdAgent(storage, "update", ["agent-1"], {
          json: "true",
          "definition-json": JSON.stringify({ description: "Updated" }),
          "expected-version": expectedVersion,
        }),
      );

      expect(captured.exitCode).toBe(1);
      expect(JSON.parse(captured.stdout)).toMatchObject({
        ok: false,
        error: { message: "--expected-version must be a positive safe integer" },
      });
      expect(request).not.toHaveBeenCalled();
    },
  );

  it("rejects the parser's --expected-version=3 key instead of omitting CAS", async () => {
    const parsed = parseCliArgs([
      "agent",
      "update",
      "agent-1",
      "--definition-json",
      JSON.stringify({ description: "Updated" }),
      "--expected-version=3",
      "--json",
    ]);
    expect(parsed.flags["expected-version=3"]).toBe("true");

    const captured = await captureCliOutput(() =>
      cmdAgent(storage, parsed.positional[0], parsed.positional.slice(1), parsed.flags),
    );

    expect(captured.exitCode).toBe(1);
    expect(JSON.parse(captured.stdout)).toMatchObject({
      ok: false,
      error: { message: "Use --expected-version <version>; equals form is not supported" },
    });
    expect(request).not.toHaveBeenCalled();
  });

  it("pins Agent update expected-version help", () => {
    const topic = resolveHelpTopic(["agent", "update"]);
    expect(topic).toBeDefined();
    if (!topic) return;

    const rendered = renderHelpTopic(topic);
    expect(topic.usage).toContain("[--expected-version <version>]");
    expect(topic.flags).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ name: "--expected-version", value: "<version>" }),
      ]),
    );
    expect(rendered).toContain("Omit --expected-version for a compatible unconditional PATCH.");
    expect(rendered).toContain("--expected-version 3 --json");
  });
});
