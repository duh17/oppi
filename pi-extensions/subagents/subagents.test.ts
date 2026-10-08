import { describe, expect, test } from "bun:test";
import {
	applyGet,
	applyWaitReading,
	refreshLaunched,
	renderSubagentTerminal,
	rowFallback,
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
