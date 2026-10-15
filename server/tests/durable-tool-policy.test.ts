import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { defineExtension } from "@earendil-works/pi-durable";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { resolveDurableAgent } from "../src/durable-agent.js";
import { DurableMcp } from "../src/durable-mcp.js";
import { bindOppiHost } from "../src/durable-extension-api.js";
import { sandboxHost } from "../src/durable-sandbox-host.js";
import type { Session } from "../src/types.js";
import { DurableAsk } from "../extensions/durable/ask/durable.js";

// The sandbox tools' entry reads the host when it is evaluated, as the loader's import does.
bindOppiHost({ sandbox: sandboxHost, sessions: () => undefined, control: () => undefined });
const { default: DurableSandboxTools } =
  await import("../extensions/durable/sandbox-tools/durable.js");

type Policy = NonNullable<NonNullable<Session["launch"]>["tools"]>;

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

/** The tools a sandbox session launched with `policy` starts with. */
function toolsFor(policy: Policy): string[] {
  const { change } = resolveDurableAgent({
    policy,
    runtime: "sandbox",
    base: [CodingTools, DurableSandboxTools, DurableAsk],
    loaded: [],
    sessions: defineExtension({ name: "oppi.sessions" }),
    spawn: false,
    grant: false,
  });
  return change.tools.map((tool) => tool.name).sort();
}

describe("durable tool policy, as Pi's createAgentSession", () => {
  it("noTools builtin drops Pi's built-in tools and keeps extension tools", () => {
    expect(toolsFor({ noTools: "builtin" })).toEqual(["ask"]);
  });

  it("noTools all enables nothing; an allow list is the enabled set, minus excluded", () => {
    expect(toolsFor({ noTools: "all" })).toEqual([]);
    expect(toolsFor({ noTools: "all", allowed: ["ask", "read"] })).toEqual(["ask", "read"]);
    expect(toolsFor({ noTools: "builtin", allowed: ["read", "ask"], excluded: ["ask"] })).toEqual([
      "read",
    ]);
  });

  it("opens MCP for noTools builtin and for an allow list under noTools all, not for all alone", async () => {
    const agentDir = mkdtempSync(join(tmpdir(), "oppi-durable-tool-policy-"));
    dirs.push(agentDir);
    writeFileSync(
      join(agentDir, "mcp.json"),
      JSON.stringify({ mcpServers: { echo: { command: "/nonexistent/mcp-server" } } }),
    );
    const open = (policy: Policy) =>
      DurableMcp.open({
        sessionId: "s1",
        cwd: agentDir,
        agentDir,
        projectTrusted: false,
        policy,
        providerToken: async () => undefined,
        install: () => {},
        uninstall: () => {},
      });

    expect(await open({ noTools: "all" })).toBeUndefined();
    for (const policy of [
      { noTools: "builtin" },
      { noTools: "all", allowed: ["mcp__echo__ping"] },
    ] as const) {
      const mcp = await open(policy);
      expect(mcp, JSON.stringify(policy)).toBeDefined();
      await mcp?.close();
    }
  });
});
