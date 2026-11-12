import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

/** The real `oppi` entry point, as an agent's shell runs it. */
async function oppi(
  args: string[],
  options: { cwd: string; stdin?: string },
): Promise<{ exit: number | null; stdout: string; stderr: string }> {
  const child = spawn("bun", [join(import.meta.dirname, "..", "src", "cli.ts"), ...args], {
    cwd: options.cwd,
    env: { ...process.env, NO_COLOR: "1" },
    stdio: ["pipe", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8").on("data", (text: string) => (stdout += text));
  child.stderr.setEncoding("utf8").on("data", (text: string) => (stderr += text));
  child.stdin.end(options.stdin ?? "");
  const exit = await new Promise<number | null>((resolve) => child.on("close", resolve));
  return { exit, stdout, stderr };
}

function checkout(): string {
  const root = mkdtempSync(join(tmpdir(), "oppi-cli-layout-"));
  roots.push(root);
  mkdirSync(join(root, ".oppi", "layouts"), { recursive: true });
  mkdirSync(join(root, "src"));
  writeFileSync(join(root, "src", "auth.ts"), "export {};\n");
  return root;
}

const REVIEW = JSON.stringify({
  v: 1,
  title: "Review auth fix",
  root: {
    split: "row",
    children: [
      { pane: "chat", chat: "self" },
      {
        split: "column",
        children: [
          { pane: "code", file: "src/auth.ts", line: 20 },
          { pane: "notes", file: "/Users/alex/notes/plan.md", syntax: "md" },
        ],
      },
    ],
  },
  focus: "chat",
});

describe("oppi layout check", () => {
  it("reads a layout from stdin exactly as from its file", async () => {
    const root = checkout();
    writeFileSync(join(root, ".oppi", "layouts", "review.json"), REVIEW);

    const fromFile = await oppi(["layout", "check", ".oppi/layouts/review.json", "--json"], {
      cwd: root,
    });
    const fromStdin = await oppi(["layout", "check", "-", "--json"], { cwd: root, stdin: REVIEW });
    expect(fromFile.exit).toBe(0);
    expect(fromStdin).toEqual(fromFile);

    const data = JSON.parse(fromFile.stdout).data;
    expect(data.valid).toBe(true);
    expect(data.warnings.map((w: { code: string; path: string }) => `${w.code} ${w.path}`)).toEqual(
      [
        "unknownField root.children[1].children[1].syntax",
        "absolutePath root.children[1].children[1].file",
        "value root.children[1].children[1].file",
      ],
    );
  });

  it("lists the panes and warns about a machine-bound path", async () => {
    const root = checkout();
    writeFileSync(join(root, ".oppi", "layouts", "review.json"), REVIEW);

    const { exit, stdout } = await oppi(["layout", "check", ".oppi/layouts/review.json"], {
      cwd: root,
    });
    expect(exit).toBe(0);
    expect(stdout).toContain("review.json: valid (layout version 1) · Review auth fix");
    expect(stdout).toMatch(/chat\s+Chat\s+this chat/);
    expect(stdout).toMatch(/code\s+File\s+src\/auth\.ts:20/);
    expect(stdout).toContain(
      "warning: root.children[1].children[1].file: an absolute path ties this layout to one machine",
    );
  });

  it("exits 1 naming each problem's path and what is allowed there", async () => {
    const root = checkout();
    const broken = {
      v: 1,
      title: "Broken",
      root: { split: "row", children: [{ pane: "chat", chat: "self" }] },
      focus: "chat",
    };
    writeFileSync(join(root, ".oppi", "layouts", "broken.json"), JSON.stringify(broken));

    const human = await oppi(["layout", "check", ".oppi/layouts/broken.json"], { cwd: root });
    expect(human.exit).toBe(1);
    expect(human.stdout).toContain("broken.json: 1 problem");
    expect(human.stdout).toContain("root: a split needs 2 to 8 children, found 1");

    const web = await oppi(["layout", "check", "-", "--json"], {
      cwd: root,
      stdin: JSON.stringify({
        v: 1,
        title: "Preview",
        root: { pane: "site", web: "http://localhost:5173/" },
        focus: "site",
      }),
    });
    expect(web.exit).toBe(1);
    expect(JSON.parse(web.stdout).data.problems).toEqual([
      expect.objectContaining({ code: "webLoopback", path: "root.web" }),
    ]);
  });
});
