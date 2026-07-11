import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";

import {
  createLifecycleJournalExtension,
  OPPI_LIFECYCLE_CUSTOM_TYPE,
} from "../src/lifecycle-journal-extension.js";
import { readSessionTracePageFromFile } from "../src/trace-paging.js";
import { buildSessionContext, type SessionEntry } from "../src/trace.js";

describe("lifecycle journal extension", () => {
  it("persists structural Pi events as versioned custom entries", () => {
    const handlers = new Map<string, (event: Record<string, unknown>) => void>();
    const appendEntry = vi.fn();
    const extension = createLifecycleJournalExtension();

    extension.factory({
      appendEntry,
      on: (type: string, handler: (event: Record<string, unknown>) => void) => {
        handlers.set(type, handler);
      },
    } as never);

    handlers.get("agent_start")?.({});
    handlers.get("tool_execution_start")?.({
      toolCallId: "call-1",
      toolName: "bash",
      args: { command: "secret and intentionally not duplicated" },
    });
    handlers.get("tool_execution_end")?.({
      toolCallId: "call-1",
      toolName: "bash",
      isError: false,
      result: { content: "also not duplicated" },
    });
    handlers.get("agent_end")?.({});
    handlers.get("agent_settled")?.({});

    expect(appendEntry.mock.calls).toEqual([
      [OPPI_LIFECYCLE_CUSTOM_TYPE, { version: 1, event: "agent_start" }],
      [
        OPPI_LIFECYCLE_CUSTOM_TYPE,
        {
          version: 1,
          event: "tool_execution_start",
          toolCallId: "call-1",
          toolName: "bash",
        },
      ],
      [
        OPPI_LIFECYCLE_CUSTOM_TYPE,
        {
          version: 1,
          event: "tool_execution_end",
          toolCallId: "call-1",
          toolName: "bash",
          isError: false,
        },
      ],
      [OPPI_LIFECYCLE_CUSTOM_TYPE, { version: 1, event: "agent_end" }],
      [OPPI_LIFECYCLE_CUSTOM_TYPE, { version: 1, event: "agent_settled" }],
    ]);
  });

  it("keeps the full lifecycle and result with its call at a page boundary", async () => {
    const directory = await mkdtemp(join(tmpdir(), "oppi-lifecycle-page-"));
    const tracePath = join(directory, "session.jsonl");
    const entries: SessionEntry[] = [
      {
        type: "message",
        id: "assistant-1",
        timestamp: "2026-07-10T10:00:00.000Z",
        message: {
          role: "assistant",
          content: [
            {
              type: "toolCall",
              id: "call-1",
              name: "bash",
              arguments: { command: "true" },
            },
          ],
        },
      },
      {
        type: "custom",
        id: "lifecycle-start",
        parentId: "assistant-1",
        timestamp: "2026-07-10T10:00:01.000Z",
        customType: OPPI_LIFECYCLE_CUSTOM_TYPE,
        data: {
          version: 1,
          event: "tool_execution_start",
          toolCallId: "call-1",
          toolName: "bash",
        },
      },
      {
        type: "custom",
        id: "lifecycle-end",
        parentId: "lifecycle-start",
        timestamp: "2026-07-10T10:00:03.000Z",
        customType: OPPI_LIFECYCLE_CUSTOM_TYPE,
        data: {
          version: 1,
          event: "tool_execution_end",
          toolCallId: "call-1",
          toolName: "bash",
          isError: false,
        },
      },
      {
        type: "message",
        id: "result-1",
        parentId: "lifecycle-end",
        timestamp: "2026-07-10T10:00:03.000Z",
        message: {
          role: "toolResult",
          content: "done",
          toolCallId: "call-1",
          toolName: "bash",
          isError: false,
        },
      },
    ];
    await writeFile(tracePath, `${entries.map((entry) => JSON.stringify(entry)).join("\n")}\n`);

    const page = readSessionTracePageFromFile(tracePath, { targetEvents: 1 });

    expect(page.trace.map((event) => event.type)).toEqual(["toolCall", "toolResult"]);
    expect(page.trace[1]?.lifecycleBefore?.map((event) => event.event)).toEqual([
      "toolStart",
      "toolEnd",
    ]);
    expect(page.page.hasOlder).toBe(false);
  });

  it("carries lifecycle evidence on compatible original trace events", () => {
    const entries: SessionEntry[] = [
      {
        type: "custom",
        id: "lifecycle-1",
        timestamp: "2026-07-10T10:00:00.000Z",
        customType: OPPI_LIFECYCLE_CUSTOM_TYPE,
        data: { version: 1, event: "agent_start" },
      },
      {
        type: "message",
        id: "user-1",
        parentId: "lifecycle-1",
        timestamp: "2026-07-10T10:00:01.000Z",
        message: { role: "user", content: "hello" },
      },
      {
        type: "custom",
        id: "lifecycle-2",
        parentId: "user-1",
        timestamp: "2026-07-10T10:00:02.000Z",
        customType: OPPI_LIFECYCLE_CUSTOM_TYPE,
        data: { version: 1, event: "agent_settled" },
      },
    ];

    expect(buildSessionContext(entries, { view: "full" })).toEqual([
      {
        id: "user-1",
        type: "user",
        timestamp: "2026-07-10T10:00:01.000Z",
        text: "hello",
        lifecycleBefore: [
          {
            id: "lifecycle-1",
            event: "agentStart",
            timestamp: "2026-07-10T10:00:00.000Z",
          },
        ],
        lifecycleAfter: [
          {
            id: "lifecycle-2",
            event: "agentSettled",
            timestamp: "2026-07-10T10:00:02.000Z",
          },
        ],
      },
    ]);
  });
});
