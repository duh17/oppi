import { describe, expect, test } from "bun:test";
import { applyGet, refreshLaunched, subagentFromCreate, subagentRows } from "./subagents.ts";

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
});
