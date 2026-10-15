import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  DurableManifestError,
  bundledDurableExtensionPackages,
  discoverDurableExtensionPackages,
  loadDurableExtensions,
  readDurableManifest,
  type DurableExtensionPackage,
} from "../src/durable-extension-loader.js";

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), "oppi-durable-loader-"));
  dirs.push(dir);
  return dir;
}

/** A package directory with `package.json` and the given files. */
function writePackage(root: string, manifest: unknown, files: Record<string, string> = {}): string {
  mkdirSync(root, { recursive: true });
  writeFileSync(
    join(root, "package.json"),
    typeof manifest === "string" ? manifest : JSON.stringify(manifest),
  );
  for (const [name, body] of Object.entries(files)) writeFileSync(join(root, name), body);
  return root;
}

const EXTENSION = [
  'import { Type } from "typebox";',
  'import { defineExtension, defineTool } from "@earendil-works/pi-durable";',
  "export const probe = defineExtension({",
  '  name: "probe",',
  "  tools: [defineTool({",
  '    name: "probe_tool",',
  '    description: "Probe.",',
  "    parameters: Type.Object({}),",
  '    async execute() { return { output: [{ type: "text", text: "ok" }] }; },',
  "  })],",
  "});",
  "",
].join("\n");

async function load(manifest: unknown, entry: string) {
  const root = writePackage(join(tempDir(), "pkg"), manifest, { "durable.ts": entry });
  const found = readDurableManifest(root)!;
  return loadDurableExtensions([{ root, extensionIds: [], ...found }], {
    names: new Set(),
    tools: new Set(),
  });
}

describe("durable manifest", () => {
  it("loads a plain default-exported Extension from the declared entry, with the manifest's runtimes", async () => {
    const result = await load(
      { oppi: { durable: { entry: "./durable.ts", runtimes: ["host", "sandbox"] } } },
      `${EXTENSION}export default probe;\n`,
    );
    expect(result.errors).toEqual([]);
    expect(
      result.loaded.map((loaded) => ({
        name: loaded.extension.name,
        tools: loaded.extension.tools?.map((tool) => tool.name),
        runtimes: loaded.runtimes,
      })),
    ).toEqual([{ name: "probe", tools: ["probe_tool"], runtimes: ["host", "sandbox"] }]);
  });

  it("defaults runtimes to host and loads every extension of an array default export", async () => {
    const result = await load(
      { oppi: { durable: { entry: "./durable.ts" } } },
      `${EXTENSION}export default [probe, defineExtension({ name: "second" })];\n`,
    );
    expect(result.errors).toEqual([]);
    expect(result.loaded.map((loaded) => [loaded.extension.name, loaded.runtimes])).toEqual([
      ["probe", ["host"]],
      ["second", ["host"]],
    ]);
  });

  it("finds the TypeScript source of a .js entry", () => {
    const root = writePackage(
      join(tempDir(), "pkg"),
      { oppi: { durable: { entry: "./src/durable.js" } } },
      {},
    );
    mkdirSync(join(root, "src"));
    writeFileSync(join(root, "src", "durable.ts"), "export default {};\n");
    expect(readDurableManifest(root)?.entry).toBe(join(root, "src", "durable.ts"));
  });

  it("has no durable entry without `oppi.durable`, even with a durable.ts at the root", async () => {
    const root = writePackage(
      join(tempDir(), "pkg"),
      { name: "pkg", oppi: {} },
      {
        "durable.ts": `${EXTENSION}export default probe;\n`,
      },
    );
    expect(readDurableManifest(root)).toBeUndefined();

    const agentDir = tempDir();
    writePackage(
      join(agentDir, "extensions", "classic"),
      { name: "classic", pi: { extensions: ["./index.ts"] } },
      { "index.ts": "export default function () {}\n", "durable.ts": EXTENSION },
    );
    writePackage(
      join(agentDir, "extensions", "declared"),
      {
        name: "declared",
        pi: { extensions: ["./index.ts"] },
        oppi: { durable: { entry: "./durable.ts" } },
      },
      { "index.ts": "export default function () {}\n", "durable.ts": EXTENSION },
    );
    const discovered = await discoverDurableExtensionPackages(agentDir);
    expect(discovered.errors).toEqual([]);
    expect(discovered.packages.map((pkg) => pkg.root)).toEqual([
      join(agentDir, "extensions", "declared"),
    ]);
  });

  it.each([
    ["the pre-manifest string shape", { oppi: { durable: "./durable.ts" } }, "must be an object"],
    ["a non-object `oppi`", { oppi: "durable" }, "`oppi` must be an object"],
    [
      "an unknown key",
      { oppi: { durable: { entry: "./durable.ts", main: "x" } } },
      "unknown keys: main",
    ],
    ["no entry", { oppi: { durable: { runtimes: ["host"] } } }, "`oppi.durable.entry` must be"],
    ["a bare entry", { oppi: { durable: { entry: "durable.ts" } } }, 'starting with "./"'],
    [
      "an entry outside the package",
      { oppi: { durable: { entry: "./../durable.ts" } } },
      "inside the package",
    ],
    ["a missing entry file", { oppi: { durable: { entry: "./missing.ts" } } }, "missing file"],
    [
      "an unknown runtime",
      { oppi: { durable: { entry: "./durable.ts", runtimes: ["vm"] } } },
      "`oppi.durable.runtimes`",
    ],
    [
      "empty runtimes",
      { oppi: { durable: { entry: "./durable.ts", runtimes: [] } } },
      "`oppi.durable.runtimes`",
    ],
    [
      "a repeated runtime",
      { oppi: { durable: { entry: "./durable.ts", runtimes: ["host", "host"] } } },
      "once each",
    ],
    ["invalid JSON", "{ oppi: ", "not valid JSON"],
  ])("refuses %s with a DurableManifestError", (_label, manifest, message) => {
    const root = writePackage(join(tempDir(), "pkg"), manifest, { "durable.ts": EXTENSION });
    expect(() => readDurableManifest(root)).toThrow(DurableManifestError);
    expect(() => readDurableManifest(root)).toThrow(message);
  });

  it("reports a bundled package without a manifest as an error, not as classic-only", () => {
    const dir = tempDir();
    writePackage(join(dir, "ask"), { name: "ask" }, { "durable.ts": EXTENSION });
    const { packages, errors } = bundledDurableExtensionPackages(dir);
    expect(packages.map((pkg) => pkg.root)).not.toContain(join(dir, "ask"));
    expect(errors).toContainEqual(
      expect.objectContaining({
        root: join(dir, "ask"),
        message: "Bundled package ask has no `oppi.durable` manifest",
      }),
    );
  });
});

describe("durable entry default export", () => {
  it.each([
    [
      "the old { extension, runtimes } shape",
      "export default { extension: probe, runtimes: ['host'] };",
    ],
    ["a factory", "export default () => probe;"],
    ["an array with a non-extension", "export default [probe, 42];"],
    ["an empty array", "export default [];"],
    ["no default export", "export const other = probe;"],
  ])("refuses %s as a named load error", async (_label, line) => {
    const result = await load(
      { oppi: { durable: { entry: "./durable.ts" } } },
      `${EXTENSION}${line}\n`,
    );
    expect(result.loaded).toEqual([]);
    expect(result.errors).toEqual([
      expect.objectContaining({
        message: expect.stringMatching(
          /^The default export (must be a pi-durable Extension|is an empty array)/,
        ),
      }),
    ]);
  });

  it("loads a package whole or not at all when one of its extensions clashes", async () => {
    const root = writePackage(
      join(tempDir(), "pkg"),
      { oppi: { durable: { entry: "./durable.ts" } } },
      { "durable.ts": `${EXTENSION}export default [defineExtension({ name: "fine" }), probe];\n` },
    );
    const pkg: DurableExtensionPackage = { root, extensionIds: [], ...readDurableManifest(root)! };
    const result = await loadDurableExtensions([pkg], {
      names: new Set(),
      tools: new Set(["probe_tool"]),
    });
    expect(result.loaded).toEqual([]);
    expect(result.errors).toEqual([
      expect.objectContaining({
        message: 'Tool "probe_tool" is already offered by another extension',
      }),
    ]);
  });
});
