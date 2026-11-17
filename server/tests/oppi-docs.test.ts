import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import * as PiSdk from "@earendil-works/pi-coding-agent";

import { OPPI_CLI_SYSTEM_PROMPT_HINT } from "../src/oppi-cli-prompt.js";
import {
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
      getPromptHints: () => ({ oppiDocsPrompt: { enabled: true } }),
      getMobileOutputGuideSettings: () => ({ enabled: true, revision: 1 }),
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

  it("orders the docs hint, CLI hint, workspace prompt, then the guide in host sessions", async () => {
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
      getPromptHints: () => ({
        oppiDocsPrompt: { enabled: true },
        oppiCliPrompt: { enabled: true },
      }),
      getMobileOutputGuideSettings: () => ({ enabled: true, revision: 1 }),
      onEvent: () => {},
      onEnd: () => {},
    });

    try {
      const resourceLoader = (
        backend as unknown as {
          runtime: { services: { resourceLoader: PiSdk.ResourceLoader } };
        }
      ).runtime.services.resourceLoader;
      expect(resourceLoader.getAppendSystemPrompt()).toEqual([
        buildOppiSystemPromptAppend(),
        OPPI_CLI_SYSTEM_PROMPT_HINT,
        "Workspace-specific note.",
        buildMobileOutputGuide(),
      ]);
    } finally {
      await backend.dispose();
    }
  });
});

// The guide teaches agents the oppi:// links they write. Each one, with its placeholders filled, must
// be a decoding vector in protocol/links.json, whose every vector Apple PaneLinkCodecTests decodes:
// a link the guide shows always opens in the app.
describe("Mobile Output Guide links", () => {
  const SAMPLES: Record<string, string> = {
    "full-session-id": "11111111-1111-4111-8111-111111111111",
  };
  const vectors = (
    JSON.parse(
      readFileSync(new URL("../../protocol/links.json", import.meta.url), "utf8"),
    ) as { vectors: { input: string; route?: unknown }[] }
  ).vectors;

  it("shows only links the app's link codec decodes", () => {
    const links = buildMobileOutputGuide().match(/oppi:\/\/[^\s)]+/g) ?? [];
    expect(links.length).toBeGreaterThan(0);
    for (const link of links) {
      const example = link.replace(/<([^>]+)>/g, (_, name: string) => {
        const sample = SAMPLES[name];
        if (sample === undefined) throw new Error(`No sample value for <${name}> in ${link}`);
        return sample;
      });
      const vector = vectors.find((candidate) => candidate.input === example);
      expect(vector?.route, `${example} is not a decoding vector in protocol/links.json`).toBeDefined();
    }
  });
});
