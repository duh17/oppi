/**
 * Applet Extension Factory
 *
 * Server-managed extension that provides create_applet / update_applet tools.
 * Injected into pi sessions with workspace context (same pattern as permission gate).
 */

import type { ExtensionFactory } from "@mariozechner/pi-coding-agent";
import type { Storage } from "./storage.js";
import { AppletError } from "./storage/applet-store.js";

// JSON Schema objects compatible with TypeBox's TSchema interface.
// Avoids direct @sinclair/typebox import (transitive dep, not listed in package.json).

const createAppletParamsSchema = {
  type: "object" as const,
  properties: {
    title: { type: "string" as const, description: "Short title for the applet" },
    html: {
      type: "string" as const,
      description:
        "Self-contained HTML document. Inline all JS/CSS. External libraries from CDN only (cdnjs, jsdelivr, unpkg, esm.sh). Max 1MB.",
    },
    description: { type: "string" as const, description: "What the applet does" },
    tags: {
      type: "array" as const,
      items: { type: "string" as const },
      description: "Categorization tags",
    },
    changeNote: { type: "string" as const, description: "What changed in this version" },
  },
  required: ["title", "html"] as string[],
};

const updateAppletParamsSchema = {
  type: "object" as const,
  properties: {
    appletId: { type: "string" as const, description: "ID of the applet to update" },
    html: { type: "string" as const, description: "Updated HTML content" },
    title: { type: "string" as const, description: "New title (optional)" },
    description: { type: "string" as const, description: "New description (optional)" },
    tags: {
      type: "array" as const,
      items: { type: "string" as const },
      description: "Updated tags (optional)",
    },
    changeNote: {
      type: "string" as const,
      description: 'What changed, e.g. "Added dark mode"',
    },
  },
  required: ["appletId", "html"] as string[],
};

const listAppletsParamsSchema = {
  type: "object" as const,
  properties: {},
};

interface CreateAppletParams {
  title: string;
  html: string;
  description?: string;
  tags?: string[];
  changeNote?: string;
}

interface UpdateAppletParams {
  appletId: string;
  html: string;
  title?: string;
  description?: string;
  tags?: string[];
  changeNote?: string;
}

export function createAppletExtensionFactory(
  storage: Storage,
  sessionId: string,
  workspaceId: string,
): ExtensionFactory {
  return (extensionApi: unknown) => {
    const pi = extensionApi as {
      registerTool(tool: {
        name: string;
        label: string;
        description: string;
        promptSnippet?: string;
        promptGuidelines?: string[];
        parameters: unknown;
        execute(
          toolCallId: string,
          params: unknown,
        ): Promise<{ content: { type: string; text: string }[] }>;
      }): void;
    };

    // ─── create_applet ───

    pi.registerTool({
      name: "create_applet",
      label: "Create Applet",
      description:
        "Create a new HTML applet. The applet is stored on the server with version history and can be viewed in a browser or in the Oppi app. Write self-contained HTML with inline JS/CSS. Load external libraries from CDNs (cdnjs.cloudflare.com, cdn.jsdelivr.net, unpkg.com, esm.sh).",
      promptSnippet:
        "Create a new HTML applet — self-contained HTML+JS+CSS rendered in the user's browser.",
      promptGuidelines: [
        "Applets must be self-contained single-file HTML. Inline all JS and CSS.",
        "Use CDN links for external libraries: cdnjs.cloudflare.com, cdn.jsdelivr.net, unpkg.com, esm.sh",
        'Include <meta name="viewport" content="width=device-width, initial-scale=1.0"> for mobile',
        "Support both light and dark mode via prefers-color-scheme media query",
        "Keep applets under 100KB typical, 1MB hard limit",
      ],
      parameters: createAppletParamsSchema,
      async execute(_toolCallId: string, params: unknown) {
        const p = params as CreateAppletParams;
        try {
          const result = storage.createApplet(workspaceId, {
            title: p.title,
            html: p.html,
            description: p.description,
            tags: p.tags,
            sessionId,
          });

          return {
            content: [
              {
                type: "text",
                text: [
                  `Applet created: "${result.applet.title}" (v${result.version.version})`,
                  `ID: ${result.applet.id}`,
                  `Size: ${result.version.size} bytes`,
                ].join("\n"),
              },
            ],
          };
        } catch (err) {
          const message = err instanceof AppletError ? err.message : "Failed to create applet";
          return { content: [{ type: "text", text: `Error: ${message}` }] };
        }
      },
    });

    // ─── update_applet ───

    pi.registerTool({
      name: "update_applet",
      label: "Update Applet",
      description:
        "Update an existing applet with new HTML content. Creates a new immutable version — previous versions are preserved. Use list_applets to find applet IDs.",
      promptSnippet: "Update an existing applet — creates a new version with the new HTML.",
      parameters: updateAppletParamsSchema,
      async execute(_toolCallId: string, params: unknown) {
        const p = params as UpdateAppletParams;
        try {
          const result = storage.updateApplet(workspaceId, p.appletId, {
            html: p.html,
            title: p.title,
            description: p.description,
            tags: p.tags,
            changeNote: p.changeNote,
            sessionId,
          });

          if (!result) {
            return {
              content: [{ type: "text", text: `Error: Applet "${p.appletId}" not found` }],
            };
          }

          return {
            content: [
              {
                type: "text",
                text: [
                  `Applet updated: "${result.applet.title}" (v${result.version.version})`,
                  `ID: ${result.applet.id}`,
                  `Size: ${result.version.size} bytes`,
                  result.version.changeNote ? `Change: ${result.version.changeNote}` : "",
                ]
                  .filter(Boolean)
                  .join("\n"),
              },
            ],
          };
        } catch (err) {
          const message = err instanceof AppletError ? err.message : "Failed to update applet";
          return { content: [{ type: "text", text: `Error: ${message}` }] };
        }
      },
    });

    // ─── list_applets ───

    pi.registerTool({
      name: "list_applets",
      label: "List Applets",
      description:
        "List all applets in the current workspace. Shows ID, title, version, and description for each.",
      promptSnippet: "List applets in the current workspace.",
      parameters: listAppletsParamsSchema,
      async execute() {
        const applets = storage.listApplets(workspaceId);
        if (applets.length === 0) {
          return { content: [{ type: "text", text: "No applets in this workspace." }] };
        }

        const lines = applets.map(
          (a) =>
            `- ${a.title} (v${a.currentVersion}) [id: ${a.id}]${a.description ? ` — ${a.description}` : ""}`,
        );

        return {
          content: [
            {
              type: "text",
              text: `${applets.length} applet${applets.length === 1 ? "" : "s"}:\n${lines.join("\n")}`,
            },
          ],
        };
      },
    });
  };
}
