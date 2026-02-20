/**
 * Tests for renderer discovery and loading in MobileRendererRegistry.
 *
 * Renderers live in ~/.pi/agent/mobile-renderers/ (separate from extensions).
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MobileRendererRegistry } from "../src/mobile-renderer.js";

let tempDir: string;

beforeEach(() => {
  tempDir = mkdtempSync(join(tmpdir(), "oppi-renderer-test-"));
});

afterEach(() => {
  rmSync(tempDir, { recursive: true, force: true });
});

describe("discoverRenderers", () => {
  it("finds .ts files", () => {
    writeFileSync(join(tempDir, "memory.ts"), "export default {}");
    writeFileSync(join(tempDir, "weather.ts"), "export default {}");

    const files = MobileRendererRegistry.discoverRenderers(tempDir);
    expect(files).toHaveLength(2);
    expect(files[0]).toContain("memory.ts");
    expect(files[1]).toContain("weather.ts");
  });

  it("finds .js files", () => {
    writeFileSync(join(tempDir, "custom.js"), "module.exports = {}");

    const files = MobileRendererRegistry.discoverRenderers(tempDir);
    expect(files).toHaveLength(1);
    expect(files[0]).toContain("custom.js");
  });

  it("returns empty for non-existent directory", () => {
    expect(MobileRendererRegistry.discoverRenderers("/non/existent")).toEqual([]);
  });

  it("ignores dotfiles", () => {
    writeFileSync(join(tempDir, ".hidden.ts"), "export default {}");
    expect(MobileRendererRegistry.discoverRenderers(tempDir)).toEqual([]);
  });

  it("ignores non-ts/js files", () => {
    writeFileSync(join(tempDir, "README.md"), "# Docs");
    writeFileSync(join(tempDir, "config.json"), "{}");
    expect(MobileRendererRegistry.discoverRenderers(tempDir)).toEqual([]);
  });

  it("finds multiple renderer files", () => {
    writeFileSync(join(tempDir, "memory.ts"), "export default {}");
    writeFileSync(join(tempDir, "weather.js"), "module.exports = {}");
    writeFileSync(join(tempDir, "todos.ts"), "export default {}");

    const files = MobileRendererRegistry.discoverRenderers(tempDir);
    expect(files).toHaveLength(3);
  });
});

describe("loadRenderer", () => {
  it("loads a valid .ts renderer with typed renderers", async () => {
    const filePath = join(tempDir, "test.ts");
    writeFileSync(filePath, `
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
    const { loaded, errors } = await reg.loadRenderer(filePath);

    expect(errors).toEqual([]);
    expect(loaded).toEqual(["my_tool"]);
    expect(reg.has("my_tool")).toBe(true);

    const segs = reg.renderCall("my_tool", { name: "test" });
    expect(segs).toBeDefined();
    expect(segs!.map((s) => s.text).join("")).toBe("my_tool test");
  });

  it("loads a valid .js renderer (CommonJS)", async () => {
    const filePath = join(tempDir, "test.js");
    writeFileSync(filePath, `
      module.exports = {
        js_tool: {
          renderCall(args) { return [{ text: "js " + (args.x || "") }]; },
          renderResult(d, e) { return [{ text: e ? "err" : "ok" }]; },
        },
      };
    `);

    const reg = new MobileRendererRegistry();
    const { loaded, errors } = await reg.loadRenderer(filePath);

    expect(errors).toEqual([]);
    expect(loaded).toEqual(["js_tool"]);
  });

  it("skips entries missing renderCall/renderResult", async () => {
    const filePath = join(tempDir, "bad.ts");
    writeFileSync(filePath, `
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
    const { loaded, errors } = await reg.loadRenderer(filePath);

    expect(loaded).toEqual(["good"]);
    expect(errors).toHaveLength(1);
    expect(errors[0]).toContain("bad");
  });

  it("handles import error gracefully", async () => {
    const filePath = join(tempDir, "broken.ts");
    writeFileSync(filePath, "throw new Error('compilation failed');");

    const reg = new MobileRendererRegistry();
    const { loaded, errors } = await reg.loadRenderer(filePath);

    expect(loaded).toEqual([]);
    expect(errors).toHaveLength(1);
    expect(errors[0]).toContain("compilation failed");
  });
});

describe("loadAllRenderers", () => {
  it("discovers and loads all renderers from a directory", async () => {
    writeFileSync(join(tempDir, "memory.ts"), `
      export default {
        tool_a: {
          renderCall() { return [{ text: "a" }]; },
          renderResult() { return [{ text: "a" }]; },
        },
      };
    `);
    writeFileSync(join(tempDir, "todos.ts"), `
      export default {
        tool_b: {
          renderCall() { return [{ text: "b" }]; },
          renderResult() { return [{ text: "b" }]; },
        },
      };
    `);

    const reg = new MobileRendererRegistry();
    const { loaded, errors } = await reg.loadAllRenderers(tempDir);

    expect(errors).toEqual([]);
    expect(loaded.sort()).toEqual(["tool_a", "tool_b"]);
    expect(reg.has("tool_a")).toBe(true);
    expect(reg.has("tool_b")).toBe(true);
  });

  it("user renderers can override built-in renderers", async () => {
    writeFileSync(join(tempDir, "custom-bash.ts"), `
      export default {
        bash: {
          renderCall() { return [{ text: "custom bash" }]; },
          renderResult() { return [{ text: "custom result" }]; },
        },
      };
    `);

    const reg = new MobileRendererRegistry();
    expect(reg.has("bash")).toBe(true); // built-in

    await reg.loadAllRenderers(tempDir);

    const segs = reg.renderCall("bash", { command: "test" });
    expect(segs!.map((s) => s.text).join("")).toBe("custom bash"); // overridden
  });

  it("handles empty directory", async () => {
    const reg = new MobileRendererRegistry();
    const { loaded, errors } = await reg.loadAllRenderers(tempDir);

    expect(loaded).toEqual([]);
    expect(errors).toEqual([]);
  });
});
