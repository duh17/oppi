import { describe, expect, it } from "vitest";

import { createSubagentsFactory, type SubagentsContext } from "./subagents.js";

function createContext(): SubagentsContext {
  return {
    workspaceId: "ws-1",
    sessionId: "parent-1",
    async spawnChild() {
      throw new Error("not used");
    },
    async spawnDetached() {
      throw new Error("not used");
    },
    listChildren() {
      return [];
    },
    getSession() {
      return undefined;
    },
    listWorkspaceSessions() {
      return [];
    },
    subscribe() {
      return () => {};
    },
    getAvailableModelIds() {
      return [];
    },
    async stopSession() {
      throw new Error("not used");
    },
    async resumeSession() {
      throw new Error("not used");
    },
    async sendMessage() {
      throw new Error("not used");
    },
  };
}

describe("subagents adapter", () => {
  it("loads the server subagents implementation and registers tools", async () => {
    const tools = new Map<string, unknown>();
    const factory = createSubagentsFactory(createContext());

    await factory({
      registerTool(tool: { name: string }) {
        tools.set(tool.name, tool);
      },
      on() {},
      sendMessage() {},
    } as never);

    expect([...tools.keys()].sort()).toEqual([
      "inspect_agent",
      "send_message",
      "spawn_agent",
      "stop_agent",
    ]);
  });
});
