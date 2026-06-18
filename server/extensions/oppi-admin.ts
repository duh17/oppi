import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import type { Storage } from "../src/storage.js";
import type { CreateWorkspaceRequest, UpdateWorkspaceRequest, Workspace } from "../src/types.js";

const PromptModeSchema = Type.Literal("append");
const ThemeColorSchemeSchema = Type.Union([Type.Literal("dark"), Type.Literal("light")]);

const REQUIRED_THEME_COLOR_KEYS = [
  "bg",
  "bgDark",
  "bgHighlight",
  "fg",
  "fgDim",
  "comment",
  "blue",
  "cyan",
  "green",
  "orange",
  "purple",
  "red",
  "yellow",
  "thinkingText",
  "userMessageBg",
  "userMessageText",
  "toolPendingBg",
  "toolSuccessBg",
  "toolErrorBg",
  "toolTitle",
  "toolOutput",
  "mdHeading",
  "mdLink",
  "mdLinkUrl",
  "mdCode",
  "mdCodeBlock",
  "mdCodeBlockBorder",
  "mdQuote",
  "mdQuoteBorder",
  "mdHr",
  "mdListBullet",
  "toolDiffAdded",
  "toolDiffRemoved",
  "toolDiffContext",
  "syntaxComment",
  "syntaxKeyword",
  "syntaxFunction",
  "syntaxVariable",
  "syntaxString",
  "syntaxNumber",
  "syntaxType",
  "syntaxOperator",
  "syntaxPunctuation",
  "thinkingOff",
  "thinkingMinimal",
  "thinkingLow",
  "thinkingMedium",
  "thinkingHigh",
  "thinkingXhigh",
] as const;

const THEME_HEX_RE = /^#[0-9a-fA-F]{6}$/;

const CreateWorkspaceParams = Type.Object({
  name: Type.String({ description: "Workspace name" }),
  description: Type.Optional(Type.String({ description: "Short workspace description" })),
  icon: Type.Optional(Type.String({ description: "Emoji or icon string" })),
  systemPrompt: Type.Optional(Type.String()),
  systemPromptMode: Type.Optional(PromptModeSchema),
  hostMount: Type.Optional(Type.String()),
  defaultModel: Type.Optional(Type.String()),
  gitStatusEnabled: Type.Optional(Type.Boolean()),
});

const UpdateWorkspaceParams = Type.Object({
  workspaceId: Type.String({ description: "Workspace id" }),
  name: Type.Optional(Type.String()),
  description: Type.Optional(Type.Union([Type.String(), Type.Null()])),
  icon: Type.Optional(Type.Union([Type.String(), Type.Null()])),
  systemPrompt: Type.Optional(Type.Union([Type.String(), Type.Null()])),
  systemPromptMode: Type.Optional(PromptModeSchema),
  hostMount: Type.Optional(Type.Union([Type.String(), Type.Null()])),
  defaultModel: Type.Optional(Type.Union([Type.String(), Type.Null()])),
  gitStatusEnabled: Type.Optional(Type.Boolean()),
});

const WorkspaceIdParams = Type.Object({
  workspaceId: Type.String({ description: "Workspace id" }),
});

const BuildThemeParams = Type.Object({
  name: Type.String({ description: "Display name for the theme" }),
  colorScheme: ThemeColorSchemeSchema,
  colors: Type.Record(Type.String(), Type.String(), {
    description: "Map of Oppi theme color token to #RRGGBB hex value",
  }),
});

const NoParams = Type.Object({});

function normalizeCreateRequest(params: Record<string, unknown>): CreateWorkspaceRequest {
  const req: CreateWorkspaceRequest = {
    name: String(params.name),
  };

  if (typeof params.description === "string") req.description = params.description;
  if (typeof params.icon === "string") req.icon = params.icon;
  if (typeof params.systemPrompt === "string") req.systemPrompt = params.systemPrompt;
  if (params.systemPromptMode === "append") {
    req.systemPromptMode = params.systemPromptMode;
  }
  if (typeof params.hostMount === "string") req.hostMount = params.hostMount;
  if (typeof params.defaultModel === "string") req.defaultModel = params.defaultModel;
  if (typeof params.gitStatusEnabled === "boolean") req.gitStatusEnabled = params.gitStatusEnabled;

  return req;
}

function normalizeUpdateRequest(params: Record<string, unknown>): UpdateWorkspaceRequest {
  const req: UpdateWorkspaceRequest = {};

  if (typeof params.name === "string") req.name = params.name;
  if (typeof params.description === "string" || params.description === null) {
    req.description = params.description as string | null;
  }
  if (typeof params.icon === "string" || params.icon === null) {
    req.icon = params.icon as string | null;
  }
  if (typeof params.systemPrompt === "string" || params.systemPrompt === null) {
    req.systemPrompt = params.systemPrompt as string | null;
  }
  if (params.systemPromptMode === "append") {
    req.systemPromptMode = params.systemPromptMode;
  }
  if (typeof params.hostMount === "string" || params.hostMount === null) {
    req.hostMount = params.hostMount as string | null;
  }
  if (typeof params.defaultModel === "string" || params.defaultModel === null) {
    req.defaultModel = params.defaultModel as string | null;
  }
  if (typeof params.gitStatusEnabled === "boolean") req.gitStatusEnabled = params.gitStatusEnabled;

  return req;
}

function slugify(name: string): string {
  return name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

function validateThemeColors(colors: Record<string, string>): void {
  const missing = REQUIRED_THEME_COLOR_KEYS.filter((key) => !(key in colors));
  if (missing.length > 0) {
    throw new Error(`Missing ${missing.length} required color tokens: ${missing.join(", ")}`);
  }

  const invalid: string[] = [];
  for (const [key, value] of Object.entries(colors)) {
    if (!THEME_HEX_RE.test(value)) {
      invalid.push(`${key}: ${JSON.stringify(value)}`);
    }
  }
  if (invalid.length > 0) {
    throw new Error(`Invalid hex colors (must be #RRGGBB): ${invalid.join(", ")}`);
  }
}

function buildThemePayload(
  name: string,
  colorScheme: "dark" | "light",
  colors: Record<string, string>,
): { name: string; colorScheme: "dark" | "light"; colors: Record<string, string> } {
  validateThemeColors(colors);

  const orderedColors: Record<string, string> = {};
  for (const key of REQUIRED_THEME_COLOR_KEYS) {
    orderedColors[key] = colors[key];
  }
  for (const key of Object.keys(colors)) {
    if (!(key in orderedColors)) {
      orderedColors[key] = colors[key];
    }
  }

  return { name, colorScheme, colors: orderedColors };
}

function workspaceText(workspace: Workspace): string {
  return JSON.stringify(
    {
      id: workspace.id,
      name: workspace.name,
      hostMount: workspace.hostMount,
    },
    null,
    2,
  );
}

export function createOppiAdminFactory(storage: Storage): ExtensionFactory {
  return (pi) => {
    pi.registerTool({
      name: "oppi_admin_list_workspaces",
      label: "List Oppi workspaces",
      description: "List Oppi workspaces from the server runtime.",
      parameters: NoParams,
      async execute() {
        const workspaces = storage.listWorkspaces();
        return {
          content: [{ type: "text", text: JSON.stringify({ workspaces }, null, 2) }],
          details: { workspaces },
        };
      },
    });

    pi.registerTool({
      name: "oppi_admin_get_workspace",
      label: "Get Oppi workspace",
      description: "Get one Oppi workspace by id.",
      parameters: WorkspaceIdParams,
      async execute(_toolCallId, params) {
        const workspace = storage.getWorkspace(String(params.workspaceId));
        if (!workspace) {
          throw new Error(`Workspace not found: ${params.workspaceId}`);
        }
        return {
          content: [{ type: "text", text: workspaceText(workspace) }],
          details: { workspace },
        };
      },
    });

    pi.registerTool({
      name: "oppi_admin_create_workspace",
      label: "Create Oppi workspace",
      description: "Create a new Oppi workspace in the runtime config store.",
      parameters: CreateWorkspaceParams,
      async execute(_toolCallId, params) {
        const request = normalizeCreateRequest(params as Record<string, unknown>);
        const workspace = storage.createWorkspace(request);
        return {
          content: [
            { type: "text", text: `Created workspace ${workspace.name} (${workspace.id})` },
          ],
          details: { workspace },
        };
      },
    });

    pi.registerTool({
      name: "oppi_admin_update_workspace",
      label: "Update Oppi workspace",
      description: "Update an existing Oppi workspace in the runtime config store.",
      parameters: UpdateWorkspaceParams,
      async execute(_toolCallId, params) {
        const workspaceId = String(params.workspaceId);
        const request = normalizeUpdateRequest(params as Record<string, unknown>);
        const workspace = storage.updateWorkspace(workspaceId, request);
        if (!workspace) {
          throw new Error(`Workspace not found: ${workspaceId}`);
        }
        return {
          content: [
            { type: "text", text: `Updated workspace ${workspace.name} (${workspace.id})` },
          ],
          details: { workspace },
        };
      },
    });

    pi.registerTool({
      name: "oppi_admin_delete_workspace",
      label: "Delete Oppi workspace",
      description: "Delete an Oppi workspace from the runtime config store.",
      parameters: WorkspaceIdParams,
      async execute(_toolCallId, params) {
        const workspaceId = String(params.workspaceId);
        const existing = storage.getWorkspace(workspaceId);
        if (!existing) {
          throw new Error(`Workspace not found: ${workspaceId}`);
        }
        const deleted = storage.deleteWorkspace(workspaceId);
        if (!deleted) {
          throw new Error(`Failed to delete workspace: ${workspaceId}`);
        }
        return {
          content: [{ type: "text", text: `Deleted workspace ${existing.name} (${existing.id})` }],
          details: { workspaceId, deleted: true },
        };
      },
    });

    pi.registerTool({
      name: "build_theme",
      label: "Build Theme",
      description:
        "Build an Oppi iOS theme with the full 49-token color map and save it into the Oppi runtime themes directory.",
      parameters: BuildThemeParams,
      async execute(_toolCallId, params) {
        const name = String(params.name);
        const colorScheme = params.colorScheme === "light" ? "light" : "dark";
        const colors = params.colors as Record<string, string>;
        const theme = buildThemePayload(name, colorScheme, colors);

        const themesDir = join(storage.getDataDir(), "themes");
        if (!existsSync(themesDir)) {
          mkdirSync(themesDir, { recursive: true });
        }

        const slug = slugify(name);
        if (!slug) {
          throw new Error(
            `Could not generate a valid filename from theme name ${JSON.stringify(name)}`,
          );
        }

        const filePath = join(themesDir, `${slug}.json`);
        writeFileSync(filePath, JSON.stringify(theme, null, 2) + "\n", "utf8");

        return {
          content: [
            {
              type: "text",
              text: `Theme ${JSON.stringify(name)} saved to ${filePath}`,
            },
          ],
          details: {
            themePreview: theme,
            filePath,
            slug,
          },
        };
      },
    });
  };
}
