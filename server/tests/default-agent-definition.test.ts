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
  it("ships the managed Oppi, ask, and read tools with a minimal prompt", async () => {
    const { buildDefaultAgentSystemPrompt } = await import("../src/default-agent.js");
    expect(DEFAULT_AGENT_TOOL_NAMES).toEqual(["oppi", "ask", "read"]);
    expect(DEFAULT_AGENT_DEFINITION).toMatchObject({
      name: "Oppi",
      description:
        "Manage Oppi workspaces, Agents, Skills, schedules, and sessions through the built-in oppi tool. Destructive actions need approval.",
      sessionDefaults: {
        noTools: "builtin",
        tools: ["oppi", "ask", "read"],
      },
    });
    const prompt = buildDefaultAgentSystemPrompt({ docsPath: "/tmp/oppi-docs" });
    expect(prompt).toContain("/tmp/oppi-docs");
    expect(prompt).toContain("You are Oppi, the control agent");
    expect(prompt).toContain("oppi help");
    expect(prompt).toContain("- read:");
    expect(prompt).not.toContain("OPERATING RULES");
    expect(prompt.length).toBeLessThan(1500);
  });

  it("always presents as Oppi and reconciles the safe tool list without losing other customization", () => {
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
          tools: ["oppi", "ask", "read"],
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
          name: "Oppi",
          icon: { kind: "emoji", value: "🏠" },
          description: "Customized description",
          instructions: { mode: "append", text: "Keep replies short." },
          resources: { noContextFiles: true },
          sessionDefaults: {
            model: "openai-codex/gpt-5.5",
            thinkingLevel: "high",
            noTools: "builtin",
            tools: ["oppi", "ask", "read"],
          },
        },
      });
      expect(store.getAgentVersion(DEFAULT_AGENT_ID, 3)?.definition.sessionDefaults).toEqual({
        noTools: "builtin",
        tools: ["oppi", "ask", "read"],
        model: "openai-codex/gpt-5.5",
        thinkingLevel: "high",
      });

      store.close();
      store = new AgentDefinitionStore(dataDir);
      expect(store.getAgent(DEFAULT_AGENT_ID)?.version).toBe(3);
    } finally {
      store.close();
    }
  });
});
