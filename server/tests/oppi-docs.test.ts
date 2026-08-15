import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import * as PiSdk from "@earendil-works/pi-coding-agent";

import { OPPI_CLI_SYSTEM_PROMPT_HINT } from "../src/oppi-cli-prompt.js";
import {
  appendOppiSystemPromptHint,
  buildMobileOutputGuide,
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
  it("describes supported Oppi rendering without prescribing response style", () => {
    const guide = buildMobileOutputGuide();

    expect(guide).toMatch(/^You are running in Oppi\.\n\nOppi rendering capabilities:/);
    expect(guide).toContain("[[path/to/file.ext#L12-L18|Label]]");
    expect(guide).toContain("![Description](path/to/image.svg)");
    expect(guide).toContain(
      "```mermaid\nflowchart TD\n  A[Start] --> B[Done]\n```",
    );
    expect(guide).not.toContain("\\nflowchart");
    expect(guide).toContain("$$x^2 + y^2 = z^2$$");
    expect(guide).toContain("fenced latex block");
    expect(guide).toContain("images, audio, video, PDF, HTML, Org, LaTeX, Mermaid, and Graphviz");
    expect(guide).toContain("oppi://session/<session-id>");
    expect(guide).toContain("real workspace-relative paths");
    expect(guide).not.toMatch(/lead with|be concise|short paragraphs|instead of|must use/i);
    expect(guide).not.toContain("screen dimension");
  });
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
      [
        "Oppi documentation (read only when asked about Oppi mobile/runtime behavior):",
        `- Docs directory: ${docsPath}`,
        `- Server configuration (ASR, TTS, config CLI): ${join(docsPath!, "server-configuration.md")}`,
        `- Extensions: ${join(docsPath!, "extensions.md")}`,
        `- Native extension UI: ${join(docsPath!, "extension-native-ui.md")}`,
        `- Attachment rendering: ${join(docsPath!, "attachment-rendering.md")}`,
        "- When working on Oppi topics, read the relevant docs completely and follow .md cross-references before implementing.",
      ].join("\n"),
    );
  });

  it("appends the hint only once", () => {
    const base = "Custom prompt.";
    const once = appendOppiSystemPromptHint(base);
    const twice = appendOppiSystemPromptHint(once);

    expect(once).toContain(
      "Oppi documentation (read only when asked about Oppi mobile/runtime behavior):",
    );
    expect(twice).toBe(once);
  });

  it("keeps the optional capability guide behind saved-Agent replacement authority", async () => {
    cwd = mkdtempSync(join(tmpdir(), "oppi-agent-replace-prompt-"));
    const backend = await SdkBackend.create({
      session: makeSession({ launch: { status: "launching", requestedAt: 1, agentId: "agent-1" } }),
      workspace: {
        id: "w1",
        name: "Agent Replace Test",
        runtime: "host",
        hostMount: cwd,
        systemPrompt: "Workspace-specific note.",
      } as Workspace,
      agentDefinition: {
        name: "Replacement Agent",
        instructions: { mode: "replace", text: "Saved-Agent replacement authority." },
      },
      getOppiExtensionSettings: () => ({
        enabled: false,
        approvalPolicy: "confirmDestructiveOnly",
        mobileOutputGuideEnabled: true,
        revision: 1,
      }),
      onEvent: () => {},
      onEnd: () => {},
    });

    try {
      const resourceLoader = (
        backend as unknown as {
          runtime: { services: { resourceLoader: PiSdk.ResourceLoader } };
        }
      ).runtime.services.resourceLoader;
      expect(resourceLoader.getSystemPrompt()).toBe("Saved-Agent replacement authority.");
      expect(resourceLoader.getAppendSystemPrompt()).toEqual([
        expect.stringContaining(
          "Oppi documentation (read only when asked about Oppi mobile/runtime behavior):",
        ),
        "Workspace-specific note.",
      ]);
      expect(resourceLoader.getAppendSystemPrompt()).not.toContain(buildMobileOutputGuide());
    } finally {
      await backend.dispose();
    }
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

      expect(appendPrompts[0]).toContain(
        "Oppi documentation (read only when asked about Oppi mobile/runtime behavior):",
      );
      expect(appendPrompts[1]).toBe("Workspace-specific note.");
    } finally {
      await backend.dispose();
    }
  });

  it("adds the concise CLI hint only when its experiment is enabled", async () => {
    cwd = mkdtempSync(join(tmpdir(), "oppi-cli-prompt-"));
    mkdirSync(cwd, { recursive: true });

    const backend = await SdkBackend.create({
      session: makeSession(),
      workspace: {
        id: "w1",
        name: "CLI Prompt Test",
        runtime: "host",
        hostMount: cwd,
      } as Workspace,
      onEvent: () => {},
      onEnd: () => {},
      serverConfig: { oppiDocsPrompt: { enabled: false }, oppiCliPrompt: { enabled: true } },
    });

    try {
      const resourceLoader = (
        backend as unknown as {
          runtime: { services: { resourceLoader: PiSdk.ResourceLoader } };
        }
      ).runtime.services.resourceLoader;

      expect(resourceLoader.getAppendSystemPrompt()).toEqual([OPPI_CLI_SYSTEM_PROMPT_HINT]);
      expect(OPPI_CLI_SYSTEM_PROMPT_HINT).toContain(
        "prompts an idle session and steers a busy session",
      );
      expect(OPPI_CLI_SYSTEM_PROMPT_HINT).toContain("--follow-up");
      expect(OPPI_CLI_SYSTEM_PROMPT_HINT).not.toContain("alias");
    } finally {
      await backend.dispose();
    }
  });

  it("does not add the docs hint when disabled in server settings", async () => {
    cwd = mkdtempSync(join(tmpdir(), "oppi-docs-disabled-"));
    mkdirSync(cwd, { recursive: true });

    const backend = await SdkBackend.create({
      session: makeSession(),
      workspace: {
        id: "w1",
        name: "Docs Disabled Test",
        runtime: "host",
        hostMount: cwd,
        systemPrompt: "Workspace-specific note.",
      } as Workspace,
      onEvent: () => {},
      onEnd: () => {},
      serverConfig: { oppiDocsPrompt: { enabled: false } },
    });

    try {
      const resourceLoader = (
        backend as unknown as {
          runtime: { services: { resourceLoader: PiSdk.ResourceLoader } };
        }
      ).runtime.services.resourceLoader;

      expect(resourceLoader.getAppendSystemPrompt()).toEqual(["Workspace-specific note."]);
    } finally {
      await backend.dispose();
    }
  });
});
