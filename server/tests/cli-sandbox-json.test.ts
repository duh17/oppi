import { afterEach, describe, expect, it, vi } from "vitest";

import { localApiRequest } from "../src/cli/local-api-client.js";
import { runCli } from "../src/cli/runner.js";

vi.mock("../src/cli/local-api-client.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/cli/local-api-client.js")>();
  return { ...actual, localApiRequest: vi.fn() };
});

const request = vi.mocked(localApiRequest);

const sandboxScope = { workspaceId: "ws-sandbox", workspaceName: "sandbox" };
const hostMount = "/Users/alice/workspace/project";
const piSessionFile = "/Users/alice/.pi/agent/sessions/s1.jsonl";

afterEach(() => {
  request.mockReset();
});

describe("sandbox-scoped CLI JSON", () => {
  it("omits hostMount and host home paths from workspace get, while unscoped CLI still includes them", async () => {
    const workspace = { id: "ws-sandbox", name: "sandbox", hostMount };
    request.mockResolvedValue({ workspace } as never);

    const scoped = await runCli(["workspace", "get", "ws-sandbox"], {
      dataDir: "/tmp/oppi-sandbox-cli-json",
      captureHuman: true,
      forceJson: true,
      sandboxScope,
    });
    const unscoped = await runCli(["workspace", "get", "ws-sandbox"], {
      dataDir: "/tmp/oppi-sandbox-cli-json",
      captureHuman: true,
      forceJson: true,
    });

    expect(scoped).toMatchObject({ ok: true, exitCode: 0 });
    expect(unscoped).toMatchObject({ ok: true, exitCode: 0 });

    const scopedJson = JSON.parse(scoped.stdout) as {
      data: { workspace: Record<string, unknown> };
    };
    const unscopedJson = JSON.parse(unscoped.stdout) as {
      data: { workspace: Record<string, unknown> };
    };

    expect(JSON.stringify(scopedJson)).not.toContain("/Users/");
    expect(JSON.stringify(scopedJson)).not.toContain("hostMount");
    expect(scopedJson.data.workspace).toEqual({ id: "ws-sandbox", name: "sandbox" });

    expect(workspace.hostMount).toBe(hostMount);
    expect(unscopedJson.data.workspace.hostMount).toBe(hostMount);
    expect(JSON.stringify(unscopedJson)).toContain("/Users/");
  });

  it("omits session file paths and host cwd from session get, while unscoped CLI still includes them", async () => {
    const session = {
      id: "sess-1",
      workspaceId: "ws-sandbox",
      name: "child",
      status: "ready",
      piSessionFile,
      piSessionFiles: [piSessionFile],
      cwd: hostMount,
      launch: { target: { displayCwd: "/workspace/sandbox" } },
    };
    request.mockResolvedValue({ session } as never);

    const scoped = await runCli(["session", "get", "sess-1"], {
      dataDir: "/tmp/oppi-sandbox-cli-json",
      captureHuman: true,
      forceJson: true,
      sandboxScope,
    });
    const unscoped = await runCli(["session", "get", "sess-1"], {
      dataDir: "/tmp/oppi-sandbox-cli-json",
      captureHuman: true,
      forceJson: true,
    });

    expect(scoped).toMatchObject({ ok: true, exitCode: 0 });
    expect(unscoped).toMatchObject({ ok: true, exitCode: 0 });

    const scopedJson = JSON.parse(scoped.stdout) as { data: { session: Record<string, unknown> } };
    const unscopedJson = JSON.parse(unscoped.stdout) as {
      data: { session: Record<string, unknown> };
    };

    expect(JSON.stringify(scopedJson)).not.toContain("/Users/");
    expect(JSON.stringify(scopedJson)).not.toContain("hostMount");
    expect(scopedJson.data.session).not.toHaveProperty("piSessionFile");
    expect(scopedJson.data.session).not.toHaveProperty("piSessionFiles");
    expect(scopedJson.data.session).not.toHaveProperty("cwd");
    expect(scopedJson.data.session).toMatchObject({
      id: "sess-1",
      workspaceId: "ws-sandbox",
      name: "child",
      status: "ready",
      launch: { target: { displayCwd: "/workspace/sandbox" } },
    });

    expect(session.piSessionFile).toBe(piSessionFile);
    expect(session.piSessionFiles).toEqual([piSessionFile]);
    expect(session.cwd).toBe(hostMount);
    expect(unscopedJson.data.session.piSessionFile).toBe(piSessionFile);
    expect(unscopedJson.data.session.piSessionFiles).toEqual([piSessionFile]);
    expect(unscopedJson.data.session.cwd).toBe(hostMount);
    expect(JSON.stringify(unscopedJson)).toContain("/Users/");
  });

  it("omits host session file paths from sandbox-scoped session list JSON", async () => {
    request.mockImplementation(async (_storage, path) => {
      if (path === "/workspaces/ws-sandbox") {
        return { workspace: { id: "ws-sandbox", name: "sandbox", hostMount } } as never;
      }
      if (typeof path === "string" && path.startsWith("/workspaces/ws-sandbox/sessions")) {
        return {
          workspaceId: "ws-sandbox",
          active: [
            {
              id: "sess-1",
              workspaceId: "ws-sandbox",
              name: "child",
              status: "ready",
              piSessionFile,
              piSessionFiles: [piSessionFile],
              path: piSessionFile,
              cwd: hostMount,
            },
          ],
          stopped: [],
        } as never;
      }
      throw new Error(`unexpected path ${String(path)}`);
    });

    const scoped = await runCli(["session", "list", "--workspace", "ws-sandbox"], {
      dataDir: "/tmp/oppi-sandbox-cli-json",
      captureHuman: true,
      forceJson: true,
      sandboxScope,
    });

    expect(scoped).toMatchObject({ ok: true, exitCode: 0 });
    expect(JSON.stringify(JSON.parse(scoped.stdout))).not.toContain("/Users/");
    expect(JSON.stringify(JSON.parse(scoped.stdout))).not.toContain("hostMount");
    expect(JSON.stringify(JSON.parse(scoped.stdout))).not.toContain("piSessionFile");
  });
});
