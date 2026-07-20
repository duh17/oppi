import { beforeEach, describe, expect, it, vi } from "vitest";

import { cmdAgent } from "../src/cli/commands/agent.js";
import { localApiRequest, type LocalApiConnection } from "../src/cli/local-api-client.js";
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
      icon: "🧘",
      status: "active",
      version: 2,
      createdAt: 1,
      updatedAt: 2,
    },
  ],
};

describe("agent list command", () => {
  beforeEach(() => {
    request.mockReset();
    request.mockResolvedValue(response);
  });

  it("shows saved icons in human list output", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    try {
      await cmdAgent(storage, "list", [], {});
      expect(log.mock.calls.flat().join("\n")).toContain("icon 🧘");
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
      data: { agents: [{ id: "agent-1", icon: "🧘" }] },
    });
  });
});
