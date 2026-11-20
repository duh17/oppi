import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import type { ToolExecutionApi } from "@earendil-works/pi-durable";
import { afterEach, describe, expect, it } from "vitest";
import { internalUrls } from "../src/durable-internal-urls.js";
import { GondolinExecutionEnv } from "../src/durable-gondolin-env.js";
import { bindOppiHost } from "../src/durable-extension-api.js";
import { pageText, parseInternalUrl } from "../src/internal-urls.js";
import type { Session } from "../src/types.js";

const row = (id: string, extra: Partial<Session> = {}): Session =>
  ({ id, status: "ready", lastActivity: 1, workspaceId: "w", ...extra }) as Session;

let rows: Session[] = [];
const bindSessions = (sessions: Session[]): void => {
  rows = sessions;
};
// The host as the server binds it, with the one part these tests read: the caller's sessions.
const noTool = { description: "", parameters: {}, execute: async () => ({}) };
bindOppiHost({
  sessions: () => ({
    reading: {
      sessionId: "caller",
      workspaceSessions: () => rows.filter((session) => session.workspaceId === "w"),
      transcript: async (id: string) =>
        id === "classic-1"
          ? null
          : [{ id: "e1", type: "assistant", timestamp: "", text: `answer of ${id}` }],
    },
  }),
  files: { ls: noTool, find: noTool, grep: noTool, internalUrls },
} as unknown as Parameters<typeof bindOppiHost>[0]);

// A conversation no saved Agent launched: no Oppi agent document.
const read = (path: string, api: Partial<ToolExecutionApi> = {}) =>
  internalUrls.read(
    { path },
    { snapshot: async () => undefined, ...api } as ToolExecutionApi,
    context,
  );
const textOf = async (path: string, api?: Partial<ToolExecutionApi>) => {
  const result = await read(path, api);
  return result?.output?.map((part) => (part.type === "text" ? part.text : "")).join("");
};

afterEach(() => bindSessions([]));

describe("internal URL resolution", () => {
  it("leaves file paths alone and splits an id from its path", () => {
    expect(parseInternalUrl("src/a.ts")).toBeUndefined();
    // Pi's read resolves file: URLs itself.
    expect(parseInternalUrl("file:///tmp/a.ts")).toBeUndefined();
    expect(parseInternalUrl("proc://bash-1/streams")).toMatchObject({
      scheme: "proc",
      id: "bash-1",
      path: "/streams",
    });
  });

  it("matches an id by exact value or unique prefix and lists ids otherwise", async () => {
    bindSessions([row("caller"), row("aaa1"), row("aaa2"), row("bbb1")]);
    expect(await textOf("history://bbb")).toContain("answer of bbb1");
    // An exact id wins over a longer id it prefixes.
    bindSessions([row("caller"), row("aaa"), row("aaa2")]);
    expect(await textOf("history://aaa")).toContain("answer of aaa");
    bindSessions([row("caller"), row("aaa1"), row("aaa2")]);
    await expect(read("history://aaa")).rejects.toThrow(
      /Ambiguous session id prefix "aaa": aaa1, aaa2/,
    );
    await expect(read("history://zzz")).rejects.toThrow(/No session "zzz". Valid ids: .*aaa1/);
  });

  it("refuses other workspaces and non-durable transcripts with a way forward", async () => {
    bindSessions([
      row("caller"),
      row("classic-1"),
      row("foreign-1", { workspaceId: "other", launch: { parentSessionId: "caller" } }),
    ]);
    await expect(read("history://foreign-1")).rejects.toThrow(/No session "foreign-1"/);
    await expect(read("agent://foreign-1")).rejects.toThrow(/No child session/);
    await expect(read("history://classic-1")).rejects.toThrow(/oppi session trace classic-1/);
  });

  it("reports a still-running child as progress, and a finished one as its answer", async () => {
    bindSessions([
      row("caller"),
      row("busy-1", { status: "busy", launch: { parentSessionId: "caller" } }),
      row("done-1", { launch: { parentSessionId: "busy-1" } }),
    ]);
    expect(await textOf("agent://busy-1")).toContain("Still working");
    // A grandchild is still this session's descendant.
    expect(await textOf("agent://done-1")).toContain("answer of done-1");
  });

  it("names the tool that does the job for schemes Oppi does not serve", async () => {
    bindSessions([]);
    await expect(read("issue://4")).rejects.toThrow("gh issue view");
    await expect(read("omp://x")).rejects.toThrow("not available");
    await expect(read("local://notes.md")).rejects.toThrow("no shared scratch");
    await expect(read("skill://x")).rejects.toThrow(
      /Unknown URL scheme "skill:\/\/". Supported: .*agent:\/\//,
    );
  });

  it("does not let a plugin take a scheme the server serves", () => {
    for (const scheme of ["agent", "history", "mcp", "ssh"])
      expect(() => internalUrls.register(scheme, async () => "")).toThrow("server's own");
  });

  it("serves every scheme the server owns, and a scheme a plugin registered", async () => {
    bindSessions([row("caller")]);
    // Each built-in answers as itself (these need no listing from the call's tools).
    expect(await textOf("history://")).toContain("Sessions in this workspace");
    expect(await textOf("agent://")).toContain("Sessions this session launched");
    const noResourceTools = { executeTool: async () => Promise.reject(new Error("absent")) };
    await expect(read("mcp://", noResourceTools)).rejects.toThrow(
      /mcp:\/\/ needs the session's MCP/,
    );
    const sandbox = new GondolinExecutionEnv({} as never, "w", "/workspace");
    await expect(read("ssh://", { env: sandbox })).rejects.toThrow(
      "not available in sandbox sessions",
    );
    internalUrls.register("plugin-test", async (target) => `plugin saw ${target.id}`);
    expect(await textOf("plugin-test://abc")).toBe("plugin saw abc");
  });

  it("reads an MCP resource through the session's resource tools", async () => {
    const calls: Array<[string, unknown]> = [];
    const api = {
      executeTool: async (name: string, args: unknown) => {
        calls.push([name, args]);
        return name === "list_mcp_resources"
          ? {
              isError: false,
              diagnostics: [],
              structuredOutput: JSON.stringify({
                resources: [{ server: "notes", uri: "test://a", name: "A" }],
              }),
            }
          : {
              isError: false,
              diagnostics: [],
              structuredOutput: "hello resource",
            };
      },
    };
    expect(await textOf("mcp://test://a", api)).toBe("hello resource");
    expect(calls.at(-1)).toEqual(["read_mcp_resource", { server: "notes", uri: "test://a" }]);
    expect(await textOf("mcp://", api)).toContain("notes  test://a  A");
    await expect(read("mcp://test://b", api)).rejects.toThrow(
      'No MCP resource "test://b". Available: test://a',
    );
    const offered = {
      executeTool: async () => Promise.reject(new Error("Tool x is not available")),
    };
    await expect(read("mcp://test://a", offered)).rejects.toThrow(
      /MCP resource tools, which are not available/,
    );
  });

  it("pages like the read tool and says where to continue", () => {
    const text = Array.from({ length: 5 }, (_, i) => `line ${i + 1}`).join("\n");
    expect(pageText(text, 2, 2)).toBe(
      "line 2\nline 3\n\n[Showing lines 2-3 of 5. Use offset=4 to continue.]",
    );
    expect(pageText(text, 4)).toBe("line 4\nline 5");
    expect(() => pageText(text, 9)).toThrow("beyond the end");
  });
});
