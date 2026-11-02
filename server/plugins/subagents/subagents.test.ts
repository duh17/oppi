import { describe, expect, test } from "bun:test";
import {
	applyGet,
	applyWaitReading,
	isMissingSession,
	launcherFromGet,
	pillRows,
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

describe("subagents", () => {
	test("only a create result from this parent becomes a row", () => {
		const child = subagentFromCreate(
			"oppi session create --workspace oppi --name scout --json",
			'{"ok":true,"data":{"session_id":"child-1"}}',
			"parent-1",
		);
		expect(child?.link).toBe("oppi://session/child-1");
		expect(child?.parentId).toBe("parent-1");
		expect(subagentFromCreate("oppi session list --json", '{"ok":true,"data":{"sessions":[]}}')).toBeNull();
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
			[{ id: "child-1", title: "scout", subtitle: "child-1", link: "oppi://session/child-1", state: "running" }],
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
		expect(row?.subtitle).toBe("Done");
		expect(row?.detail).toBe("child1");
		expect(rowFallback(row!)).toContain("Done");
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

	test("widget chrome does not repeat the count as the subtitle", () => {
		const rows = [
			{
				id: "child-1",
				title: "scout",
				subtitle: "child1",
				link: "oppi://session/child-1",
				state: "running" as const,
			},
			{
				id: "child-2",
				title: "review",
				subtitle: "child2",
				link: "oppi://session/child-2",
				state: "success" as const,
			},
		];
		const chrome = widgetChrome(rows);
		expect(chrome.title).toBe("2 subagents");
		expect(chrome.subtitle).toBe("1 working");
		expect(chrome.subtitle).not.toBe(chrome.title);
		expect(widgetChrome(rows.slice(0, 1)).subtitle).toBe("Working");
		expect(widgetChrome([{ ...rows[1]! }]).subtitle).toBe("Done");
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

	test("the pill keeps old asking and working children, then the newest finished ones, errors among them", () => {
		// 110 children; the oldest is asking, the second oldest still working, a recent one errored.
		const all = many(110, { 109: "warning", 108: "running", 50: "running", 1: "error" });
		const shown = selectPillRows(all);
		expect(shown.map((row) => row.id)).toEqual([
			"child-1", // asking first, however old
			"child-60", // then working, newest first
			"child-2",
			"child-110", // then finished by age: an error is finished, not above working
			"child-109", // (the error)
			"child-108",
			"child-107",
			"child-106",
		]);
		// An old error does not keep a row over newer done children.
		expect(selectPillRows(many(30, { 29: "error" })).map((row) => row.id)).not.toContain("child-1");
	});

	test("title counts every child and the subtitle its states, with the live ones past the rows", () => {
		const all = many(111, { 110: "warning", 109: "running", 5: "running" });
		expect(widgetChrome(all)).toEqual({ title: "111 subagents", subtitle: "2 working \u00b7 1 needs you" });
		expect(widgetChrome(many(111)).subtitle).toBe("All done");
		// Eleven live children: eight rows, three more working behind them.
		const busy = many(20, Object.fromEntries(Array.from({ length: 11 }, (_, i) => [i, "running" as const])));
		expect(widgetChrome(busy).subtitle).toBe("11 working \u00b7 +3 more working");
		expect(selectPillRows(busy)).toHaveLength(8);
		expect(selectPillRows(busy).every((row) => row.state === "running")).toBe(true);
	});

	test("the overflow counts only live children, asking ones before working ones", () => {
		// Errors are finished: twelve of them past the rows add no overflow.
		const errored = many(30, Object.fromEntries(Array.from({ length: 12 }, (_, i) => [i, "error" as const])));
		expect(widgetChrome(errored).subtitle).toBe("12 errors");
		// Ten asking children fill the eight rows; two of them and every working child are behind.
		const crowded = many(
			30,
			Object.fromEntries([
				...Array.from({ length: 10 }, (_, i) => [i, "warning" as const]),
				...Array.from({ length: 5 }, (_, i) => [10 + i, "running" as const]),
			]),
		);
		expect(selectPillRows(crowded).every((row) => row.state === "warning")).toBe(true);
		expect(widgetChrome(crowded).subtitle).toBe(
			"5 working \u00b7 10 need you \u00b7 +2 more need you \u00b7 +5 more working",
		);
		// Some working children fit beside the asking ones, the rest are behind.
		const mixed = many(30, {
			0: "warning",
			1: "warning",
			...Object.fromEntries(Array.from({ length: 9 }, (_, i) => [2 + i, "running" as const])),
		});
		expect(widgetChrome(mixed).subtitle).toBe("9 working \u00b7 2 need you \u00b7 +3 more working");
	});

	test("a last row opens the whole thread, only when children are hidden", () => {
		const rows = pillRows(many(111), "parent-1");
		expect(rows).toHaveLength(9);
		expect(rows.at(-1)).toMatchObject({
			id: "thread",
			title: "All 111 in thread",
			link: "oppi://thread/parent-1",
		});
		expect(rows.slice(0, 8).every((row) => row.link.startsWith("oppi://session/"))).toBe(true);
		expect(pillRows(many(8), "parent-1")).toHaveLength(8);
		expect(pillRows(many(111))).toHaveLength(8);
	});

	test("a hidden child that starts working takes a row", () => {
		const all = many(30);
		expect(selectPillRows(all).map((row) => row.id)).not.toContain("child-3");
		const woke = withStatuses(all, [{ id: "child-3", status: "busy" }]);
		expect(selectPillRows(woke)[0]?.id).toBe("child-3");
		expect(widgetChrome(woke).subtitle).toBe("1 working");
	});

	test("the terminal band counts every child but draws the selected rows", () => {
		const lines = renderSubagentTerminal(many(30, { 29: "running" }));
		expect(lines).toHaveLength(9);
		expect(lines[0]).toContain("30 subagents");
		expect(lines[1]).toContain("child 1");
	});

	test("a deleted session leaves the set, and the launcher's Oppi id is the thread", () => {
		const gone = { ok: false, error: { code: "session_not_found", message: "Session not found: child-2" } };
		expect(isMissingSession(gone)).toBe(true);
		expect(
			isMissingSession({ ok: false, error: { status: 404, message: "Session not found: child-2" } }),
		).toBe(true);
		expect(isMissingSession({ ok: false, error: { code: "unauthorized" } })).toBe(false);
		// Another thing that is gone says nothing about the session.
		expect(
			isMissingSession({ ok: false, error: { status: 404, message: "Workspace not found: ws-1" } }),
		).toBe(false);
		expect(isMissingSession({ ok: false, error: { code: "workspace_not_found", message: "not found" } })).toBe(false);
		expect(isMissingSession({ ok: true, data: { session: { id: "child-2" } } })).toBe(false);
		const all = many(12);
		expect(refreshLaunched(all, [gone], ["child-2"]).map((row) => row.id)).not.toContain("child-2");
		expect(refreshLaunched(all, [gone], ["child-2"])).toHaveLength(11);
		const get = { ok: true, data: { session: { id: "child-1", launch: { parentSessionId: "oppi-parent" } } } };
		expect(launcherFromGet(get)).toBe("oppi-parent");
		expect(launcherFromGet(gone)).toBeUndefined();
	});

	test("a get payload puts model and context on the expanded row", () => {
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
		expect(row?.subtitle).toBe("Working · opus-4-6");
		expect(row?.detail).toBe("68%");
		expect(row?.progress).toBeCloseTo(0.68);
		expect(rowFallback(row!)).toContain("opus-4-6");
		expect(rowFallback(row!)).toContain("68%");
	});

	test("wait status updates keep model and context on the row", () => {
		const launched = {
			id: "child-1",
			title: "scout",
			subtitle: "child1",
			link: "oppi://session/child-1",
			state: "running" as const,
			model: "cursor/composer-1.5",
			contextTokens: 12_000,
			contextWindow: 200_000,
		};
		const done = applyWaitReading([launched], {
			timedOut: false,
			settled: [{ id: "child-1", status: "ready" }],
			attention: [],
			running: [],
		});
		const [row] = subagentRows(done);
		expect(row?.subtitle).toBe("Done · composer-1.5");
		expect(row?.detail).toBe("6%");
		expect(row?.progress).toBeCloseTo(0.06);
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
					contextTokens: 50_000,
					contextWindow: 200_000,
				},
			},
		});
		expect(next?.state).toBe("warning");
		expect(next?.contextTokens).toBe(50_000);
		expect(subagentRows([next!])[0]?.subtitle).toBe("Needs attention · opus-4-6");
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

	test("a get without usage keeps the launched model and the short id", () => {
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
		expect(row?.subtitle).toBe("Working · deepseek-v4-flash");
		expect(row?.detail).toBe("child1");
		expect(row?.progress).toBeUndefined();
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
			contextTokens: 4_000,
			contextWindow: 100_000,
		}),
		child({
			id: "bbbbbbbb-bbbb",
			title: "worker-swift-dead-code",
			state: "running",
			model: "xai/grok-4.7",
			contextTokens: 0,
			contextWindow: 100_000,
		}),
		child({
			id: "cccccccc-cccc",
			title: "scout-unlanded-branches",
			state: "success",
			model: "xai/grok-4.7",
			contextTokens: 3_000,
			contextWindow: 100_000,
		}),
	];

	test("a phone-width band keeps status and model and drops the session URL", () => {
		const lines = renderSubagentTerminal(crew, { width: 52 });
		expect(lines[0]).toBe("\u2502 \u25cf 3 subagents \u00b7 1 working");
		expect(lines.join("\n")).not.toContain("oppi://");
		expect(lines.join("\n")).not.toContain("1fa2aa56");
		const working = lines.find((line) => line.includes("worker-swift-dead-code"));
		expect(working).toContain("Working");
		expect(working).toContain("grok-4.7");
		expect(working).toContain("0%");
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
		const warned = child({ id: "child-1", title: "scout", state: "warning", model: "anthropic/claude-opus-4-6" });
		const lines = renderSubagentTerminal([warned], { width: 40, style: marked });
		expect(lines[0]).toContain("<warning>!</warning>");
		expect(lines[0]).toContain("Needs attention");
		expect(lines[1]).toContain("<warning>Needs attention</warning>");
		expect(lines.join("\n")).not.toContain("oppi://");
		const [row] = subagentRows([warned]);
		expect(rowFallback(row!)).toContain("oppi://session/child-1");
		expect(row?.subtitle).toBe("Needs attention \u00b7 opus-4-6");
	});

	test("an empty set draws nothing", () => {
		expect(renderSubagentTerminal([])).toEqual([]);
	});

	test("a wide-character name is truncated before the row can wrap", () => {
		const lines = renderSubagentTerminal(
			[child({ id: "child-1", title: "\u68c0\u67e5\u5de5\u4f5c\u6811\u5ba1\u8ba1", state: "running", model: "xai/grok-4.7" })],
			{ width: 20 },
		);
		expect(lines[1]).toContain("Working");
		expect(lines[1]).not.toContain("\u5ba1\u8ba1");
		expect(lines[1]).not.toContain("oppi://");
	});
});
