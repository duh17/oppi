import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { DurableHarness } from "../src/durable-harness.js";
import { BUNDLED_PACKAGES_DIR } from "../src/durable-extension-loader.js";

const runtimes: DurableHarness[] = [];
const dirs: string[] = [];
afterEach(async () => {
  await Promise.all(runtimes.splice(0).map((runtime) => runtime.closeAll()));
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

describe("bundled durable packages", () => {
  it("reloads a built-in in place, and keeps its running code when the reload fails", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-durable-builtin-reload-"));
    dirs.push(dir);
    // A copy of Oppi's bundled packages with real files, so one can change under the runtime.
    const bundled = join(dir, "bundled");
    cpSync(BUNDLED_PACKAGES_DIR, bundled, { recursive: true, dereference: true });
    const entry = join(bundled, "project-context", "durable.ts");
    const original = readFileSync(entry, "utf8");

    const runtime = new DurableHarness(join(dir, "data"), bundled);
    runtimes.push(runtime);
    const { registry } = await runtime.ensureShared();
    const installed = () =>
      registry
        .snapshot()
        .installed()
        .map((extension) => extension.name);
    const order = installed();
    const host = await runtime.openHost("reload", { cwd: dir });
    const { harness } = await host.open();
    const conversation = await harness.createConversation(
      { ownership: { kind: "ownerless" }, agent: { extensions: runtime.builtInsFor("host") } },
      context,
    );
    const sections = async () =>
      (await conversation.agent(context)).sections.map((section) => section.key);
    expect(await sections()).not.toContain("reload_probe");

    writeFileSync(
      entry,
      original.replace("sections: [", 'sections: [section("reload_probe", () => "v2"),'),
    );
    const reloaded = await runtime.reloadExtensions();
    expect(reloaded.errors).toEqual([]);
    expect(reloaded.loaded).toContainEqual(
      expect.objectContaining({ name: "project-context", builtIn: true }),
    );
    // Replaced under its name: the next resolution uses the new code, in the same place.
    expect(await sections()).toContain("reload_probe");
    expect(installed()).toEqual(order);

    writeFileSync(entry, "export default {\n");
    const broken = await runtime.reloadExtensions();
    expect(broken.errors).toEqual([
      expect.objectContaining({ root: join(bundled, "project-context") }),
    ]);
    expect(broken.kept).toEqual([
      expect.objectContaining({ name: "project-context", builtIn: true }),
    ]);
    expect(await sections()).toContain("reload_probe");
    expect(installed()).toEqual(order);
  });

  it("refuses to open the runtime when a built-in fails its first load", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-durable-builtin-broken-"));
    dirs.push(dir);
    const bundled = join(dir, "bundled");
    cpSync(BUNDLED_PACKAGES_DIR, bundled, { recursive: true, dereference: true });
    writeFileSync(join(bundled, "sessions", "durable.ts"), "export default 42;\n");
    const runtime = new DurableHarness(join(dir, "data"), bundled);
    runtimes.push(runtime);
    await expect(runtime.ensureShared()).rejects.toThrow(
      /bundled durable extensions failed to load: .*sessions.*The default export must be a pi-durable Extension/,
    );
  });
});
