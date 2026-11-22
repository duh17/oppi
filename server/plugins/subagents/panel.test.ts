import { describe, expect, test } from "bun:test";
import { BACKGROUND_CONTEXT, type Context } from "@earendil-works/chord/context";
import type { ConversationId } from "@earendil-works/pi-durable";
import type { ExtensionUISurface, SurfaceConversation } from "oppi/v1";
import { SubagentDismissals, SubagentPill } from "./contract.ts";
import { ANSWER_EXCERPT_MAX } from "./subagents.ts";
import {
  CLEAR_FAILED,
  DISMISS,
  loadPanel,
  panel,
  subagentView,
  type SubagentPanelState,
} from "./panel.ts";
import type { Subagent } from "./subagents.ts";

/**
 * The panel's documents in memory: the watcher's rows, the dismissals, and nothing else. A test
 * that reads them through a new `store()` is a fresh process with the same saved state.
 */
function store(seed: { rows?: Subagent[]; dismissed?: Record<string, number> } = {}): {
  docs: Map<object, unknown>;
  doc: <T>(token: object) => T;
  conversation: SurfaceConversation;
} {
  // Keyed by the document token itself: that is what a read names, and `defineDoc` keeps its own
  // description to itself.
  const docs = new Map<object, unknown>([
    [SubagentPill, { rows: seed.rows ?? [], threadSessionId: "parent-session" }],
    [SubagentDismissals, { dismissed: seed.dismissed ?? {} }],
  ]);
  const doc = <T>(token: object): T => docs.get(token) as T;
  const conversation: SurfaceConversation = {
    conversationId: 1 as ConversationId,
    snapshot: (async (token: object) => structuredClone(doc(token))) as never,
    snapshotAsOf: (async (token: object) => structuredClone(doc(token))) as never,
    commit: (async (change: (tx: { doc: typeof doc }) => unknown) => change({ doc })) as never,
  };
  return { docs, doc, conversation };
}

function failed(id: string, at: number, overrides: Partial<Subagent> = {}): Subagent {
  return {
    id,
    title: id,
    subtitle: id.slice(0, 8),
    link: `oppi://session/${id}`,
    state: "error",
    activity: "Antigravity quota exceeded",
    answer: "Antigravity quota exceeded or access denied: the request was refused.",
    finishedAt: at,
    since: at,
    ...overrides,
  };
}

function working(id: string): Subagent {
  return {
    id,
    title: id,
    subtitle: id.slice(0, 8),
    link: `oppi://session/${id}`,
    state: "running",
    activity: "Running bash",
    since: 1_000,
  };
}

/** One tap, through the panel's own action path, answering with what it published. */
async function tap(
  actionId: string,
  values: Record<string, string>,
  state: SubagentPanelState,
  conversation: SurfaceConversation,
): Promise<ExtensionUISurface | undefined> {
  const published: ExtensionUISurface[] = [];
  const handler = panel.handlers().get(actionId);
  if (!handler) throw new Error(`no ${actionId} handler`);
  await handler(state, {
    state,
    compositeId: "subagents",
    actionId,
    values,
    signal: new AbortController().signal,
    context: BACKGROUND_CONTEXT as Context,
    ctx: {
      surfaces: {
        publish: (surface: ExtensionUISurface) => published.push(surface),
        dismiss: () => undefined,
        conversation,
      },
    },
    conversation,
  });
  return published.at(-1);
}

/** Every node of a surface's trees and pill, depth first. */
function nodes(surface: ExtensionUISurface): Array<Record<string, unknown>> {
  const found: Array<Record<string, unknown>> = [];
  const walk = (node: unknown): void => {
    if (!node || typeof node !== "object") return;
    const record = node as Record<string, unknown>;
    found.push(record);
    for (const child of (record.children as unknown[] | undefined) ?? []) walk(child);
    for (const child of (record.items as unknown[] | undefined) ?? []) walk(child);
  };
  for (const section of surface.sections) {
    if ("body" in section) walk(section.body);
  }
  if (surface.pill) walk(surface.pill.content);
  return found;
}

function ids(surface: ExtensionUISurface): string[] {
  return nodes(surface)
    .map((node) => node.id)
    .filter((id): id is string => typeof id === "string");
}

/** What the strip's pill says, one line at most. */
function pillWords(surface: ExtensionUISurface): string[] {
  const content = surface.pill?.content;
  return (content?.children ?? [])
    .map((node) => ("text" in node ? node.text : undefined))
    .filter((text): text is string => typeof text === "string");
}

function words(surface: ExtensionUISurface): string[] {
  return nodes(surface)
    .map((node) => node.text)
    .filter((text): text is string => typeof text === "string");
}

describe("subagents panel", () => {
  test("the pill counts the failures and the drawer lists each section", () => {
    const rows = [failed("child-a", 5_000), working("child-b")];
    const { view } = subagentView({ rows, threadSessionId: "parent-session" });
    const surface = panel.render({ rows, threadSessionId: "parent-session" });
    expect(view.header.title).toBe("Subagents");
    // The pill is one line: the one thing wrong. The drawer's subtitle carries the whole count.
    expect(pillWords(surface)).toEqual(["Subagents", "1 failed"]);
    expect(surface.header.subtitle).toBe("1 failed \u00b7 1 working");
    // The pill leads with the failure's own mark, so the strip says why it is there.
    const pill = nodes(surface).filter((node) => node.id === "pill:mark");
    expect(pill).toHaveLength(1);
    expect(pill[0]?.name).toBe("xmark.circle.fill");
    expect(words(surface)).toContain("Needs You");
    expect(words(surface)).toContain("Working");
    // A failed row opens its child and offers Dismiss; a working row opens it and offers nothing.
    expect(ids(surface)).toContain("dismiss:child-a");
    expect(ids(surface)).not.toContain("dismiss:child-b");
    const head = nodes(surface).find((node) => node.id === "head:child-a");
    expect(head?.link).toBe("oppi://session/child-a");
    // Its failure is what the row says, and its answer is one fold away.
    expect(words(surface)).toContain("Antigravity quota exceeded");
    expect(ids(surface)).toContain("answer:child-a");
    expect(nodes(surface).find((node) => node.id === "head:child-a")?.type).toBe("row");
    // An elapsed count ticks the row's state without a new snapshot.
    const elapsed = nodes(surface).find((node) => node.id === "time:child-b");
    expect(elapsed?.type).toBe("elapsed");
  });

  test("a dismissal hides the failure without touching the child, and persists", async () => {
    const rows = [failed("child-a", 5_000), working("child-b")];
    const first = store({ rows });
    const state = await loadPanel(first.conversation, BACKGROUND_CONTEXT as Context);
    if (!state) throw new Error("expected a panel");

    const published = await tap(DISMISS, { child: "child-a" }, state, first.conversation);
    if (!published) throw new Error("the tap published nothing");

    // Gone from Needs You, and it does not count as failed any more. It keeps its error line.
    expect(ids(published)).not.toContain("dismiss:child-a");
    expect(words(published)).not.toContain("1 failed \u00b7 1 working");
    expect(words(published)).toContain("Antigravity quota exceeded");
    // A finished row has no count to tick.
    expect(ids(published)).not.toContain("time:child-a");
    // The child itself is untouched: its row still opens it.
    expect(nodes(published).find((node) => node.id === "head:child-a")?.link).toBe(
      "oppi://session/child-a",
    );
    expect(
      (first.doc(SubagentDismissals) as { dismissed: Record<string, number> }).dismissed["child-a"],
    ).toBeGreaterThan(0);

    // A restart reads the same documents: the failure stays dismissed.
    const restarted = store({
      rows,
      dismissed: (first.doc(SubagentDismissals) as { dismissed: Record<string, number> }).dismissed,
    });
    const after = await loadPanel(restarted.conversation, BACKGROUND_CONTEXT as Context);
    if (!after) throw new Error("the panel ended");
    expect(after.rows.find((row) => row.id === "child-a")?.state).toBe("success");
    expect(after.rows.find((row) => row.id === "child-a")?.dismissed).toBe(true);
  });

  test("a later failure of the same child needs you again", async () => {
    const dismissedAt = 5_000;
    const again = store({
      rows: [failed("child-a", dismissedAt + 1)],
      dismissed: { "child-a": dismissedAt },
    });
    const state = await loadPanel(again.conversation, BACKGROUND_CONTEXT as Context);
    if (!state) throw new Error("the panel ended");
    expect(state.rows[0]?.state).toBe("error");
    const surface = panel.render(state);
    expect(ids(surface)).toContain("dismiss:child-a");
    expect(words(surface)).toContain("1 failed");
  });

  test("Clear failed dismisses every failure at once, and nothing else", async () => {
    const rows = [failed("child-a", 5_000), failed("child-b", 6_000), working("child-c")];
    const only = store({ rows });
    const state = await loadPanel(only.conversation, BACKGROUND_CONTEXT as Context);
    if (!state) throw new Error("expected a panel");
    expect(pillWords(panel.render(state))).toEqual(["Subagents", "2 failed"]);
    expect(panel.render(state).header.subtitle).toBe("2 failed \u00b7 1 working");

    const published = await tap(CLEAR_FAILED, {}, state, only.conversation);
    if (!published) throw new Error("the tap published nothing");
    expect(words(published)).toContain("1 working");
    expect(words(published)).not.toContain("2 failed \u00b7 1 working");
    const dismissed = (
      only.doc(SubagentDismissals) as {
        dismissed: Record<string, number>;
      }
    ).dismissed;
    expect(Object.keys(dismissed).sort()).toEqual(["child-a", "child-b"]);
    expect(dismissed["child-c"]).toBeUndefined();
  });

  test("Clear failed is offered only while more than one child fails", async () => {
    const one = panel.render({ rows: [failed("child-a", 5_000)] });
    expect(ids(one)).not.toContain("clear-failed:button");
    const two = panel.render({ rows: [failed("child-a", 5_000), failed("child-b", 6_000)] });
    expect(ids(two)).toContain("clear-failed:button");
    // Beside the heading, on the section's first line.
    expect(ids(two)).toContain("section:needs-you:heading");
  });

  test("the panel ends when no child is live", async () => {
    const done = store({ rows: [{ ...failed("child-a", 5_000), state: "success" }] });
    expect(await loadPanel(done.conversation, BACKGROUND_CONTEXT as Context)).toBeUndefined();
    const dismissed = store({ rows: [failed("child-a", 5_000)], dismissed: { "child-a": 9_000 } });
    expect(await loadPanel(dismissed.conversation, BACKGROUND_CONTEXT as Context)).toBeUndefined();
  });

  test("a long answer spans markdown nodes of a node's words, and the surface still validates", () => {
    const answer = Array.from(
      { length: 60 },
      (_, index) => `line ${index} of the failure report`,
    ).join("\n");
    const surface = panel.render({ rows: [failed("child-a", 5_000, { answer })] });
    const chunks = nodes(surface)
      .filter((node) => node.type === "markdown")
      .map((node) => String(node.markdown ?? ""));
    expect(chunks.length).toBeGreaterThan(1);
    for (const chunk of chunks) expect(Array.from(chunk).length).toBeLessThanOrEqual(500);
    // The whole excerpt reaches the phone, and it is the row's long cut of the answer.
    const shown = chunks.join("").length;
    expect(shown).toBeGreaterThan(1_400);
    expect(shown).toBeLessThanOrEqual(ANSWER_EXCERPT_MAX);
  });

  test("a thread too big for the limits keeps the newest children and counts the rest", () => {
    const rows = [
      failed("child-a", 9_000, { answer: "x".repeat(1_500) }),
      ...Array.from({ length: 60 }, (_, index) => ({
        ...failed(`old-${index}`, 1_000 + index, { state: "success" as const }),
      })),
    ];
    const view = subagentView({ rows, threadSessionId: "parent-session" });
    const surface = panel.render({ rows, threadSessionId: "parent-session" });
    expect(view.shown.size).toBeGreaterThan(1);
    expect(view.shown.size).toBeLessThan(rows.length);
    expect(ids(surface)).toContain("more");
    const more = nodes(surface).find((node) => node.id === "more:text");
    expect(String(more?.text)).toMatch(/^\d+ more in Thread$/);
    // A child that fits opens its session; the whole surface is what the server would accept.
    expect(nodes(surface).some((node) => node.link === "oppi://session/child-a")).toBe(true);
  });

  test("Earlier folds the finished children behind one row", () => {
    const rows = [
      failed("child-a", 5_000),
      ...Array.from({ length: 5 }, (_, index) => ({
        ...failed(`old-${index}`, 1_000 + index, { state: "success" as const }),
      })),
    ];
    const surface = panel.render({ rows });
    const earlier = nodes(surface).find((node) => node.id === "earlier:group");
    expect(earlier?.type).toBe("group");
    expect(earlier?.collapsed).toBe(true);
    expect(earlier?.title).toBe("2 finished");
    // The three newest finished children stay in Recent, the older two fold away.
    expect(ids(surface)).toContain("head:old-4");
    function inside(node: Record<string, unknown> | undefined, id: string): boolean {
      return !!node && JSON.stringify(node).includes(`"${id}"`);
    }
    expect(inside(earlier, "head:old-0")).toBe(true);
    const recent = nodes(surface).find((node) => node.id === "section:recent");
    expect(recent).toBeDefined();
    expect(inside(earlier, "head:old-3")).toBe(false);
  });

  test("251 finished children are one Earlier fold that counts what it holds", () => {
    const rows: Subagent[] = [
      failed("child-a", 9_000),
      ...Array.from({ length: 251 }, (_, index) => ({
        ...failed(`old-${index}`, 1_000 + index, { state: "success" as const }),
      })),
    ];
    const view = subagentView({ rows, threadSessionId: "parent-session" });
    const surface = panel.render({ rows, threadSessionId: "parent-session" });
    // One fold, however many finished children there are: no second fold, no repeated title.
    const folds = nodes(surface).filter(
      (node) => node.type === "group" && String(node.id).startsWith("earlier:group"),
    );
    expect(folds).toHaveLength(1);
    const fold = folds[0] as { title?: unknown; children?: unknown[] };
    const held = fold.children ?? [];
    // Its title counts the children it holds, not the whole Earlier section.
    expect(fold.title).toBe(`${held.length} finished`);
    expect(held.length).toBe(12);
    // Nothing repeats: one fold, one title that counts it.
    const counted = nodes(surface)
      .map((node) => node.title)
      .filter((title) => /^\d+ finished$/.test(String(title)));
    expect(counted).toEqual([fold.title]);
    // The rest is counted once, by the row that opens the thread.
    const more = nodes(surface).find((node) => node.id === "more:text");
    expect(Number(String(more?.text ?? "").replace(/\D+/g, ""))).toBe(
      rows.length - view.shown.size,
    );
    // Every child drawn is drawn once, and the fold's children are among them.
    expect(view.shown.size).toBe(1 + 3 + 12);
    expect(ids(surface).filter((id) => id.startsWith("child:")).length).toBe(view.shown.size);
  });
});
