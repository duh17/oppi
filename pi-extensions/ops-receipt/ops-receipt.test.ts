import { describe, expect, it } from "bun:test";

import opsReceipt, {
  commandKind,
  parseOppiJsonData,
  receiptFromInspect,
  receiptFromToolEvent,
  receiptFromWait,
  CUSTOM_TYPE,
} from "./index.ts";

describe("ops-receipt", () => {
  it("classifies wait and inspect commands only", () => {
    expect(commandKind("oppi session wait abc --json")).toBe("wait");
    expect(commandKind("oppi session inspect abc --view summary --json")).toBe("inspect");
    expect(commandKind("oppi session list --json")).toBeNull();
    expect(commandKind("npm test")).toBeNull();
  });

  it("stamps an idle wait without copying output_delta", () => {
    const receipt = receiptFromWait(
      {
        session_id: "bfe1909c-2335-4f46-b1a8-45797b1c55f2",
        reason: "idle",
        status: "stopped",
        output_delta: "SECRET_SHOULD_NOT_APPEAR",
      },
      "oppi session wait bfe1909c --for idle --json",
    );
    expect(receipt).toEqual({
      title: "Child done",
      body: "bfe1909c · idle",
      sessionId: "bfe1909c-2335-4f46-b1a8-45797b1c55f2",
      reason: "idle",
    });
    expect(JSON.stringify(receipt)).not.toContain("SECRET");
  });

  it("stamps attention waits as needs-you", () => {
    const receipt = receiptFromWait(
      { session_id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", reason: "attention" },
      "oppi session wait aaaaaaaa --for either --json",
    );
    expect(receipt?.title).toBe("Child needs you");
    expect(receipt?.body).toBe("aaaaaaaa · attention");
  });

  it("stamps inspect only when the child is idle or stopped", () => {
    const done = receiptFromInspect({
      session_id: "11111111-1111-4111-8111-111111111111",
      summary: { sessionName: "custom-entry-timeline-repair", status: "stopped" },
    });
    expect(done).toEqual({
      title: "Child done",
      body: "custom-entry-timeline-repair · stopped",
      sessionId: "11111111-1111-4111-8111-111111111111",
      reason: "stopped",
    });
    expect(
      receiptFromInspect({
        summary: { sessionName: "still-running", status: "busy" },
      }),
    ).toBeNull();
  });

  it("ignores failed tools and non-json output", () => {
    expect(
      receiptFromToolEvent({
        isError: true,
        args: { command: "oppi session wait abc --json" },
        result: '{"ok":true,"data":{"session_id":"abc","reason":"idle"}}',
      }),
    ).toBeNull();
    expect(
      receiptFromToolEvent({
        args: { command: "oppi session wait abc --json" },
        result: "timed out",
      }),
    ).toBeNull();
  });

  it("parses a json envelope buried in tool text", () => {
    const data = parseOppiJsonData(
      'noise\n{"ok":true,"data":{"session_id":"abc","reason":"idle"}}\n',
    );
    expect(data).toEqual({ session_id: "abc", reason: "idle" });
  });

  it("does not stamp from tool_execution_end because that event has no args", () => {
    expect(
      receiptFromToolEvent({
        toolName: "bash",
        result: {
          content: [
            {
              type: "text",
              text: JSON.stringify({
                ok: true,
                data: { session_id: "01b6d562-bb82-4700-8865-2931f9d1790c", reason: "idle" },
              }),
            },
          ],
        },
      }),
    ).toBeNull();
  });

  it("stamps from tool_result input.command and content", () => {
    const receipt = receiptFromToolEvent({
      toolName: "bash",
      input: { command: "oppi session wait 01b6d562 --for either --json" },
      content: [
        {
          type: "text",
          text: JSON.stringify({
            ok: true,
            data: {
              session_id: "01b6d562-bb82-4700-8865-2931f9d1790c",
              reason: "idle",
              status: "stopped",
            },
          }),
        },
      ],
    });
    expect(receipt).toEqual({
      title: "Child done",
      body: "01b6d562 · idle",
      sessionId: "01b6d562-bb82-4700-8865-2931f9d1790c",
      reason: "idle",
    });
  });

  it("registers a renderer and appends on tool_result", () => {
    const appendEntry = mockFn();
    const handlers = new Map<string, Array<(event: unknown) => void>>();
    const renderers = new Map<string, (entry: { data: unknown }) => { render: () => string[] }>();
    opsReceipt({
      appendEntry,
      registerEntryRenderer: (type, renderer) => {
        renderers.set(type, renderer);
      },
      on: (event, handler) => {
        const list = handlers.get(event) ?? [];
        list.push(handler);
        handlers.set(event, list);
      },
    } as never);

    expect(renderers.has(CUSTOM_TYPE)).toBe(true);
    const painted = renderers.get(CUSTOM_TYPE)?.({
      data: { title: "Child done", body: "repair · idle" },
    });
    expect(painted?.render()).toEqual(["Child done", "repair · idle"]);
    expect(handlers.has("tool_result")).toBe(true);
    expect(handlers.has("tool_execution_end")).toBe(false);

    for (const handler of handlers.get("tool_result") ?? []) {
      handler({
        type: "tool_result",
        toolName: "bash",
        toolCallId: "call-1",
        input: { command: "oppi session wait 01b6d562 --for either --json" },
        content: [
          {
            type: "text",
            text: JSON.stringify({
              ok: true,
              data: {
                session_id: "01b6d562-bb82-4700-8865-2931f9d1790c",
                reason: "idle",
                status: "stopped",
              },
            }),
          },
        ],
        isError: false,
      });
    }
    expect(appendEntry.calls).toEqual([
      [
        CUSTOM_TYPE,
        {
          title: "Child done",
          body: "01b6d562 · idle",
          sessionId: "01b6d562-bb82-4700-8865-2931f9d1790c",
          reason: "idle",
        },
      ],
    ]);
  });
});

function mockFn(): ((...args: unknown[]) => void) & { calls: unknown[][] } {
  const calls: unknown[][] = [];
  const fn = ((...args: unknown[]) => {
    calls.push(args);
  }) as ((...args: unknown[]) => void) & { calls: unknown[][] };
  fn.calls = calls;
  return fn;
}
