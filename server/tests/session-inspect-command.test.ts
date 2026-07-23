import { describe, expect, it } from "vitest";

import {
  inspectJsonResult,
  inspectSession,
  type SessionTraceEvent,
} from "../src/cli/commands/session-inspect.js";
import type { LocalApiRequestOptions } from "../src/cli/local-api-client.js";

type ApiCall = <T>(path: string, options?: LocalApiRequestOptions) => Promise<T>;

function traceCall(trace: SessionTraceEvent[]): { call: ApiCall; paths: string[] } {
  const paths: string[] = [];
  return {
    paths,
    call: async <T>(path: string): Promise<T> => {
      paths.push(path);
      return {
        session: {
          id: "session/1",
          name: "Coverage",
          workspaceId: "ws 1",
          worktreeId: "main",
          status: "stopped",
          model: "test/model",
        },
        trace,
      } as T;
    },
  };
}

const fullTrace: SessionTraceEvent[] = [
  { type: "system", text: "Model context" },
  { type: "compaction", text: "Earlier summary" },
  { type: "user", text: "first prompt" },
  { type: "thinking", thinking: "considering" },
  { type: "toolCall", id: "call-1", tool: "read", args: { path: "README.md" } },
  { type: "toolResult", toolName: "read", output: "contents", isError: false },
  { type: "assistant", text: "first answer" },
  { type: "user", text: "second prompt" },
  { type: "toolCall" },
  { type: "toolResult", output: "failed", isError: true },
  { type: "assistant", message: "second answer" },
];

describe("session inspect command contract", () => {
  it.each([
    { view: "messages", turns: "2", expected: [2], text: "second answer" },
    { view: "tools", turns: "1-2", expected: [1, 2], text: "read [ok] contents" },
    { view: "response", turns: "all", expected: [1, 2], text: "second answer" },
  ])("renders $view with table-driven turn selection", async ({ view, turns, expected, text }) => {
    const api = traceCall(fullTrace);

    const result = await inspectSession("session/1", [], { view, turns }, api.call);

    expect(result.selected_turns).toEqual(expected);
    expect(result.text).toContain(text);
    expect(result.summary.counts).toEqual({
      traceEvents: 11,
      turns: 2,
      userMessages: 2,
      assistantMessages: 2,
      thinkingMessages: 1,
      toolCalls: 2,
      toolResults: 2,
      toolErrors: 1,
    });
    expect(api.paths).toEqual([
      view === "response"
        ? "/sessions/session%2F1/trace?include=messages"
        : "/sessions/session%2F1/trace",
    ]);
  });

  it("uses the positional turn selector and removes inline data payloads", async () => {
    const api = traceCall([
      { type: "user", text: "image data:image/png;base64,QUJDREVGRw==" },
      { type: "assistant", text: "done" },
      { type: "user", text: "later" },
    ]);

    const result = await inspectSession("s", ["1"], { view: "messages" }, api.call);

    expect(result.selected_turns).toEqual([1]);
    expect(result.text).toContain("[inline image/png data omitted]");
    expect(result.text).not.toContain("QUJDREVGRw");
    expect(result.text).not.toContain("later");
  });

  it("builds overview and outline from the compact outline API", async () => {
    const paths: string[] = [];
    const call: ApiCall = async <T>(path: string): Promise<T> => {
      paths.push(path);
      if (path === "/sessions/sess") {
        return {
          session: { id: "sess", name: "Inspect", workspaceId: "ws/one", status: "busy" },
        } as T;
      }
      return {
        outline: {
          entries: [
            { id: "u1", kind: "user", summary: "question" },
            { id: "t1", kind: "tool", summary: "read file", tool: "read", isError: true },
            { id: "ignored", kind: "unknown", summary: "future event" },
            { id: "a1", kind: "assistant", summary: "answer" },
          ],
        },
      } as T;
    };

    const outline = await inspectSession("sess", [], { view: "outline" }, call);
    const overview = await inspectSession("sess", [], { view: "overview" }, call);

    expect(outline.text).toContain("Turn 1");
    expect(outline.text).toContain("1 tool call");
    expect(outline.text).toContain("1 error");
    expect(outline.summary.counts).toMatchObject({ traceEvents: 4, toolCalls: 1, toolResults: 1 });
    expect(overview.text).toContain("session: sess");
    expect(overview.text).toContain("tool_errors: 1");
    expect(paths).toEqual([
      "/sessions/sess",
      "/workspaces/ws%2Fone/sessions/sess/trace-outline",
      "/sessions/sess",
      "/workspaces/ws%2Fone/sessions/sess/trace-outline",
    ]);
  });

  it("uses the control-session outline route for workspace-less sessions", async () => {
    const paths: string[] = [];
    const result = await inspectSession("control/1", [], { view: "summary" }, (async <T>(
      path: string,
    ) => {
      paths.push(path);
      if (path === "/sessions/control%2F1") {
        return { session: { id: "control/1", name: "Control" } } as T;
      }
      return { outline: { entries: [{ id: "u1", kind: "user", summary: "status" }] } } as T;
    }) as ApiCall);

    expect(paths).toEqual(["/sessions/control%2F1", "/control-sessions/control%2F1/trace-outline"]);
    expect(result.summary).toMatchObject({ sessionId: "control/1", workspaceId: undefined });
  });

  it("returns stable JSON shapes for summary and detailed views", async () => {
    const api = traceCall([]);
    const summary = await inspectSession("s", [], { view: "summary" }, async <T>(path: string) => {
      if (path === "/sessions/s") return { session: { id: "s", workspaceId: "ws" } } as T;
      return { outline: { entries: [] } } as T;
    });
    const messages = await inspectSession("s", [], { view: "messages" }, api.call);

    expect(inspectJsonResult(summary)).toEqual({ view: "summary", summary: summary.summary });
    expect(inspectJsonResult(messages)).toEqual({
      view: "messages",
      selected_turns: [],
      summary: messages.summary,
      text: "",
    });
  });

  it.each([
    ["0", "--turns must be all"],
    ["3", "--turns must be all"],
    ["2-1", "--turns must be all"],
    ["1,,2", "--turns must be all"],
    ["one", "--turns must be all"],
  ])("rejects invalid turn selector %s", async (turns, message) => {
    const api = traceCall(fullTrace);
    await expect(inspectSession("s", [], { view: "messages", turns }, api.call)).rejects.toThrow(
      message,
    );
  });

  it.each([
    {
      name: "unknown view",
      flags: { view: "raw" },
      call: traceCall([]).call,
      message: "--view must be one of",
    },
    {
      name: "missing trace",
      flags: { view: "messages" },
      call: (async () => ({ session: {} })) as ApiCall,
      message: "trace array",
    },
    {
      name: "malformed outline",
      flags: { view: "outline" },
      call: (async <T>(path: string) =>
        (path === "/sessions/s"
          ? { session: { id: "s", workspaceId: "ws" } }
          : { outline: { entries: [{ id: "bad" }] } }) as T) as ApiCall,
      message: "invalid trace outline entry",
    },
  ])("rejects malformed input: $name", async ({ flags, call, message }) => {
    await expect(inspectSession("s", [], flags, call)).rejects.toThrow(message);
  });
});
