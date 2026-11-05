import { describe, expect, it } from "vitest";
import { createJobsPanel, type PanelJob } from "../plugins/background-jobs/panel.js";
import type { ExtensionUISurface, ExtensionUISurfaceNode } from "../src/types.js";

/**
 * The jobs panel as the host receives it. Every case goes through `render`, which runs the host's
 * own validator, so a view over a wire limit fails here instead of being dropped on a phone.
 */

const AT = 1_700_000_000_000;

function job(id: string, overrides: Partial<PanelJob> = {}): PanelJob {
  return { id, command: `run ${id}`, status: "running", startedAt: AT - 5_000, ...overrides };
}

/** Every word the nodes under `node` carry, in tree order. */
function words(node: ExtensionUISurfaceNode): string[] {
  const own = "text" in node && typeof node.text === "string" ? [node.text] : [];
  return [...own, ...("children" in node ? node.children.flatMap(words) : [])];
}

function render(jobs: PanelJob[]): ExtensionUISurface {
  return createJobsPanel().surface.render({ jobs, at: AT });
}

function find(node: ExtensionUISurfaceNode, id: string): ExtensionUISurfaceNode | undefined {
  if (node.id === id) return node;
  if ("children" in node)
    for (const child of node.children) {
      const found = find(child, id);
      if (found) return found;
    }
  return undefined;
}

function body(surface: ExtensionUISurface): ExtensionUISurfaceNode {
  const [section] = surface.sections;
  if (section?.composite !== "blocks") throw new Error("expected a blocks section");
  return section.body;
}

describe("background jobs panel view", () => {
  it("offers Stop on a running job only, with the job named in the tap", () => {
    const surface = render([job("bash-1"), job("bash-2", { status: "completed", exitCode: 0 })]);
    expect(find(body(surface), "stop:bash-1")).toMatchObject({
      type: "button",
      title: "Stop",
      action: { id: "stop", values: { job: "bash-1" } },
    });
    expect(find(body(surface), "stop:bash-2")).toBeUndefined();
    expect(surface.actions.stop).toMatchObject({ title: "Stop", pending: { title: "Stopping…" } });
    expect(Object.keys(surface.actions)).toEqual(["stop"]);
  });

  it("titles a row by what the job runs, and keeps the full command behind the fold", () => {
    const command =
      "cd ~/work/app && bun ~/tools/scripts/land.ts run --workspace web --owner 4f1c9d2e-7b3a 2>&1 | tail -8";
    const surface = render([job("bash-262", { command })]);
    const list = body(surface);
    expect(find(list, "title:bash-262")).toMatchObject({ text: "bun land.ts run" });
    // The id and the age are the secondary line; nothing before the fold repeats the command.
    expect(find(list, "meta:bash-262")).toMatchObject({ text: "bash-262 · Running <1m" });
    const folded = find(list, "output:bash-262");
    expect(folded).toMatchObject({ type: "group", collapsed: true });
    const outside = words(list).filter((word) => !words(folded!).includes(word));
    expect(outside.join("\n")).not.toContain("4f1c9d2e");
    expect(find(folded!, "command:bash-262")).toMatchObject({
      type: "text",
      style: "mono",
      text: expect.stringContaining("--owner 4f1c9d2e"),
    });
    // The header and the pill say how many jobs run, never which command.
    expect(JSON.stringify([surface.header, surface.pill])).not.toContain("land.ts");
  });

  it.each([
    ["cd /tmp; ls -la", "ls"],
    ["cd 'my dir' && cd sub && npm test -- --run src/panel", "npm test"],
    ["API_KEY=x NODE_ENV=test make -j4 all", "make"],
    ["./scripts/release.sh --dry-run", "release.sh"],
    ["sleep 30", "sleep 30"],
    ["cd /tmp", "cd /tmp"],
    ["a-very-long-program-name-that-keeps-going-and-going", "a-very-long-program-nam…"],
  ])("names %j as %j", (command, title) => {
    expect(find(body(render([job("bash-1", { command })])), "title:bash-1")).toMatchObject({
      text: title,
    });
  });

  it("shows how long a running job has run, in whole minutes", () => {
    const jobs = [
      job("bash-1", { startedAt: AT - (65 * 60_000 + 30_000) }),
      job("bash-2", { startedAt: AT - 12 * 60_000 }),
    ];
    const list = body(render(jobs));
    expect(find(list, "meta:bash-1")).toMatchObject({ text: "bash-1 · Running 1h 5m" });
    expect(find(list, "meta:bash-2")).toMatchObject({ text: "bash-2 · Running 12m" });
  });

  it("says how each finished job ended, by exit status when it has one", () => {
    const list = body(
      render([
        job("ok", { status: "completed", exitCode: 0 }),
        job("bad", { status: "failed", exitCode: 2 }),
        job("lost", { status: "failed", exitCode: null }),
        job("stopped", { status: "cancelled" }),
        job("slow", { status: "timed_out" }),
      ]),
    );
    const meta = (id: string) => (find(list, `meta:${id}`) as { text: string }).text;
    expect(meta("ok")).toBe("ok · Exit 0");
    expect(meta("bad")).toBe("bad · Exit 2");
    expect(meta("lost")).toBe("lost · Failed");
    expect(meta("stopped")).toBe("stopped · Stopped");
    expect(meta("slow")).toBe("slow · Timed out");
    // Success and failure differ by more than colour: the glyph is another shape.
    const glyph = (id: string) => (find(list, `status:${id}`) as { name: string }).name;
    expect(new Set(["ok", "bad", "stopped", "slow"].map(glyph)).size).toBe(4);
    expect(glyph("ok")).toContain("checkmark");
    expect(glyph("bad")).toContain("xmark");
  });

  it("counts the jobs in the pill and the header, running first", () => {
    const pillWords = (surface: ExtensionUISurface) =>
      surface.pill ? words(surface.pill.content) : [];
    const running = render([job("a")]);
    expect(pillWords(running)[0]).toBe("1 job running");
    expect(running.header).toEqual({ title: "Background jobs", subtitle: "1 running" });
    const mixed = render([job("a", { status: "completed", exitCode: 0 }), job("b")]);
    expect(pillWords(mixed)[0]).toBe("2 jobs · 1 running");
    expect(mixed.header.subtitle).toBe("1 running · 1 finished");
    const done = render([job("a", { status: "completed", exitCode: 0 })]);
    expect(pillWords(done)).toEqual(["1 job finished"]);
    expect(done.header.subtitle).toBe("1 finished");
    expect(pillWords(render([job("a"), job("b")]))[0]).toBe("2 jobs running");
  });

  it("folds each job's output tail away, plain and cut to the node cap", () => {
    const output = [
      "\u001b[32mgreen\u001b[0m start",
      "progress 10%\rprogress 100%",
      ...Array.from({ length: 40 }, (_, index) => `line ${index} ${"x".repeat(60)}`),
    ].join("\n");
    const surface = render([job("bash-1", { status: "completed", exitCode: 0, output })]);
    const group = find(body(surface), "output:bash-1");
    expect(group).toMatchObject({ type: "group", collapsed: true });
    const tail = find(body(surface), "tail:bash-1");
    // The block says what it holds in its header: output, not source.
    expect(tail).toMatchObject({ type: "code", language: "output" });
    const text = (tail as { text: string }).text;
    expect(Array.from(text).length).toBeLessThanOrEqual(480);
    expect(text).toContain("line 39");
    expect(text).not.toContain("\u001b");
    // A run that never finished has saved no output yet, and says so.
    expect(find(body(render([job("bash-2")])), "tail:bash-2")).toMatchObject({
      type: "text",
      text: "No output yet",
    });
  });

  it("lists running jobs first and counts what it cannot draw", () => {
    const jobs = [
      ...Array.from({ length: 6 }, (_, index) =>
        job(`done-${index}`, { status: "completed", exitCode: 0 }),
      ),
      ...Array.from({ length: 8 }, (_, index) => job(`run-${index}`)),
    ];
    const surface = render(jobs);
    const list = body(surface);
    if (list.type !== "stack") throw new Error("expected a stack");
    // Eleven jobs and a count of the three left out: the eight that run come first.
    expect(list.children).toHaveLength(12);
    expect(list.children.slice(0, 8).map((child) => child.id)).toEqual(
      Array.from({ length: 8 }, (_, index) => `job:run-${index}`),
    );
    expect(find(list, "more")).toMatchObject({ text: "+3 more" });
    expect(surface.header.subtitle).toBe("8 running · 6 finished");
  });

  it("gives an older client the terminal band the classic pill draws", () => {
    const surface = render([job("bash-1", { command: "npm test" })]);
    expect(surface.fallback.text).toContain("bash-1");
    expect(surface.fallback.text).toContain("npm test");
    const section = surface.sections[0];
    expect(section?.fallback.text).toBe(surface.fallback.text);
  });
});
