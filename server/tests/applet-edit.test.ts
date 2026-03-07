import { describe, expect, it } from "vitest";
import { buildAppletEditPrompt, extractAppletEditContext } from "../src/applet-edit.js";
import type { Applet, AppletVersion } from "../src/types.js";
import type { TraceEvent } from "../src/trace.js";

describe("applet edit context", () => {
  it("extracts compact provenance around a matching tool call", () => {
    const events: TraceEvent[] = [
      {
        id: "u1",
        type: "user",
        timestamp: "2026-03-06T00:00:00Z",
        text: "Build me a small JSON inspector applet for API responses.",
      },
      {
        id: "a1",
        type: "assistant",
        timestamp: "2026-03-06T00:00:01Z",
        text: "I'll create a simple viewer with pretty-printing and copy support.",
      },
      {
        id: "tool-123",
        type: "toolCall",
        timestamp: "2026-03-06T00:00:02Z",
        tool: "create_applet",
        args: { title: "JSON Inspector", html: "<html>...</html>" },
      },
      {
        id: "result-1",
        type: "toolResult",
        timestamp: "2026-03-06T00:00:03Z",
        toolCallId: "tool-123",
        output: 'Applet created: "JSON Inspector" (v1)',
        isError: false,
      },
    ];

    const context = extractAppletEditContext(events, "tool-123");
    expect(context).not.toBeNull();
    expect(context?.userSnippet).toContain("JSON inspector");
    expect(context?.assistantSnippet).toContain("simple viewer");
    expect(context?.toolName).toBe("create_applet");
    expect(context?.toolArgsSnippet).toContain("JSON Inspector");
    expect(context?.toolResultSnippet).toContain("Applet created");
  });

  it("builds a prompt with provenance when available", () => {
    const applet: Applet = {
      id: "a1",
      workspaceId: "w1",
      title: "JSON Inspector",
      description: "Inspect JSON payloads",
      currentVersion: 2,
      tags: ["json", "debug"],
      createdAt: 1,
      updatedAt: 2,
    };

    const version: AppletVersion = {
      version: 2,
      appletId: "a1",
      sessionId: "s1",
      toolCallId: "tool-123",
      size: 512,
      changeNote: "Added search",
      createdAt: 2,
    };

    const prompt = buildAppletEditPrompt({
      applet,
      version,
      context: {
        sourceSessionId: "s1",
        sourceToolCallId: "tool-123",
        sourceSessionName: "Build JSON tools",
        userSnippet: "Build a JSON inspector applet.",
        assistantSnippet: "I'll create a searchable viewer.",
        toolName: "create_applet",
        toolArgsSnippet: "{\"title\":\"JSON Inspector\"}",
        toolResultSnippet: "Applet created successfully.",
      },
    });

    expect(prompt).toContain("Hidden context: the user is editing an existing Oppi applet.");
    expect(prompt).toContain("source session: Build JSON tools");
    expect(prompt).toContain("Inspect the current applet source with get_applet(appletId).");
    expect(prompt).toContain("Save changes with update_applet(appletId: a1, html: ...).");
  });

  it("falls back cleanly when provenance is unavailable", () => {
    const applet: Applet = {
      id: "a1",
      workspaceId: "w1",
      title: "JSON Inspector",
      currentVersion: 1,
      createdAt: 1,
      updatedAt: 1,
    };

    const version: AppletVersion = {
      version: 1,
      appletId: "a1",
      size: 256,
      createdAt: 1,
    };

    const prompt = buildAppletEditPrompt({ applet, version, context: null });
    expect(prompt).toContain("Original creation/update provenance is unavailable");
    expect(prompt).toContain("get_applet(appletId)");
  });
});
