import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { defineExtension, type ToolRegistration } from "@earendil-works/pi-durable";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import {
  resolveDurableAgent,
  toolAllowed,
  type DurableToolNarrowing,
} from "../src/durable-agent.js";
import { DurableMcp } from "../src/durable-mcp.js";
import { bindOppiHost } from "../src/durable-extension-api.js";
import { sandboxHost } from "../src/durable-sandbox-host.js";
import type { Session } from "../src/types.js";
import { DurableAsk } from "../extensions/durable/ask/durable.js";

// The sandbox tools' entry reads the host when it is evaluated, as the loader's import does.
bindOppiHost({
  sandbox: sandboxHost,
  sessions: () => undefined,
  control: () => undefined,
  notify: () => undefined,
});
const { default: DurableSandboxTools } =
  await import("../extensions/durable/sandbox-tools/durable.js");

type Policy = NonNullable<NonNullable<Session["launch"]>["tools"]>;

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

/** The tools a sandbox session launched with `policy` starts with, narrowed as a spawn asks. */
function toolsFor(policy: Policy, narrow?: DurableToolNarrowing): string[] {
  const { change } = resolveDurableAgent({
    ...(narrow ? { narrow } : {}),
    policy,
    runtime: "sandbox",
    base: [CodingTools, DurableSandboxTools, DurableAsk],
    loaded: [],
    classic: { bundled: new Set(), names: new Map() },
    enabled: () => true,
    sessions: defineExtension({ name: "oppi.sessions" }),
    spawn: false,
    grant: false,
    notify: defineExtension({ name: "oppi.notify" }),
    notifies: false,
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

  it("narrows a spawn's tools and never widens them past the parent's", () => {
    // readOnly keeps Pi's read and bash, whatever the parent offers beyond them.
    expect(toolsFor({}, { parentTools: ["read", "bash", "ask", "ls"], readOnly: true })).toEqual([
      "bash",
      "read",
    ]);
    // An intersection: a tool the parent lacks is dropped, an excluded one is dropped.
    expect(toolsFor({}, { parentTools: ["read", "ask"], tools: ["read", "ask", "ls"] })).toEqual([
      "ask",
      "read",
    ]);
    expect(toolsFor({}, { parentTools: ["read", "ask"], excludeTools: ["ask"] })).toEqual(["read"]);
    // readOnly and tools intersect: readOnly never adds the tools the caller did not name.
    expect(
      toolsFor(
        {},
        { parentTools: ["read", "bash", "ask"], tools: ["read", "ask"], readOnly: true },
      ),
    ).toEqual(["read"]);
  });

  it("excludeTools removes only what it names, so a later MCP tool is not dropped", () => {
    const narrow: DurableToolNarrowing = {
      parentTools: ["read", "write", "ask"],
      excludeTools: ["write"],
    };
    expect(toolsFor({}, narrow)).toEqual(["ask", "read"]);
    const { change, doc } = resolveDurableAgent({
      narrow,
      runtime: "sandbox",
      base: [CodingTools, DurableSandboxTools, DurableAsk],
      loaded: [],
      classic: { bundled: new Set(), names: new Map() },
      enabled: () => true,
      sessions: defineExtension({ name: "oppi.sessions" }),
      spawn: false,
      grant: false,
      notify: defineExtension({ name: "oppi.notify" }),
      notifies: false,
    });
    expect(change.tools.map((tool) => tool.name).sort()).toEqual(["ask", "read"]);
    // The policy is not an allow list: a tool this session only gets at attach still passes.
    expect(toolAllowed(doc.tools, "write")).toBe(false);
    expect(toolAllowed(doc.tools, "mcp_echo_run")).toBe(true);
    expect(toolAllowed(doc.tools, "notify")).toBe(true);
    // What the parent did not offer is excluded by name, so nothing can widen the child later.
    for (const absent of ["bash", "edit", "ls"])
      expect(toolAllowed(doc.tools, absent), absent).toBe(false);
  });

  it("caps a saved Agent's package tool at spawn when the parent lacks it", () => {
    // The child's own package offers `pkg_only`; the spawning session never had that tool.
    const packageTool = { name: "pkg_only" } as unknown as ToolRegistration;
    const pkg = defineExtension({ name: "pkg", tools: [packageTool] });
    const extensionId = "pkg.ext";
    const { change, doc } = resolveDurableAgent({
      saved: {
        id: "agent-1",
        version: 1,
        definition: {
          name: "Packaged",
          resources: { extensionIds: [extensionId] },
          sessionDefaults: { excludeTools: ["write"] },
        },
      },
      narrow: { parentTools: ["read", "ask"], excludeTools: ["bash"] },
      runtime: "sandbox",
      base: [CodingTools, DurableAsk],
      loaded: [
        {
          extension: pkg,
          runtimes: ["sandbox"],
          root: "/tmp/pkg",
          entry: "/tmp/pkg/durable.js",
          extensionIds: [extensionId],
        },
      ],
      classic: { bundled: new Set(), names: new Map() },
      enabled: () => true,
      sessions: defineExtension({ name: "oppi.sessions" }),
      spawn: false,
      grant: false,
      notify: defineExtension({ name: "oppi.notify" }),
      notifies: false,
    });
    // It starts with the parent's intersection only.
    expect(change.tools.map((tool) => tool.name).sort()).toEqual(["ask", "read"]);
    // The stored policy carries the cap, so an attach that loads `pkg` cannot add it back.
    expect(toolAllowed(doc.tools, "pkg_only")).toBe(false);
    expect(doc.tools?.excluded).toContain("pkg_only");
    // A tool that only exists at attach is still allowed.
    expect(toolAllowed(doc.tools, "mcp_echo_run")).toBe(true);
  });

  it("stores the narrowed list as the tool policy, so a later attach cannot widen it", async () => {
    const { doc, change } = resolveDurableAgent({
      narrow: { parentTools: ["read", "bash", "ask"], readOnly: true },
      runtime: "sandbox",
      base: [CodingTools, DurableSandboxTools, DurableAsk],
      loaded: [],
      classic: { bundled: new Set(), names: new Map() },
      enabled: () => true,
      sessions: defineExtension({ name: "oppi.sessions" }),
      spawn: false,
      grant: false,
      notify: defineExtension({ name: "oppi.notify" }),
      notifies: false,
    });
    expect(change.tools.map((tool) => tool.name).sort()).toEqual(["bash", "read"]);
    expect(doc.tools).toEqual({ allowed: ["read", "bash"] });
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
