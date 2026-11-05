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
    const surface = render([job("bash-1"), job("bash-2", { status: "completed" })]);
    expect(find(body(surface), "stop:bash-1")).toMatchObject({
      type: "button",
      title: "Stop",
      action: { id: "stop", values: { job: "bash-1" } },
    });
    expect(find(body(surface), "stop:bash-2")).toBeUndefined();
    expect(find(body(surface), "status:bash-2")).toMatchObject({ text: "done" });
    expect(surface.actions.stop).toMatchObject({ title: "Stop", pending: { title: "Stopping…" } });
    expect(Object.keys(surface.actions)).toEqual(["stop"]);
  });

  it("titles the panel with the running count, then with the results left", () => {
    expect(render([job("bash-1"), job("bash-2")]).header.title).toBe("2 jobs");
    expect(
      render([job("bash-1", { status: "failed" }), job("bash-2", { status: "cancelled" })]).header
        .title,
    ).toBe("2 results");
  });

  it("folds each job's output tail away, plain and cut to the node cap", () => {
    const output = [
      "\u001b[32mgreen\u001b[0m start",
      "progress 10%\rprogress 100%",
      ...Array.from({ length: 40 }, (_, index) => `line ${index} ${"x".repeat(60)}`),
    ].join("\n");
    const surface = render([job("bash-1", { status: "completed", output })]);
    const group = find(body(surface), "output:bash-1");
    expect(group).toMatchObject({ type: "group", collapsed: true });
    const tail = find(body(surface), "tail:bash-1");
    expect(tail?.type).toBe("code");
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
      ...Array.from({ length: 6 }, (_, index) => job(`done-${index}`, { status: "completed" })),
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
    expect(surface.header.title).toBe("8 jobs");
  });

  it("gives an older client the terminal band the classic pill draws", () => {
    const surface = render([job("bash-1", { command: "npm test" })]);
    expect(surface.fallback.text).toContain("bash-1");
    expect(surface.fallback.text).toContain("npm test");
    const section = surface.sections[0];
    expect(section?.fallback.text).toBe(surface.fallback.text);
  });
});
