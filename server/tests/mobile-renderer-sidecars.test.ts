/**
 * Tests for sidecar discovery and loading in MobileRendererRegistry.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MobileRendererRegistry } from "../src/mobile-renderer.js";

let tempDir: string;

beforeEach(() => {
  tempDir = mkdtempSync(join(tmpdir(), "oppi-sidecar-test-"));
});

afterEach(() => {
  rmSync(tempDir, { recursive: true, force: true });
});

describe("discoverSidecars", () => {
  it("finds file sidecars (.mobile.ts)", () => {
    writeFileSync(join(tempDir, "memory.ts"), "// extension");
    writeFileSync(join(tempDir, "memory.mobile.ts"), "export default {}");

    const sidecars = MobileRendererRegistry.discoverSidecars(tempDir);
    expect(sidecars).toHaveLength(1);
    expect(sidecars[0]).toContain("memory.mobile.ts");
  });

  it("finds file sidecars (.mobile.js)", () => {
    writeFileSync(join(tempDir, "weather.js"), "// extension");
    writeFileSync(join(tempDir, "weather.mobile.js"), "module.exports = {}");

    const sidecars = MobileRendererRegistry.discoverSidecars(tempDir);
    expect(sidecars).toHaveLength(1);
    expect(sidecars[0]).toContain("weather.mobile.js");
  });

  it("finds directory sidecars (dir/mobile.ts)", () => {
    const extDir = join(tempDir, "my-ext");
    mkdirSync(extDir);
    writeFileSync(join(extDir, "index.ts"), "// extension");
    writeFileSync(join(extDir, "mobile.ts"), "export default {}");

    const sidecars = MobileRendererRegistry.discoverSidecars(tempDir);
    expect(sidecars).toHaveLength(1);
    expect(sidecars[0]).toContain("my-ext/mobile.ts");
  });

  it("prefers mobile.ts over mobile.js in directories", () => {
    const extDir = join(tempDir, "my-ext");
    mkdirSync(extDir);
    writeFileSync(join(extDir, "mobile.ts"), "export default {}");
    writeFileSync(join(extDir, "mobile.js"), "module.exports = {}");

    const sidecars = MobileRendererRegistry.discoverSidecars(tempDir);
    expect(sidecars).toHaveLength(1);
    expect(sidecars[0]).toMatch(/mobile\.ts$/);
  });

  it("returns empty for non-existent directory", () => {
    expect(MobileRendererRegistry.discoverSidecars("/non/existent")).toEqual([]);
  });

  it("ignores dotfiles", () => {
    writeFileSync(join(tempDir, ".hidden.mobile.ts"), "export default {}");
    expect(MobileRendererRegistry.discoverSidecars(tempDir)).toEqual([]);
  });

  it("ignores non-mobile files", () => {
    writeFileSync(join(tempDir, "memory.ts"), "// extension only");
    writeFileSync(join(tempDir, "README.md"), "# Docs");
    expect(MobileRendererRegistry.discoverSidecars(tempDir)).toEqual([]);
  });

  it("finds multiple sidecars", () => {
    writeFileSync(join(tempDir, "memory.mobile.ts"), "export default {}");
    writeFileSync(join(tempDir, "weather.mobile.js"), "module.exports = {}");
    const extDir = join(tempDir, "my-ext");
    mkdirSync(extDir);
    writeFileSync(join(extDir, "mobile.ts"), "export default {}");

    const sidecars = MobileRendererRegistry.discoverSidecars(tempDir);
    expect(sidecars).toHaveLength(3);
  });
});

describe("loadSidecar", () => {
  it("loads a valid .mobile.ts sidecar with typed renderers", async () => {
    const sidecarPath = join(tempDir, "test.mobile.ts");
    writeFileSync(sidecarPath, `
      interface Seg { text: string; style?: string; }
      const renderers: Record<string, { renderCall(args: Record<string, unknown>): Seg[]; renderResult(d: unknown, e: boolean): Seg[] }> = {
        my_tool: {
          renderCall(args: Record<string, unknown>): Seg[] {
            return [{ text: "my_tool ", style: "bold" }, { text: String(args.name || "") }];
          },
          renderResult(_details: unknown, isError: boolean): Seg[] {
            return [{ text: isError ? "fail" : "ok", style: isError ? "error" : "success" }];
          },
        },
      };
      export default renderers;
    `);

    const reg = new MobileRendererRegistry();
    const { loaded, errors } = await reg.loadSidecar(sidecarPath);

    expect(errors).toEqual([]);
    expect(loaded).toEqual(["my_tool"]);
    expect(reg.has("my_tool")).toBe(true);

    const segs = reg.renderCall("my_tool", { name: "test" });
    expect(segs).toBeDefined();
    expect(segs!.map((s) => s.text).join("")).toBe("my_tool test");
  });

  it("loads a valid .mobile.js sidecar (CommonJS)", async () => {
    const sidecarPath = join(tempDir, "test.mobile.js");
    writeFileSync(sidecarPath, `
      module.exports = {
        js_tool: {
          renderCall(args) { return [{ text: "js " + (args.x || "") }]; },
          renderResult(d, e) { return [{ text: e ? "err" : "ok" }]; },
        },
      };
    `);

    const reg = new MobileRendererRegistry();
    const { loaded, errors } = await reg.loadSidecar(sidecarPath);

    expect(errors).toEqual([]);
    expect(loaded).toEqual(["js_tool"]);
  });

  it("skips entries missing renderCall/renderResult", async () => {
    const sidecarPath = join(tempDir, "bad.mobile.ts");
    writeFileSync(sidecarPath, `
      export default {
        good: {
          renderCall() { return [{ text: "ok" }]; },
          renderResult() { return [{ text: "ok" }]; },
        },
        bad: {
          renderCall() { return []; },
          // missing renderResult
        },
      };
    `);

    const reg = new MobileRendererRegistry();
    const { loaded, errors } = await reg.loadSidecar(sidecarPath);

    expect(loaded).toEqual(["good"]);
    expect(errors).toHaveLength(1);
    expect(errors[0]).toContain("bad");
  });

  it("handles import error gracefully", async () => {
    const sidecarPath = join(tempDir, "broken.mobile.ts");
    writeFileSync(sidecarPath, "throw new Error('compilation failed');");

    const reg = new MobileRendererRegistry();
    const { loaded, errors } = await reg.loadSidecar(sidecarPath);

    expect(loaded).toEqual([]);
    expect(errors).toHaveLength(1);
    expect(errors[0]).toContain("compilation failed");
  });
});

describe("loadAllSidecars", () => {
  it("discovers and loads all sidecars from a directory", async () => {
    writeFileSync(join(tempDir, "ext1.mobile.ts"), `
      export default {
        tool_a: {
          renderCall() { return [{ text: "a" }]; },
          renderResult() { return [{ text: "a" }]; },
        },
      };
    `);
    writeFileSync(join(tempDir, "ext2.mobile.ts"), `
      export default {
        tool_b: {
          renderCall() { return [{ text: "b" }]; },
          renderResult() { return [{ text: "b" }]; },
        },
      };
    `);

    const reg = new MobileRendererRegistry();
    const { loaded, errors } = await reg.loadAllSidecars(tempDir);

    expect(errors).toEqual([]);
    expect(loaded.sort()).toEqual(["tool_a", "tool_b"]);
    expect(reg.has("tool_a")).toBe(true);
    expect(reg.has("tool_b")).toBe(true);
  });

  it("extension sidecars can override built-in renderers", async () => {
    writeFileSync(join(tempDir, "custom-bash.mobile.ts"), `
      export default {
        bash: {
          renderCall() { return [{ text: "custom bash" }]; },
          renderResult() { return [{ text: "custom result" }]; },
        },
      };
    `);

    const reg = new MobileRendererRegistry();
    expect(reg.has("bash")).toBe(true); // built-in

    await reg.loadAllSidecars(tempDir);

    const segs = reg.renderCall("bash", { command: "test" });
    expect(segs!.map((s) => s.text).join("")).toBe("custom bash"); // overridden
  });

  it("handles empty extensions directory", async () => {
    const reg = new MobileRendererRegistry();
    const { loaded, errors } = await reg.loadAllSidecars(tempDir);

    expect(loaded).toEqual([]);
    expect(errors).toEqual([]);
  });
});
