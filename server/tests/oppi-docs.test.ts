import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import * as PiSdk from "@earendil-works/pi-coding-agent";

import {
  appendOppiSystemPromptHint,
  buildOppiSystemPromptAppend,
  getOppiDocsPath,
} from "../src/oppi-docs.js";
import { SdkBackend } from "../src/sdk-backend.js";
import type { Session, Workspace } from "../src/types.js";

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: `sess-${Date.now()}`,
    workspaceId: "w1",
    status: "starting",
    createdAt: Date.now(),
    lastActivity: Date.now(),
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

describe("Oppi documentation prompt hint", () => {
  let cwd: string | undefined;

  afterEach(() => {
    if (cwd) {
      rmSync(cwd, { recursive: true, force: true });
      cwd = undefined;
    }
  });

  it("points at packaged Oppi extension compatibility docs", () => {
    const docsPath = getOppiDocsPath();

    expect(docsPath).toBeDefined();
    expect(buildOppiSystemPromptAppend()).toBe(
      `Oppi documentation for mobile-compatible Pi extensions: ${docsPath} (start with extensions.md and extension-native-ui.md).`,
    );
  });

  it("appends the hint only once", () => {
    const base = "Custom prompt.";
    const once = appendOppiSystemPromptHint(base);
    const twice = appendOppiSystemPromptHint(once);

    expect(once).toContain("Oppi documentation for mobile-compatible Pi extensions:");
    expect(twice).toBe(once);
  });

  it("adds the docs hint before workspace prompt text in host sessions", async () => {
    cwd = mkdtempSync(join(tmpdir(), "oppi-docs-prompt-"));
    mkdirSync(cwd, { recursive: true });
    writeFileSync(join(cwd, "README.md"), "# Workspace\n");

    const backend = await SdkBackend.create({
      session: makeSession(),
      workspace: {
        id: "w1",
        name: "Docs Prompt Test",
        runtime: "host",
        hostMount: cwd,
        systemPrompt: "Workspace-specific note.",
      } as Workspace,
      onEvent: () => {},
      onEnd: () => {},
    });

    try {
      const resourceLoader = (
        backend as unknown as {
          runtime: { services: { resourceLoader: PiSdk.ResourceLoader } };
        }
      ).runtime.services.resourceLoader;
      const appendPrompts = resourceLoader.getAppendSystemPrompt();

      expect(appendPrompts[0]).toContain("Oppi documentation for mobile-compatible Pi extensions:");
      expect(appendPrompts[1]).toBe("Workspace-specific note.");
    } finally {
      await backend.dispose();
    }
  });
});
