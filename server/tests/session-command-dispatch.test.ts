import { beforeEach, describe, expect, it, vi } from "vitest";

import { cmdSession } from "../src/cli/commands/session.js";
import { localApiRequest, type LocalApiConnection } from "../src/cli/local-api-client.js";
import { captureCliOutput } from "../src/cli/output.js";

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

  it("maps malformed API failures to a stable nonzero JSON envelope", async () => {
    request.mockRejectedValue(Object.assign(new Error("bad response"), { status: 502 }));

    const { stdout } = await captureCliOutput(() =>
      cmdSession(storage, "get", ["s"], { json: "true" }),
    );

    expect(process.exitCode).toBe(1);
    expect(JSON.parse(stdout)).toEqual({
      ok: false,
      error: { message: "bad response", status: 502 },
    });
  });

  it.each([
    {
      action: "diff",
      positional: ["s", "file.ts"],
      flags: { path: "other.ts", json: "true" },
      message: "Conflicting path inputs",
    },
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
  ])(
    "rejects conflicting command input: $action",
    async ({ action, positional, flags, message }) => {
      const { stdout } = await captureCliOutput(() =>
        cmdSession(storage, action, positional, flags),
      );

      expect(process.exitCode).toBe(1);
      const envelope = JSON.parse(stdout) as { ok: boolean; error: { message: string } };
      expect(envelope.ok).toBe(false);
      expect(envelope.error.message).toContain(message);
      expect(request).not.toHaveBeenCalled();
    },
  );

  it("uses the human output callback for an empty list", async () => {
    request.mockResolvedValue({ sessions: [] });
    const log = vi.spyOn(console, "log").mockImplementation(() => {});

    await cmdSession(storage, "list", [], {});

    expect(log.mock.calls.flat().join("\n")).toContain("Sessions (0)");
    expect(log.mock.calls.flat().join("\n")).toContain("No sessions found.");
    log.mockRestore();
  });
});
