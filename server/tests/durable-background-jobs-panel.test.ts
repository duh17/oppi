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
    expect(find(list, "meta:bash-262")).toMatchObject({ text: "bash-262 · Running" });
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

  it("gives a running job's row and the pill a client-ticked elapsed node from its start", () => {
    const started1 = AT - (65 * 60_000 + 30_000);
    const started2 = AT - 12 * 60_000;
    const surface = render([
      job("bash-1", { startedAt: started1 }),
      job("bash-2", { startedAt: started2 }),
      job("bash-3", { status: "completed", exitCode: 0, startedAt: AT - 60_000 }),
    ]);
    const list = body(surface);
    expect(find(list, "elapsed:bash-1")).toMatchObject({ type: "elapsed", since: started1 });
    expect(find(list, "elapsed:bash-2")).toMatchObject({ type: "elapsed", since: started2 });
    // A finished job keeps its static outcome text.
    expect(find(list, "elapsed:bash-3")).toBeUndefined();
    expect(find(list, "meta:bash-3")).toMatchObject({ text: "bash-3 · Exit 0" });
    // The pill counts the oldest running job.
    const pillNodes = JSON.stringify(surface.pill);
    expect(pillNodes).toContain(`"type":"elapsed"`);
    expect(pillNodes).toContain(`"since":${started1}`);
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

  it("shows a spinner and the newest running job's last line in the pill, trimmed", () => {
    const surface = render([
      job("old", { startedAt: AT - 60_000, output: "old output\n" }),
      job("new", { output: `\u001b[32m${"x".repeat(80)}\u001b[0m\n\n` }),
    ]);
    const pillNodes = JSON.stringify(surface.pill);
    expect(pillNodes).toContain('"type":"progress"');
    expect(pillNodes).not.toContain('"value"');
    const line = words(surface.pill!.content).find((word) => word.startsWith("x"))!;
    expect(Array.from(line)).toHaveLength(40);
    expect(pillNodes).not.toContain("old output");
    // Nothing printed yet: the pill is still the count and the age.
    const quiet = render([job("quiet")]).pill!.content;
    expect(words(quiet)).toEqual(["1 job running"]);
    expect(find(quiet, "pill:elapsed")).toMatchObject({ type: "elapsed", format: "short" });
  });

  it("says in the pill how many jobs failed, so it shows without opening the panel", () => {
    const pillWords = (jobs: PanelJob[]) => words(render(jobs).pill!.content);
    expect(
      pillWords([
        job("a", { status: "failed", exitCode: 1 }),
        job("b", { status: "failed", exitCode: null }),
        job("c", { status: "completed", exitCode: 0 }),
      ]),
    ).toContain("2 failed");
    expect(pillWords([job("a", { status: "completed", exitCode: 0 })]).join()).not.toContain(
      "failed",
    );
  });

  it("shows a running job's live lines, folder, time left, and truncation outside the fold", () => {
    const output = Array.from({ length: 30 }, (_, index) => `step ${index}`).join("\n");
    const list = body(
      render([
        job("a", {
          output,
          cwd: "/work/app/",
          timeoutAt: AT + 5 * 60_000,
          truncated: true,
        }),
      ]),
    );
    const folded = find(list, "output:a")!;
    const tail = find(list, "tail:a") as { text: string };
    expect(find(folded, "tail:a")).toBeUndefined();
    expect(tail.text.split("\n")).toHaveLength(12);
    expect(tail.text).toContain("step 29");
    expect(find(list, "detail:a")).toMatchObject({ text: "app · times out in 5m" });
    expect(find(list, "truncated:a")).toBeDefined();
    expect(find(folded, "cwd:a")).toMatchObject({ text: "/work/app/" });
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
