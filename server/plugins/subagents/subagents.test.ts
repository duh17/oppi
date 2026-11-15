import { describe, expect, test } from "bun:test";
import { normalizeExtensionUINativeSurface } from "../../src/extension-ui-contract.ts";
import {
  applyGet,
  applyWaitReading,
  isMissingSession,
  launcherFromGet,
  ANSWER_EXCERPT_MAX,
  EARLIER_EXCERPT_MAX,
  cutMarkdown,
  subagentPanel,
  type SubagentRow,
  type SubagentSection,
  refreshLaunched,
  renderSubagentTerminal,
  rowFallback,
  selectPillRows,
  subagentFromCreate,
  subagentRows,
  widgetChrome,
  withStatuses,
  type Subagent,
  type SubagentTerminalStyle,
} from "./subagents.ts";
import { readWait } from "./supervise.ts";

describe("subagents", () => {
  test("only a create result from this parent becomes a row", () => {
    const child = subagentFromCreate(
      "oppi session create --workspace oppi --name scout --json",
      '{"ok":true,"data":{"session_id":"child-1"}}',
      "parent-1",
    );
    expect(child?.link).toBe("oppi://session/child-1");
    expect(child?.parentId).toBe("parent-1");
    expect(
      subagentFromCreate("oppi session list --json", '{"ok":true,"data":{"sessions":[]}}'),
    ).toBeNull();
    expect(
      subagentFromCreate(
        "oppi session create --json",
        '{"ok":true,"data":{"note":"see"}} {"ok":true,"data":{"session_id":"not-the-create"}}',
      ),
    ).toBeNull();
  });

  test("refreshes only launched ids and drops a get that names another parent", () => {
    const launched = subagentFromCreate(
      "oppi session create --name scout --json",
      '{"ok":true,"data":{"session_id":"child-1"}}',
      "parent-1",
    );
    if (!launched) throw new Error("expected a launch");
    const rows = subagentRows(
      refreshLaunched(
        [launched],
        [
          {
            ok: true,
            data: {
              session: {
                id: "someone-else",
                name: "not ours",
                status: "busy",
                launch: { parentSessionId: "other-parent" },
              },
            },
          },
          {
            ok: true,
            data: {
              session: {
                id: "child-1",
                name: "scout",
                status: "stopped",
                workspaceId: "ws-1",
                launch: { parentSessionId: "parent-1" },
              },
            },
          },
        ],
      ),
    );
    expect(rows).toHaveLength(1);
    expect(rows[0]?.state).toBe("success");
    expect(rows[0]?.link).toBe("oppi://session/child-1?workspaceId=ws-1");
  });

  test("a saved-agent emoji prefixes the row title", () => {
    const launched = subagentFromCreate(
      "oppi session create --name scout --json",
      '{"ok":true,"data":{"session_id":"child-1"}}',
      "parent-1",
    );
    if (!launched) throw new Error("expected a launch");
    const next = applyGet(launched, {
      ok: true,
      data: {
        session: {
          id: "child-1",
          name: "scout",
          status: "busy",
          launch: { agentIcon: { kind: "emoji", value: "🔎" } },
        },
      },
    });
    expect(next?.title).toBe("🔎 scout");
    expect(
      applyGet(launched, {
        ok: true,
        data: {
          session: {
            id: "child-1",
            name: "plain",
            launch: { agentIcon: { kind: "symbol", name: "sparkles" } },
          },
        },
      })?.title,
    ).toBe("plain");
  });

  test("a ready wait status marks the row settled", () => {
    const [row] = withStatuses(
      [
        {
          id: "child-1",
          title: "scout",
          subtitle: "child-1",
          link: "oppi://session/child-1",
          state: "running",
        },
      ],
      [{ id: "child-1", status: "ready" }],
    );
    expect(row?.state).toBe("success");
  });

  test("wait attention is warning and settled ready is Done in the row copy", () => {
    const launched = {
      id: "child-1",
      title: "scout",
      subtitle: "child1",
      link: "oppi://session/child-1",
      state: "running" as const,
    };
    const warned = applyWaitReading([launched], {
      timedOut: false,
      settled: [],
      attention: [{ id: "child-1", status: "busy", pendingDialogs: 1 }],
      running: [],
    });
    expect(warned[0]?.state).toBe("warning");
    const stopping = applyWaitReading([launched], {
      timedOut: true,
      settled: [],
      attention: [],
      running: [{ id: "child-1", status: "stopping" }],
    });
    expect(stopping[0]?.state).toBe("success");
    const done = applyWaitReading([launched], {
      timedOut: false,
      settled: [{ id: "child-1", status: "ready" }],
      attention: [],
      running: [],
    });
    const [row] = subagentRows(done);
    expect(row?.state).toBe("success");
    // The section says Done; the row repeats no state word and no session id.
    expect(row?.subtitle).toBeUndefined();
    expect(row?.detail).toBeUndefined();
    expect(rowFallback(row!)).toBe("scout oppi://session/child-1");
  });

  test("a stopping get keeps a finished row Done", () => {
    const launched = subagentFromCreate(
      "oppi session create --name scout --json",
      '{"ok":true,"data":{"session_id":"child-1"}}',
      "parent-1",
    );
    if (!launched) throw new Error("expected a launch");
    const done = withStatuses([launched], [{ id: "child-1", status: "ready" }]);
    const next = applyGet(done[0]!, {
      ok: true,
      data: { session: { id: "child-1", status: "stopping" } },
    });
    expect(next?.state).toBe("success");
  });

  test("a ready get with a pending wake keeps the row Working, not Done", () => {
    const launched = subagentFromCreate(
      "oppi session create --name scout --json",
      '{"ok":true,"data":{"session_id":"child-1"}}',
      "parent-1",
    );
    if (!launched) throw new Error("expected a launch");
    const next = applyGet(launched, {
      ok: true,
      data: { session: { id: "child-1", status: "ready", pendingWake: true } },
    });
    expect(next?.state).toBe("running");
    // Once the background job ends, the next get (no pendingWake) settles the row.
    const settled = applyGet(next!, {
      ok: true,
      data: { session: { id: "child-1", status: "ready" } },
    });
    expect(settled?.state).toBe("success");
  });

  test("a wait on a child with a pending wake shows Working until the wake's turn settles", () => {
    const launched = {
      id: "child-1",
      title: "scout",
      subtitle: "child1",
      link: "oppi://session/child-1",
      state: "running" as const,
    };
    const stillWaking = applyWaitReading(
      [launched],
      readWait({
        ok: true,
        data: {
          timed_out: true,
          sessions: [{ session_id: "child-1", status: "ready", pending_wake: true }],
        },
      }),
    );
    expect(subagentRows(stillWaking)[0]?.state).toBe("running");
    const done = applyWaitReading(
      stillWaking,
      readWait({ ok: true, data: { session_id: "child-1", reason: "idle", status: "ready" } }),
    );
    expect(subagentRows(done)[0]?.state).toBe("success");
  });

  test("applyGet keeps a launched row when the payload has no parent field", () => {
    const launched = subagentFromCreate(
      "oppi session create --name scout --json",
      '{"ok":true,"data":{"session_id":"child-1"}}',
      "parent-1",
    );
    if (!launched) throw new Error("expected a launch");
    const next = applyGet(launched, {
      ok: true,
      data: { session: { id: "child-1", status: "busy", workspaceId: "ws-1" } },
    });
    expect(next?.state).toBe("running");
    expect(next?.link).toContain("workspaceId=ws-1");
  });

  /** `count` children, newest first; `states` overrides by index (0 is the newest). */
  const many = (count: number, states: Record<number, Subagent["state"]> = {}): Subagent[] =>
    Array.from({ length: count }, (_, index) => ({
      id: `child-${count - index}`,
      title: `child ${count - index}`,
      subtitle: `c${count - index}`,
      link: `oppi://session/child-${count - index}`,
      state: states[index] ?? "success",
    }));

  test("the subtitle counts live children, most urgent first, and nothing when none is live", () => {
    expect(
      widgetChrome(many(111, { 110: "warning", 109: "running", 5: "running", 3: "error" })),
    ).toEqual({
      title: "Subagents",
      subtitle: "1 failed \u00b7 1 needs you \u00b7 2 working",
    });
    // The finished ones are not counted: the pill goes away when nothing is live.
    expect(widgetChrome(many(111)).subtitle).toBeUndefined();
    // Eleven working children: eight rows, three more behind them.
    const busy = many(
      20,
      Object.fromEntries(Array.from({ length: 11 }, (_, i) => [i, "running" as const])),
    );
    expect(widgetChrome(busy).subtitle).toBe("11 working \u00b7 +3 more");
    expect(selectPillRows(busy).filter((row) => row.state === "running")).toHaveLength(8);
  });

  test("rows: what needs you, oldest first; then working, oldest run first; then the 3 newest finished", () => {
    const at = (item: Subagent, fields: Partial<Subagent>): Subagent => ({ ...item, ...fields });
    const [a, b, c, d, e, f, g] = many(7);
    const shown = selectPillRows([
      at(a!, { state: "running", since: 300 }),
      at(b!, { state: "error", since: 250 }),
      at(c!, { state: "running", since: 100 }),
      at(d!, { state: "warning", since: 200 }),
      at(e!, { finishedAt: 50 }),
      at(f!, { finishedAt: 90 }),
      at(g!, { finishedAt: 70 }),
    ]);
    expect(shown.map((row) => row.id)).toEqual([
      "child-4", // asking since 200
      "child-6", // failed since 250: a failure needs you as a question does
      "child-5", // working since 100
      "child-7", // working since 300
      "child-2", // finished at 90
      "child-1", // at 70
      "child-3", // at 50
    ]);
  });

  /** The rows of a section, or of the Earlier row's list in it. */
  const rowsIn = (section: SubagentSection): SubagentRow[] => {
    const rows = section.blocks[0].rows;
    const list = rows[0]?.id === "earlier" ? rows[0].blocks?.[0] : undefined;
    return list?.type === "activityList" ? list.rows : rows;
  };
  const markdownOf = (row: SubagentRow | undefined): string | undefined => {
    const block = row?.blocks?.[0];
    return block?.type === "markdown" ? block.markdown : undefined;
  };

  test("the panel lists every child: Needs You, Working, Recent, then Earlier behind one row", () => {
    const at = (item: Subagent, fields: Partial<Subagent>): Subagent => ({ ...item, ...fields });
    const children = many(12).map((item, index) => at(item, { finishedAt: 1_000 - index * 10 }));
    children[4] = at(children[4]!, { state: "warning", since: 5 });
    children[7] = at(children[7]!, { state: "running", since: 3 });
    // Finished later than its place in the list says: Earlier is newest first by finish.
    children[11] = at(children[11]!, { finishedAt: 955 });
    const panel = subagentPanel(children, "parent-1");
    expect(panel.sections.map((section) => section.title)).toEqual([
      "Needs You",
      "Working",
      "Recent",
      "Earlier",
    ]);
    expect(panel.sections.map((section) => rowsIn(section).map((row) => row.id))).toEqual([
      ["child-8"],
      ["child-5"],
      ["child-12", "child-11", "child-10"],
      ["child-9", "child-1", "child-7", "child-6", "child-4", "child-3", "child-2"],
    ]);
    // Earlier is one row, closed until opened, holding the other finished children.
    const earlier = panel.sections[3]!.blocks[0].rows;
    expect(earlier).toHaveLength(1);
    expect(earlier[0]).toMatchObject({ id: "earlier", title: "7 finished" });
    expect(earlier[0]!.link).toBeUndefined();
    // Every child has a row that opens its session and discloses its details; none is cut, so
    // there is no thread row.
    expect(panel.shown.size).toBe(12);
    for (const section of panel.sections)
      for (const row of rowsIn(section)) {
        expect(row.link).toBe(`oppi://session/${row.id}`);
        expect(markdownOf(row)).toBeDefined();
      }
    expect(JSON.stringify(panel.sections)).not.toContain("oppi://thread");
    // The text fallback stays the terminal band's rows, not the whole thread.
    expect(panel.fallback).toHaveLength(5);
    // Without finished children beyond Recent, there is no Earlier.
    expect(
      subagentPanel(many(2, { 0: "warning" }), "parent-1").sections.map((s) => s.title),
    ).toEqual(["Needs You", "Recent"]);
  });

  test("every live child gets a row, and the subtitle counts no more than the rows hide", () => {
    const busy = many(
      20,
      Object.fromEntries(Array.from({ length: 11 }, (_, i) => [i, "running" as const])),
    );
    const panel = subagentPanel(busy);
    expect(rowsIn(panel.sections[0]!)).toHaveLength(11);
    expect(panel.chrome.subtitle).toBe("11 working");
  });

  test("a row discloses its answer, its current step while it works, and its model and spend", () => {
    const long = `${"The answer goes on. ".repeat(200)}`;
    const at = (item: Subagent, fields: Partial<Subagent>): Subagent => ({ ...item, ...fields });
    const [working, recent, , , older] = many(5).map((item, index) =>
      at(item, { finishedAt: 100 - index, answer: long, model: "anthropic/claude-opus-5-5" }),
    );
    const panel = subagentPanel([
      at(working!, { state: "running", activity: "Running bash", answer: undefined, cost: 1.5 }),
      recent!,
      ...many(5)
        .slice(1, 3)
        .map((item, index) => at(item, { id: `mid-${index}`, finishedAt: 99 - index })),
      older!,
    ]);
    const [live, newest] = [rowsIn(panel.sections[0]!)[0], rowsIn(panel.sections[1]!)[0]];
    expect(markdownOf(live)).toBe(
      "**Now:** Running bash\n\n`anthropic/claude-opus-5-5` \u00b7 $1.50",
    );
    // Recent shows a long answer, Earlier a glance; both cut at a word, with an ellipsis.
    const recentText = markdownOf(newest)!.split("\n\n")[0]!;
    expect(recentText.length).toBeLessThanOrEqual(ANSWER_EXCERPT_MAX);
    expect(recentText.length).toBeGreaterThan(ANSWER_EXCERPT_MAX - 300);
    expect(recentText.endsWith("\u2026")).toBe(true);
    expect(long[recentText.length - 1]).toBe(" ");
    const earlierText = markdownOf(rowsIn(panel.sections[2]!)[0])!.split("\n\n")[0]!;
    expect(earlierText.length).toBeLessThanOrEqual(EARLIER_EXCERPT_MAX);
    expect(earlierText.endsWith("\u2026")).toBe(true);
  });

  test("a cut answer closes a code fence it leaves open", () => {
    const cut = cutMarkdown(`Look:\n\n\`\`\`ts\n${"const a = 1;\n".repeat(50)}\`\`\`\nDone.`, 100);
    expect(cut.endsWith("\u2026\n```")).toBe(true);
    expect(cut.match(/```/g)).toHaveLength(2);
    expect(cutMarkdown("Short.", 100)).toBe("Short.");
  });

  test("a thread too big for one surface shows the newest that fit and counts the rest", () => {
    // Wide answers, names, and branches in several scripts, so bytes outgrow characters.
    const answer = `## Result\n\n${'\u5b8c\u6210 done \u2705 "quoted" \\ '.repeat(120)}`;
    for (const live of [0, 6, 200]) {
      const children = many(200).map((item, index) => ({
        ...item,
        id: `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
        link: `oppi://session/00000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
        title: `\ud83e\udd16 subagent-with-a-long-name-${index}-\u4efb\u52a1`,
        state: index < live ? ("running" as const) : ("success" as const),
        activity: "Running a step with a long description \u2192 ".repeat(3),
        since: index,
        finishedAt: 10_000 - index,
        took: 60_000,
        model: "anthropic/claude-opus-5-5",
        thinking: "high",
        cost: 12.34,
        worktree: { branch: `feature/branch-${index}`, ahead: 3, dirty: true },
        answer,
      }));
      const panel = subagentPanel(children, "parent-1");
      const surface = {
        version: 1,
        id: "widget:subagents",
        source: "widget",
        presentation: { style: "surfacePanel", ...panel.chrome },
        blocks: panel.sections,
        fallback: { lines: panel.fallback },
      };
      // The server accepts it: it would drop a surface over any limit.
      expect(normalizeExtensionUINativeSurface(surface)).toBeDefined();
      const rows = panel.sections.flatMap(rowsIn);
      const more = rows.at(-1)!;
      expect(more).toEqual({
        id: "thread",
        title: `${200 - panel.shown.size} more in Thread`,
        link: "oppi://thread/parent-1",
      });
      // The newest that fit, in order: the shown children are a prefix of the panel's order.
      const shown = rows.slice(0, -1).map((row) => row.id);
      expect(shown).toHaveLength(panel.shown.size);
      expect(panel.shown.size).toBeGreaterThan(30);
      expect(shown).toEqual(children.slice(0, shown.length).map((c) => c.id));
    }
  });

  test("a thread of 45 shows every child, answers in full under Recent and a glance under Earlier", () => {
    const answer = `Done: the feature works.\n\n${"Some **detail** about the change and `code`. ".repeat(60)}`;
    const children = many(45).map((item, index) => ({
      ...item,
      id: `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
      link: `oppi://session/00000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
      title: `worker-feature-${index}`,
      state: index < 3 ? ("running" as const) : ("success" as const),
      activity: index < 3 ? "Running bash" : "Done: the feature works.",
      since: index,
      finishedAt: 10_000 - index,
      model: "anthropic/claude-opus-5-5",
      cost: 3.21,
      answer,
    }));
    const panel = subagentPanel(children, "parent-1");
    expect(panel.shown.size).toBe(45);
    const rows = panel.sections.flatMap(rowsIn);
    expect(rows.map((row) => row.id)).toEqual(children.map((c) => c.id));
    const excerpt = (row: SubagentRow): string =>
      markdownOf(row)!.split("\n\n").slice(0, -1).join("\n\n");
    for (const row of rows.slice(3, 6))
      expect(excerpt(row).length).toBeGreaterThan(ANSWER_EXCERPT_MAX - 100);
    for (const row of rows.slice(6)) {
      expect(excerpt(row).startsWith("Done: the feature works.")).toBe(true);
      expect(excerpt(row).length).toBeLessThanOrEqual(EARLIER_EXCERPT_MAX);
    }
  });

  test("a row's second line is what changes, the third its model, spend, worktree, and run time", () => {
    const base = many(1)[0]!;
    const [working, finished, stopped] = subagentRows([
      {
        ...base,
        state: "running",
        activity: "Running bash",
        since: 1_000,
        model: "anthropic/claude-opus-5-5",
        thinking: "high",
        cost: 2.371,
        worktree: { ahead: 5, dirty: true },
      },
      { ...base, activity: "Plan written.", took: 41 * 60_000, finishedAt: 9, since: 1, cost: 0 },
      { ...base, stopped: true, worktree: { branch: "fix/other", ahead: 0, dirty: false } },
    ]);
    expect(working).toMatchObject({
      subtitle: "Running bash",
      detail: "opus-5-5 high \u00b7 $2.37 \u00b7 5 ahead, dirty",
      state: "running",
      since: 1_000,
    });
    // A finished row's time is how long it took, and it does not tick.
    expect(finished?.detail).toBe("took 41m");
    expect(finished?.since).toBeUndefined();
    expect(stopped).toMatchObject({ subtitle: "Stopped", detail: "fix/other", state: "inactive" });
  });

  test("a hidden child that starts working takes a row", () => {
    const all = many(30);
    expect(selectPillRows(all).map((row) => row.id)).not.toContain("child-3");
    const woke = withStatuses(all, [{ id: "child-3", status: "busy" }]);
    expect(selectPillRows(woke)[0]?.id).toBe("child-3");
    expect(widgetChrome(woke).subtitle).toBe("1 working");
  });

  test("the terminal band counts the live children and draws the selected rows", () => {
    const lines = renderSubagentTerminal(many(30, { 29: "running" }));
    // The working child, then the three newest finished.
    expect(lines).toHaveLength(5);
    expect(lines[0]).toContain("Subagents \u00b7 1 working");
    expect(lines[1]).toContain("child 1");
  });

  test("a deleted session leaves the set, and the launcher's Oppi id is the thread", () => {
    const gone = {
      ok: false,
      error: { code: "session_not_found", message: "Session not found: child-2" },
    };
    expect(isMissingSession(gone)).toBe(true);
    expect(
      isMissingSession({
        ok: false,
        error: { status: 404, message: "Session not found: child-2" },
      }),
    ).toBe(true);
    expect(isMissingSession({ ok: false, error: { code: "unauthorized" } })).toBe(false);
    // Another thing that is gone says nothing about the session.
    expect(
      isMissingSession({ ok: false, error: { status: 404, message: "Workspace not found: ws-1" } }),
    ).toBe(false);
    expect(
      isMissingSession({ ok: false, error: { code: "workspace_not_found", message: "not found" } }),
    ).toBe(false);
    expect(isMissingSession({ ok: true, data: { session: { id: "child-2" } } })).toBe(false);
    const all = many(12);
    expect(refreshLaunched(all, [gone], ["child-2"]).map((row) => row.id)).not.toContain("child-2");
    expect(refreshLaunched(all, [gone], ["child-2"])).toHaveLength(11);
    const get = {
      ok: true,
      data: { session: { id: "child-1", launch: { parentSessionId: "oppi-parent" } } },
    };
    expect(launcherFromGet(get)).toBe("oppi-parent");
    expect(launcherFromGet(gone)).toBeUndefined();
  });

  test("a get payload puts the model on the row, and no context use", () => {
    const launched = subagentFromCreate(
      "oppi session create --name scout --model anthropic/claude-opus-4-6 --json",
      '{"ok":true,"data":{"session_id":"child-1"}}',
      "parent-1",
    );
    if (!launched) throw new Error("expected a launch");
    expect(launched.model).toBe("anthropic/claude-opus-4-6");
    const next = applyGet(launched, {
      ok: true,
      data: {
        session: {
          id: "child-1",
          name: "scout",
          status: "busy",
          model: "anthropic/claude-opus-4-6",
          contextTokens: 136_000,
          contextWindow: 200_000,
          launch: { parentSessionId: "parent-1" },
        },
      },
    });
    const [row] = subagentRows([next!]);
    expect(row?.detail).toBe("opus-4-6");
    expect(rowFallback(row!)).not.toContain("%");
  });

  test("wait status updates keep the model on the row", () => {
    const launched = {
      id: "child-1",
      title: "scout",
      subtitle: "child1",
      link: "oppi://session/child-1",
      state: "running" as const,
      model: "cursor/composer-1.5",
    };
    const done = applyWaitReading([launched], {
      timedOut: false,
      settled: [{ id: "child-1", status: "ready" }],
      attention: [],
      running: [],
    });
    const [row] = subagentRows(done);
    expect(row?.state).toBe("success");
    expect(row?.detail).toBe("composer-1.5");
  });

  test("a busy get does not clear wait attention on the row", () => {
    const launched = {
      id: "child-1",
      title: "scout",
      subtitle: "child1",
      link: "oppi://session/child-1",
      state: "running" as const,
    };
    const [warned] = applyWaitReading([launched], {
      timedOut: false,
      settled: [],
      attention: [{ id: "child-1", status: "busy", pendingDialogs: 1 }],
      running: [],
    });
    expect(warned?.state).toBe("warning");
    const next = applyGet(warned!, {
      ok: true,
      data: {
        session: {
          id: "child-1",
          status: "busy",
          model: "anthropic/claude-opus-4-6",
        },
      },
    });
    expect(next?.state).toBe("warning");
    expect(subagentRows([next!])[0]).toMatchObject({ state: "warning", detail: "opus-4-6" });
  });

  test("a ready get can settle a row that needed attention", () => {
    const warned = {
      id: "child-1",
      title: "scout",
      subtitle: "child1",
      link: "oppi://session/child-1",
      state: "warning" as const,
    };
    const next = applyGet(warned, {
      ok: true,
      data: { session: { id: "child-1", status: "ready" } },
    });
    expect(next?.state).toBe("success");
  });

  test("a get without a model keeps the launched one", () => {
    const launched = subagentFromCreate(
      "oppi session create --name scout --model ds4/deepseek-v4-flash --json",
      '{"ok":true,"data":{"session_id":"child-1"}}',
      "parent-1",
    );
    if (!launched) throw new Error("expected a launch");
    const next = applyGet(launched, {
      ok: true,
      data: { session: { id: "child-1", status: "busy" } },
    });
    const [row] = subagentRows([next!]);
    expect(row?.detail).toBe("deepseek-v4-flash");
  });
});

describe("terminal band", () => {
  const marked: SubagentTerminalStyle = {
    accent: (text) => `<accent>${text}</accent>`,
    success: (text) => `<success>${text}</success>`,
    warning: (text) => `<warning>${text}</warning>`,
    error: (text) => `<error>${text}</error>`,
    dim: (text) => `<dim>${text}</dim>`,
    title: (text) => `<title>${text}</title>`,
    rule: (text) => `<rule>${text}</rule>`,
    bold: (text) => `<bold>${text}</bold>`,
  };

  function child(partial: Partial<Subagent> & Pick<Subagent, "id" | "title" | "state">): Subagent {
    return {
      subtitle: partial.id.slice(0, 8),
      link: `oppi://session/${partial.id}`,
      ...partial,
    };
  }

  const crew: Subagent[] = [
    child({
      id: "1fa2aa56-aaaa",
      title: "worker-server-deps-lts",
      state: "success",
      model: "xai/grok-4.7",
    }),
    child({
      id: "bbbbbbbb-bbbb",
      title: "worker-swift-dead-code",
      state: "running",
      model: "xai/grok-4.7",
    }),
    child({
      id: "cccccccc-cccc",
      title: "scout-unlanded-branches",
      state: "success",
      model: "xai/grok-4.7",
    }),
  ];

  test("a phone-width band keeps status and model and drops the session URL", () => {
    const lines = renderSubagentTerminal(crew, { width: 52 });
    expect(lines[0]).toBe("\u2502 \u25cf Subagents \u00b7 1 working");
    expect(lines.join("\n")).not.toContain("oppi://");
    expect(lines.join("\n")).not.toContain("1fa2aa56");
    const working = lines.find((line) => line.includes("worker-swift-dead-code"));
    expect(working).toContain("Working");
    expect(working).toContain("grok-4.7");
    expect(lines.every((line) => [...line].length <= 52)).toBe(true);
    const workingAt = lines[2]?.indexOf("Working");
    const doneAt = lines[1]?.indexOf("Done");
    expect(workingAt).toBe(doneAt);
  });

  test("a narrow band keeps the status and truncates the name before the URL can appear", () => {
    const lines = renderSubagentTerminal(crew, { width: 28 });
    expect(lines.join("\n")).not.toContain("oppi://");
    expect(lines.join("\n")).not.toContain("grok-4.7");
    const working = lines.find((line) => line.includes("Working"));
    expect(working).toBeDefined();
    expect(working).not.toContain("worker-swift-dead-code");
    expect(lines.every((line) => [...line].length <= 28)).toBe(true);
  });

  test("attention uses the warning mark and does not change the phone row", () => {
    const warned = child({
      id: "child-1",
      title: "scout",
      state: "warning",
      model: "anthropic/claude-opus-4-6",
    });
    const lines = renderSubagentTerminal([warned], { width: 40, style: marked });
    expect(lines[0]).toContain("<warning>!</warning>");
    expect(lines[0]).toContain("1 needs you");
    expect(lines[1]).toContain("<warning>Needs attention</warning>");
    expect(lines.join("\n")).not.toContain("oppi://");
    const [row] = subagentRows([warned]);
    expect(rowFallback(row!)).toContain("oppi://session/child-1");
    expect(row).toMatchObject({ state: "warning", detail: "opus-4-6" });
  });

  test("an empty set draws nothing", () => {
    expect(renderSubagentTerminal([])).toEqual([]);
  });

  test("a wide-character name is truncated before the row can wrap", () => {
    const lines = renderSubagentTerminal(
      [
        child({
          id: "child-1",
          title: "\u68c0\u67e5\u5de5\u4f5c\u6811\u5ba1\u8ba1",
          state: "running",
          model: "xai/grok-4.7",
        }),
      ],
      { width: 20 },
    );
    expect(lines[1]).toContain("Working");
    expect(lines[1]).not.toContain("\u5ba1\u8ba1");
    expect(lines[1]).not.toContain("oppi://");
  });
});
