import type { Storage } from "./storage.js";
import type { Applet, AppletVersion } from "./types.js";
import { readSessionTraceFromFiles } from "./trace.js";
import type { TraceEvent } from "./trace.js";

const USER_SNIPPET_LIMIT = 600;
const ASSISTANT_SNIPPET_LIMIT = 600;
const TOOL_ARGS_LIMIT = 2_000;
const TOOL_RESULT_LIMIT = 1_000;

export interface AppletEditContext {
  sourceSessionId: string;
  sourceToolCallId: string;
  sourceSessionName?: string;
  userSnippet?: string;
  assistantSnippet?: string;
  toolName?: string;
  toolArgsSnippet?: string;
  toolResultSnippet?: string;
}

export function extractAppletEditContext(
  events: TraceEvent[],
  toolCallId: string,
): Omit<AppletEditContext, "sourceSessionId" | "sourceSessionName" | "sourceToolCallId"> | null {
  const targetId = toolCallId.trim();
  if (!targetId) return null;

  const toolCallIndex = events.findIndex(
    (event) => event.type === "toolCall" && event.id === targetId,
  );
  if (toolCallIndex === -1) return null;

  const toolCall = events[toolCallIndex];

  let userSnippet: string | undefined;
  let assistantSnippet: string | undefined;
  for (let i = toolCallIndex - 1; i >= 0; i--) {
    const event = events[i];
    if (!userSnippet && event.type === "user" && event.text) {
      userSnippet = clipSnippet(event.text, USER_SNIPPET_LIMIT);
    }
    if (!assistantSnippet && event.type === "assistant" && event.text) {
      assistantSnippet = clipSnippet(event.text, ASSISTANT_SNIPPET_LIMIT);
    }
    if (userSnippet && assistantSnippet) break;
  }

  let toolResultSnippet: string | undefined;
  for (let i = toolCallIndex + 1; i < events.length; i++) {
    const event = events[i];
    if (event.type === "toolResult" && event.toolCallId === targetId) {
      if (event.output) {
        toolResultSnippet = clipSnippet(event.output, TOOL_RESULT_LIMIT);
      }
      break;
    }
  }

  return {
    userSnippet,
    assistantSnippet,
    toolName: toolCall.tool,
    toolArgsSnippet: toolCall.args
      ? clipSnippet(JSON.stringify(toolCall.args, null, 2), TOOL_ARGS_LIMIT)
      : undefined,
    toolResultSnippet,
  };
}

export function loadAppletEditContext(
  storage: Storage,
  sourceSessionId?: string,
  toolCallId?: string,
): AppletEditContext | null {
  const trimmedSessionId = sourceSessionId?.trim() ?? "";
  const trimmedToolCallId = toolCallId?.trim() ?? "";
  if (!trimmedSessionId || !trimmedToolCallId) {
    return null;
  }

  const session = storage.getSession(trimmedSessionId);
  if (!session) {
    return null;
  }

  const files = Array.from(
    new Set([
      ...(session.piSessionFiles || []),
      ...(session.piSessionFile ? [session.piSessionFile] : []),
    ]),
  );
  if (files.length === 0) {
    return null;
  }

  const events = readSessionTraceFromFiles(files, { view: "full" });
  if (!events || events.length === 0) {
    return null;
  }

  const extracted = extractAppletEditContext(events, trimmedToolCallId);
  if (!extracted) {
    return null;
  }

  return {
    sourceSessionId: trimmedSessionId,
    sourceToolCallId: trimmedToolCallId,
    sourceSessionName: session.name,
    ...extracted,
  };
}

export function buildAppletEditPrompt(input: {
  applet: Applet;
  version: AppletVersion;
  context: AppletEditContext | null;
}): string {
  const { applet, version, context } = input;

  const lines = [
    "Hidden context: the user is editing an existing Oppi applet.",
    "",
    "Applet:",
    `- id: ${applet.id}`,
    `- title: ${applet.title}`,
    `- workspaceId: ${applet.workspaceId}`,
    `- version: ${version.version}`,
  ];

  if (applet.description?.trim()) {
    lines.push(`- description: ${applet.description.trim()}`);
  }

  if (applet.tags && applet.tags.length > 0) {
    lines.push(`- tags: ${applet.tags.join(", ")}`);
  }

  if (version.changeNote?.trim()) {
    lines.push(`- latest change note: ${version.changeNote.trim()}`);
  }

  if (context) {
    lines.push(
      "",
      "Provenance (best effort):",
      `- source session: ${context.sourceSessionName?.trim() || context.sourceSessionId}`,
      `- source tool call: ${context.sourceToolCallId}`,
    );

    if (context.userSnippet) {
      lines.push("", "Original user intent:", context.userSnippet);
    }

    if (context.assistantSnippet) {
      lines.push("", "Nearby assistant context:", context.assistantSnippet);
    }

    if (context.toolName || context.toolArgsSnippet) {
      lines.push("", `Tool call: ${context.toolName || "unknown"}`);
      if (context.toolArgsSnippet) {
        lines.push("Arguments:", context.toolArgsSnippet);
      }
    }

    if (context.toolResultSnippet) {
      lines.push("", "Tool result snippet:", context.toolResultSnippet);
    }
  } else {
    lines.push(
      "",
      "Original creation/update provenance is unavailable. Use the current applet source as ground truth.",
    );
  }

  lines.push(
    "",
    "Instructions:",
    "1. Inspect the current applet source with get_applet(appletId).",
    "2. Use this context when answering the user's next request.",
    "3. Preserve working behavior unless the request requires otherwise.",
    `4. Save changes with update_applet(appletId: ${applet.id}, html: ...).`,
    "5. The user's actual request follows after this hidden context block.",
  );

  return lines.join("\n");
}

function clipSnippet(text: string, limit: number): string {
  const normalized = text.replace(/\s+/g, " ").trim();
  if (normalized.length <= limit) {
    return normalized;
  }
  return `${normalized.slice(0, Math.max(0, limit - 1)).trimEnd()}…`;
}
