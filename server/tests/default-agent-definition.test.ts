import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { AgentDefinitionStore } from "../src/agent-definitions.js";
import {
  DEFAULT_AGENT_DEFINITION,
  DEFAULT_AGENT_ID,
  DEFAULT_AGENT_TOOL_NAMES,
} from "../src/default-agent.js";
import { openDatabase } from "../src/sqlite-compat.js";

const dataDirs: string[] = [];

afterEach(() => {
  for (const dataDir of dataDirs.splice(0)) {
    rmSync(dataDir, { recursive: true, force: true });
  }
});

function makeDataDir(): string {
  const dataDir = mkdtempSync(join(tmpdir(), "oppi-default-agent-definition-"));
  dataDirs.push(dataDir);
  return dataDir;
}

describe("shipped Oppi agent definition", () => {
  it("ships the exact isolated Oppi Control tool set with a minimal prompt", async () => {
    const { buildDefaultAgentSystemPrompt } = await import("../src/default-agent.js");
    expect(DEFAULT_AGENT_TOOL_NAMES).toEqual([
      "oppi",
      "ask",
      "read",
      "edit",
      "write",
      "grep",
      "find",
      "ls",
    ]);
    expect(DEFAULT_AGENT_DEFINITION).toMatchObject({
      name: "Oppi",
      description:
        "Manage Oppi workspaces, Agents, Skills, schedules, and sessions. Oppi tool mutations follow server approval; stock filesystem edit/write run directly with host-process permissions.",
      sessionDefaults: {
        noTools: "builtin",
        tools: ["oppi", "ask", "read", "edit", "write", "grep", "find", "ls"],
      },
    });
    const prompt = buildDefaultAgentSystemPrompt({ docsPath: "/tmp/oppi-docs" });
    expect(prompt).toContain("/tmp/oppi-docs");
    expect(prompt).toContain("You are Oppi, the control agent");
    expect(prompt).toContain("oppi help");
    expect(prompt).toContain("- read:");
    expect(prompt).toContain("- edit:");
    expect(prompt).toContain("- write:");
    expect(prompt).toContain("- grep:");
    expect(prompt).toContain("- find:");
    expect(prompt).toContain("- ls:");
    expect(prompt).toContain("Only mutations through the oppi tool follow the server approval policy");
    expect(prompt).toContain("edit and write execute directly with host-process permissions");
    expect(prompt).not.toContain("Destructive actions need approval");
    expect(prompt).not.toContain("packaged Oppi docs only");
    expect(prompt).not.toContain("OPERATING RULES");
    expect(prompt.length).toBeLessThan(1800);
  });

  it("repairs stale persisted defaults by preserving only the icon, once", () => {
    const dataDir = makeDataDir();
    let store = new AgentDefinitionStore(dataDir);
    const customized = store.updateAgent(
      DEFAULT_AGENT_ID,
      {
        name: "Home Agent",
        icon: { kind: "emoji", value: "🏠" },
        description: "Customized description",
        instructions: { mode: "append", text: "Keep replies short." },
        sessionDefaults: { model: "openai-codex/gpt-5.5", thinkingLevel: "high" },
      },
      200,
    );
    // Name is part of the shipped identity and is not customizable.
    expect(customized).toMatchObject({
      name: "Oppi",
      version: 2,
      definition: {
        name: "Oppi",
        icon: { kind: "emoji", value: "🏠" },
        description: "Customized description",
        instructions: { mode: "append", text: "Keep replies short." },
        resources: { noContextFiles: true },
        sessionDefaults: {
          model: "openai-codex/gpt-5.5",
          thinkingLevel: "high",
          noTools: "builtin",
          tools: ["oppi", "ask", "read", "edit", "write", "grep", "find", "ls"],
        },
      },
    });
    store.close();

    const db = openDatabase(join(dataDir, "session-state.db"));
    db.prepare("UPDATE agent_definitions SET name = ?, definition_json = ? WHERE id = ?").run(
      "oppi-default-agent",
      JSON.stringify({
        ...customized?.definition,
        name: "oppi-default-agent",
        resources: { noContextFiles: false, extensionIds: ["unsafe-extension"] },
        sessionDefaults: {
          model: "openai-codex/gpt-5.5",
          thinkingLevel: "high",
          noTools: "all",
          tools: ["bash"],
        },
      }),
      DEFAULT_AGENT_ID,
    );
    db.close();

    store = new AgentDefinitionStore(dataDir);
    try {
      expect(store.getAgent(DEFAULT_AGENT_ID)).toMatchObject({
        name: "Oppi",
        version: 3,
        definition: {
          ...DEFAULT_AGENT_DEFINITION,
          icon: { kind: "emoji", value: "🏠" },
        },
      });
      expect(store.getAgentVersion(DEFAULT_AGENT_ID, 3)?.definition).toEqual({
        ...DEFAULT_AGENT_DEFINITION,
        icon: { kind: "emoji", value: "🏠" },
      });

      store.close();
      store = new AgentDefinitionStore(dataDir);
      expect(store.getAgent(DEFAULT_AGENT_ID)?.version).toBe(3);
    } finally {
      store.close();
    }
  });
});
