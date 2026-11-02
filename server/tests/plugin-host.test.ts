import { mkdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { defineExtension, defineTool } from "@earendil-works/pi-durable";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { obj } from "@earendil-works/pi-schema";
import { PluginHost } from "../src/plugin-host.js";
import { serverResourceId } from "../src/server-resource-id.js";
import { makeTempDir } from "./harness/temp-dir.js";

const hosts: PluginHost[] = [];
afterEach(async () => {
  await Promise.all(hosts.splice(0).map((host) => host.close()));
});

const codemode = defineExtension({
  name: "codemode",
  tools: [
    defineTool({
      name: "codemode",
      description: "core",
      parameters: obj({}),
      execute: async () => ({ output: [] }),
    }),
  ],
});

function write(path: string, text: string): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, text);
}

/** A `server.ts` facet whose extension's tools report `version` in their description. */
function facet(
  extension: string,
  tools: string[],
  options: { version?: string; runtimes?: string[]; extra?: string } = {},
): string {
  return [
    'import { defineExtension, defineFacet, defineTool, Extensions } from "oppi/v1";',
    'import { obj } from "oppi/v1/schema";',
    "const tools = [",
    ...tools.map(
      (name) =>
        `  defineTool({ name: ${JSON.stringify(name)}, description: ${JSON.stringify(options.version ?? "v1")}, parameters: obj({}), execute: async () => ({ output: [] }) }),`,
    ),
    "];",
    "export default defineFacet((host, self) => {",
    `  self.contribute(Extensions, defineExtension({ name: ${JSON.stringify(extension)}, tools${options.runtimes ? `, runtimes: ${JSON.stringify(options.runtimes)}` : ""} }));`,
    "});",
    options.extra ?? "",
  ].join("\n");
}

/** A directory plugin: `package.json` named `name` and a `server.ts`. */
function plugin(dir: string, name: string, source: string, manifest: object = {}): void {
  write(join(dir, "package.json"), JSON.stringify({ name, ...manifest }));
  write(join(dir, "server.ts"), source);
}

function fixture(options: { required?: string[]; builtIns: string[] }) {
  const base = makeTempDir("oppi-plugin-host-");
  const builtInDir = join(base, "built-in");
  const agentDir = join(base, "agent");
  mkdirSync(agentDir, { recursive: true });
  write(
    join(builtInDir, "package.json"),
    JSON.stringify({ name: "test-built-ins", private: true, chord: { plugins: options.builtIns } }),
  );
  const host = new PluginHost({
    builtInDir,
    agentDir,
    required: new Set(options.required ?? []),
    core: { first: [CodingTools], afterBuiltIns: [codemode] },
  });
  hosts.push(host);
  const installed = () =>
    host
      .registry()
      .snapshot()
      .installed()
      .map((extension) => extension.name);
  const description = (tool: string) =>
    host
      .registry()
      .snapshot()
      .tools()
      .find((entry) => entry.tool.name === tool)?.tool.description;
  return { builtInDir, agentDir, host, installed, description };
}

describe("plugin host", () => {
  it("installs built-ins in their listed order around the core, then the owner's plugins", async () => {
    const f = fixture({ builtIns: ["./zeta", "./alpha", "group/*", "!group/draft"] });
    plugin(join(f.builtInDir, "zeta"), "zeta", facet("zeta", ["zeta_tool"]));
    plugin(
      join(f.builtInDir, "alpha"),
      "alpha",
      facet("alpha", ["alpha_tool"], { runtimes: ["host", "sandbox"] }),
    );
    plugin(join(f.builtInDir, "group/one"), "one", facet("one", []));
    // Excluded: loading it would fail.
    plugin(join(f.builtInDir, "group/draft"), "draft", 'throw new Error("excluded");');
    // The owner's plugin root: a single-file plugin and a package listing its plugins.
    write(join(f.agentDir, "plugins/solo.server.ts"), facet("solo", ["solo_tool"]));
    write(
      join(f.agentDir, "plugins/repo/package.json"),
      JSON.stringify({ name: "repo", chord: { plugins: ["./inner"] } }),
    );
    plugin(join(f.agentDir, "plugins/repo/inner"), "inner", facet("inner", []));
    // A Pi package with a classic entry and a facet: its plugin carries the classic ID.
    const pkg = join(f.agentDir, "extensions/pkg");
    plugin(pkg, "pkg", facet("pkg", ["pkg_tool"]), { pi: { extensions: ["./index.ts"] } });
    write(join(pkg, "index.ts"), "export default function () {}\n");

    const report = await f.host.load();

    expect(report.errors).toEqual([]);
    expect(f.installed()).toEqual([
      "coding-tools",
      "zeta",
      "alpha",
      "one",
      "codemode",
      "inner",
      "solo",
      "pkg",
    ]);
    const byName = new Map(f.host.plugins.map((loaded) => [loaded.name, loaded]));
    expect(byName.get("alpha")).toMatchObject({
      source: "built-in",
      runtimes: ["host", "sandbox"],
    });
    expect(byName.get("zeta")?.runtimes).toEqual(["host"]);
    expect(byName.get("pkg")).toMatchObject({
      source: "owner",
      extensionIds: [serverResourceId("extension", realpathSync(join(pkg, "index.ts")))],
    });
  });

  it("refuses a new plugin that clashes with a loaded one, and keeps old code when new code breaks", async () => {
    const f = fixture({ builtIns: ["./jobs"] });
    // A built-in may replace a core tool; an owner plugin may not.
    plugin(join(f.builtInDir, "jobs"), "jobs", facet("jobs", ["bash"]));
    plugin(join(f.agentDir, "plugins/hello"), "hello", facet("hello", ["greet"]));
    write(join(f.agentDir, "plugins/shell.server.ts"), facet("shell", ["bash"]));
    const first = await f.host.load();
    expect(first.errors).toEqual([
      expect.objectContaining({
        plugin: "shell",
        message: 'Tool "bash" is taken by plugin "jobs"',
      }),
    ]);

    // A newcomer found first still loses to the plugin already loaded.
    plugin(join(f.agentDir, "plugins/aaa"), "aaa", facet("aaa", ["greet"]));
    plugin(
      join(f.agentDir, "plugins/hello"),
      "hello",
      facet("hello", ["greet"], { version: "v2" }),
    );
    const second = await f.host.reload();
    expect(second.errors).toContainEqual(
      expect.objectContaining({
        plugin: "aaa",
        message: 'Tool "greet" is taken by plugin "hello"',
      }),
    );
    expect(f.installed()).not.toContain("aaa");
    expect(f.description("greet")).toBe("v2");

    plugin(
      join(f.agentDir, "plugins/hello"),
      "hello",
      facet("hello", ["greet"], { version: "v3", extra: "export const = ;" }),
    );
    const broken = await f.host.reload();
    expect(broken.kept.map((loaded) => loaded.name)).toEqual(["hello"]);
    expect(broken.errors).toContainEqual(expect.objectContaining({ plugin: "hello" }));
    expect(f.description("greet")).toBe("v2");
  });

  it("counts an owner package named like a built-in as that built-in", async () => {
    const f = fixture({ builtIns: ["./ask"] });
    plugin(join(f.builtInDir, "ask"), "ask", facet("ask", ["ask"]));
    // The owner's Pi link to a checkout of the same feature.
    const linked = join(f.agentDir, "extensions/ask");
    plugin(linked, "ask", facet("ask", ["ask"], { version: "checkout" }), {
      pi: { extensions: ["./index.ts"] },
    });
    write(join(linked, "index.ts"), "export default function () {}\n");

    const report = await f.host.load();

    expect(report.errors).toEqual([]);
    expect(report.skipped).toEqual([
      expect.objectContaining({ message: '"ask" is built into Oppi' }),
    ]);
    expect(f.description("ask")).toBe("v1");
    expect([...f.host.classic.bundled]).toEqual([
      serverResourceId("extension", realpathSync(join(linked, "index.ts"))),
    ]);
  });

  it("fails the first load for a required built-in only", async () => {
    const optional = fixture({ builtIns: ["./core", "./extra"], required: ["core"] });
    plugin(join(optional.builtInDir, "core"), "core", facet("core", []));
    plugin(join(optional.builtInDir, "extra"), "extra", 'throw new Error("extra is broken");');
    const report = await optional.host.load();
    expect(report.errors).toEqual([
      expect.objectContaining({
        plugin: "extra",
        message: expect.stringContaining("extra is broken"),
      }),
    ]);
    expect(optional.installed()).toContain("core");

    const required = fixture({ builtIns: ["./core"], required: ["core"] });
    plugin(join(required.builtInDir, "core"), "core", 'throw new Error("core is broken");');
    await expect(required.host.load()).rejects.toThrow(/core is broken/);
  });

  it("uninstalls a removed owner plugin and keeps a required built-in whose folder is gone", async () => {
    const f = fixture({ builtIns: ["./core"], required: ["core"] });
    plugin(join(f.builtInDir, "core"), "core", facet("core", ["core_tool"]));
    write(join(f.agentDir, "plugins/gone.server.ts"), facet("gone", ["gone_tool"]));
    await f.host.load();

    rmSync(join(f.agentDir, "plugins/gone.server.ts"));
    rmSync(join(f.builtInDir, "core"), { recursive: true });
    const report = await f.host.reload();

    expect(report.removed).toEqual(["gone"]);
    expect(report.kept.map((loaded) => loaded.name)).toEqual(["core"]);
    expect(f.installed()).toEqual(["coding-tools", "core", "codemode"]);
  });

  it("serves host-owned extensions after the plugins and wakes the reader when they change", async () => {
    const f = fixture({ builtIns: ["./core"] });
    plugin(join(f.builtInDir, "core"), "core", facet("core", []));
    await f.host.load();
    let wakes = 0;
    const stop = f.host.registry().subscribe(() => wakes++);
    const mcp = defineExtension({ name: "oppi.mcp/s1" });

    f.host.install(mcp);
    expect(f.installed().at(-1)).toBe("oppi.mcp/s1");
    f.host.uninstall(mcp);
    expect(f.installed()).not.toContain("oppi.mcp/s1");
    expect(wakes).toBe(2);
    stop();
  });
});
