import { Type } from "@sinclair/typebox";
import type { ExtensionFactory } from "@mariozechner/pi-coding-agent";

import { createAnnotation, AnnotationStoreError } from "./annotation-store.js";
import type { AnnotationSeverity, AnnotationSide } from "./types.js";

const VALID_SIDES = new Set(["old", "new", "file"]);
const VALID_SEVERITIES = new Set(["info", "warn", "error"]);

const annotateParams = Type.Object({
  path: Type.String({ description: "File path relative to the repository root." }),
  line: Type.Optional(
    Type.Number({
      description:
        "Line number to annotate (1-based). Use the new-side line number for added/modified lines, old-side for removed lines.",
    }),
  ),
  side: Type.Optional(
    Type.Union([Type.Literal("old"), Type.Literal("new"), Type.Literal("file")], {
      description:
        "Which side of the diff: 'new' for added/modified lines (default), 'old' for removed lines, 'file' for file-level comments.",
    }),
  ),
  body: Type.String({
    description: "The annotation text. Be specific about the concern and reference the code.",
  }),
  severity: Type.Union([Type.Literal("info"), Type.Literal("warn"), Type.Literal("error")], {
    description: "Severity level: 'error' for bugs, 'warn' for risks, 'info' for suggestions.",
  }),
});

/**
 * Creates a pi extension factory that registers a `review_annotate` tool.
 *
 * When the agent calls this tool during a review session, it creates a
 * server-side annotation anchored to a specific line in a file. These
 * annotations appear inline in the Oppi iOS diff view.
 */
export function createReviewAnnotateFactory(
  workspaceId: string,
  workspaceRoot: string,
  sessionId: string,
): ExtensionFactory {
  return (pi) => {
    pi.registerTool({
      name: "review_annotate",
      label: "Review Annotate",
      description: [
        "Create an inline annotation on a specific line of a file under review.",
        "Use this tool to report findings during code review. Each annotation",
        "is anchored to a file path and line number, and will appear inline in",
        "the diff view on the reviewer's device.",
        "",
        "Guidelines:",
        "- One annotation per distinct finding. Do not batch multiple issues.",
        "- Set severity to 'error' for bugs/regressions, 'warn' for risky",
        "  patterns or missing validation, 'info' for style/suggestions.",
        "- Reference the specific code in your body text.",
        "- Be concise. The reviewer sees this on a phone screen.",
      ].join("\n"),
      parameters: annotateParams,
      execute: async (_toolCallId, args, _signal, _onUpdate, _ctx) => {
        const path = typeof args.path === "string" ? args.path.trim() : "";
        const line = typeof args.line === "number" ? args.line : null;
        const side =
          typeof args.side === "string" && VALID_SIDES.has(args.side)
            ? (args.side as AnnotationSide)
            : "new";
        const body = typeof args.body === "string" ? args.body.trim() : "";
        const severity =
          typeof args.severity === "string" && VALID_SEVERITIES.has(args.severity)
            ? (args.severity as AnnotationSeverity)
            : "info";

        if (!path) {
          return {
            content: [{ type: "text" as const, text: "Error: path is required" }],
            details: undefined,
          };
        }
        if (!body) {
          return {
            content: [{ type: "text" as const, text: "Error: body is required" }],
            details: undefined,
          };
        }

        try {
          const annotation = await createAnnotation(workspaceId, workspaceRoot, {
            path,
            side,
            startLine: line,
            body,
            author: "agent",
            sessionId,
            severity,
          });

          const message = `Annotation created: ${annotation.path}:${annotation.startLine ?? "file"} [${annotation.severity}]`;
          return {
            content: [{ type: "text" as const, text: message }],
            details: undefined,
          };
        } catch (error) {
          if (error instanceof AnnotationStoreError) {
            return {
              content: [{ type: "text" as const, text: `Error: ${error.message}` }],
              details: undefined,
            };
          }
          throw error;
        }
      },
    });
  };
}
