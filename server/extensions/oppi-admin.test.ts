import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { Storage } from "../src/storage.js";
import { createOppiAdminFactory } from "./oppi-admin.js";

type RegisteredTool = {
  name: string;
  execute: (
    toolCallId: string,
    params: Record<string, unknown>,
  ) => Promise<{ content: Array<{ type: string; text: string }>; details?: unknown }>;
};

function createMockAPI(): {
  tools: Map<string, RegisteredTool>;
  registerTool(tool: RegisteredTool): void;
  registerCommand(name: string, command: unknown): void;
} {
  return {
    tools: new Map(),
    registerTool(tool) {
      this.tools.set(tool.name, tool);
    },
    registerCommand() {
      // not needed
    },
  };
}

describe("createOppiAdminFactory", () => {
  let tempDir: string;
  let oldHome: string | undefined;

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "oppi-admin-ext-"));
    oldHome = process.env.HOME;
    process.env.HOME = tempDir;
  });

  afterEach(() => {
    if (oldHome === undefined) {
      delete process.env.HOME;
    } else {
      process.env.HOME = oldHome;
    }
    rmSync(tempDir, { recursive: true, force: true });
  });

  it("creates and lists workspaces", async () => {
    const storage = new Storage(tempDir);
    const api = createMockAPI();
    createOppiAdminFactory(storage)(api as never);

    const createTool = api.tools.get("oppi_admin_create_workspace");
    const listTool = api.tools.get("oppi_admin_list_workspaces");
    expect(createTool).toBeDefined();
    expect(listTool).toBeDefined();

    await createTool!.execute("tc1", {
      name: "oppi-admin",
      skills: ["oppi-admin"],
      hostMount: "~/workspace/oppi-admin",
      extensions: ["oppi-admin"],
    });

    const result = await listTool!.execute("tc2", {});
    const details = result.details as { workspaces: Array<{ name: string }> };
    expect(details.workspaces.some((workspace) => workspace.name === "oppi-admin")).toBe(true);
  });

  it("builds a theme into ~/.config/oppi/themes", async () => {
    const storage = new Storage(tempDir);
    const api = createMockAPI();
    createOppiAdminFactory(storage)(api as never);

    const tool = api.tools.get("build_theme");
    expect(tool).toBeDefined();

    const colors = Object.fromEntries(
      [
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
      ].map((key) => [key, "#112233"]),
    );

    const result = await tool!.execute("tc3", {
      name: "Admin Theme",
      colorScheme: "dark",
      colors,
    });

    const details = result.details as { filePath: string };
    expect(readFileSync(details.filePath, "utf8")).toContain('"name": "Admin Theme"');
  });
});
