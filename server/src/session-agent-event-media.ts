import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";

import {
  materializeToolMediaContentBlocks,
  materializeToolMediaDetails,
} from "./session-attachments.js";
import { stripImageMediaFromDetails } from "./session-media-sanitization.js";

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

export function hasToolMediaDetails(details: unknown): boolean {
  if (!details || typeof details !== "object" || Array.isArray(details)) {
    return false;
  }
  const root = details as { audio?: unknown; image?: unknown; media?: unknown };
  const isMedia = (media: unknown): boolean =>
    Boolean(
      media &&
      typeof media === "object" &&
      !Array.isArray(media) &&
      (["audio", "image", "video"] as unknown[]).includes((media as { kind?: unknown }).kind),
    );

  return (
    [root.audio, root.image].some(isMedia) ||
    (Array.isArray(root.media) && root.media.some(isMedia))
  );
}

function fallbackFileNameFromArgs(args: unknown): string | undefined {
  const path = asRecord(args)?.path;
  return typeof path === "string" && path.trim() ? path : undefined;
}

function stripPartialImageContent(contents: unknown[] | undefined): unknown[] | undefined {
  if (!contents) return undefined;
  const filtered = contents.filter((block) => asRecord(block)?.type !== "image");
  return filtered.length === contents.length ? contents : filtered;
}

export function materializeAgentEventMedia(args: {
  event: AgentSessionEvent;
  dataDir?: string;
  sessionId: string;
  trustedSourceRoots?: string[];
}): AgentSessionEvent {
  const { event, dataDir, sessionId, trustedSourceRoots } = args;
  if (!dataDir) return event;

  if (event.type === "tool_execution_update") {
    const rawContent = Array.isArray(event.partialResult?.content)
      ? event.partialResult.content
      : undefined;
    const content = stripPartialImageContent(rawContent);
    const rawDetails = event.partialResult?.details;
    const strippedDetails = stripImageMediaFromDetails(rawDetails);
    const details = materializeToolMediaDetails({
      dataDir,
      sessionId,
      toolCallId: typeof event.toolCallId === "string" ? event.toolCallId : undefined,
      details: strippedDetails,
      trustedSourceRoots,
    });
    const contentChanged = content !== rawContent;
    const detailsChanged = strippedDetails !== rawDetails || details !== strippedDetails;
    if (!contentChanged && !detailsChanged) return event;

    const partialResult = { ...event.partialResult } as Record<string, unknown>;
    if (contentChanged || content) {
      partialResult.content = content
        ? materializeToolMediaContentBlocks({
            dataDir,
            sessionId,
            toolCallId: typeof event.toolCallId === "string" ? event.toolCallId : undefined,
            contents: content,
            fallbackFileName: fallbackFileNameFromArgs(event.args),
          })
        : content;
    }
    if (detailsChanged) {
      if (details !== undefined) {
        partialResult.details = details;
      } else {
        delete partialResult.details;
      }
    }

    return {
      ...event,
      partialResult,
    } as AgentSessionEvent;
  }

  if (event.type === "tool_execution_end") {
    const content = Array.isArray(event.result?.content) ? event.result.content : undefined;
    const details = materializeToolMediaDetails({
      dataDir,
      sessionId,
      toolCallId: typeof event.toolCallId === "string" ? event.toolCallId : undefined,
      details: event.result?.details,
      trustedSourceRoots,
    });
    if (!content && details === event.result?.details) return event;
    return {
      ...event,
      result: {
        ...event.result,
        ...(content
          ? {
              content: materializeToolMediaContentBlocks({
                dataDir,
                sessionId,
                toolCallId: typeof event.toolCallId === "string" ? event.toolCallId : undefined,
                contents: content,
              }),
            }
          : {}),
        ...(details !== undefined ? { details } : {}),
      },
    } as AgentSessionEvent;
  }

  return event;
}
