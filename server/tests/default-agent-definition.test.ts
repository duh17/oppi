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

describe("shipped Default Agent definition", () => {
  it("ships only the managed Oppi and ask tools", () => {
    expect(DEFAULT_AGENT_TOOL_NAMES).toEqual(["oppi", "ask"]);
    expect(DEFAULT_AGENT_DEFINITION.sessionDefaults).toEqual({
      noTools: "builtin",
      tools: ["oppi", "ask"],
    });
  });

  it("reconciles an existing install to the safe tool list without losing customization", () => {
    const dataDir = makeDataDir();
    let store = new AgentDefinitionStore(dataDir);
    const customized = store.updateAgent(
      DEFAULT_AGENT_ID,
      {
        name: "Home Agent",
        icon: "🏠",
        description: "Customized description",
        instructions: { mode: "append", text: "Keep replies short." },
        sessionDefaults: { model: "openai-codex/gpt-5.5", thinkingLevel: "high" },
      },
      200,
    );
    expect(customized?.version).toBe(2);
    store.close();

    const db = openDatabase(join(dataDir, "session-state.db"));
    db.prepare("UPDATE agent_definitions SET definition_json = ? WHERE id = ?").run(
      JSON.stringify({
        ...customized?.definition,
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
        name: "Home Agent",
        version: 3,
        definition: {
          name: "Home Agent",
          icon: "🏠",
          description: "Customized description",
          instructions: { mode: "append", text: "Keep replies short." },
          resources: { noContextFiles: true },
          sessionDefaults: {
            model: "openai-codex/gpt-5.5",
            thinkingLevel: "high",
            noTools: "builtin",
            tools: ["oppi", "ask"],
          },
        },
      });
      expect(store.getAgentVersion(DEFAULT_AGENT_ID, 3)?.definition.sessionDefaults).toEqual({
        noTools: "builtin",
        tools: ["oppi", "ask"],
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
