import { afterAll, describe, expect, mock, test } from "bun:test";
import { EventEmitter } from "node:events";

const calls: string[][] = [];
const waitChildren: Array<EventEmitter & { stdout: EventEmitter }> = [];
const getChildren: Array<EventEmitter & { stdout: EventEmitter }> = [];
const buildType = () => ({});
mock.module("@sinclair/typebox", () => ({
	Type: { Object: buildType, Optional: buildType, String: buildType, Boolean: buildType },
}));
mock.module("@earendil-works/pi-ai", () => ({ StringEnum: buildType }));
mock.module("node:child_process", () => ({
	spawn: (_command: string, args: string[]) => {
		calls.push(args);
		const child = new EventEmitter() as EventEmitter & {
			stdout: EventEmitter;
			stderr: EventEmitter;
			stdin: EventEmitter & { write: (value: string) => void; end: () => void };
			kill: () => void;
		};
		child.stdout = new EventEmitter();
		child.stderr = new EventEmitter();
		if (args[1] === "wait") waitChildren.push(child);
		if (args[1] === "get") getChildren.push(child);
		child.kill = () => {};
		child.stdin = Object.assign(new EventEmitter(), {
			write: (_value: string) => {},
			end: () => {
				if (args[1] !== "create") return;
				queueMicrotask(() => {
					child.stdout.emit("data", '{"ok":true,"data":{"session_id":"child-1"}}');
					child.emit("close", 0);
				});
			},
		});
		return child;
	},
}));

const originalSetInterval = globalThis.setInterval;
afterAll(() => {
	globalThis.setInterval = originalSetInterval;
});

describe("subagent refresh", () => {
	test("a late launch snapshot keeps wait-owned attention without recurring reads", async () => {
		const intervals: number[] = [];
		globalThis.setInterval = ((...args: Parameters<typeof setInterval>) => {
			intervals.push(args[1] as number);
			return {} as ReturnType<typeof setInterval>;
		}) as typeof setInterval;
		const handlers = new Map<string, (...args: unknown[]) => void>();
		let tool: { execute: (...args: unknown[]) => Promise<unknown> } | undefined;
		let status: string | undefined;
		type Row = { state: string; subtitle: string; detail?: string; progress?: number };
		let row: Row | undefined;
		const { default: extension } = await import("./index.ts");
		extension({
			on: (event: string, handler: (...args: unknown[]) => void) => { handlers.set(event, handler); },
			registerTool: (definition: typeof tool) => { tool = definition; },
			appendEntry: () => {},
			sendMessage: () => {},
		} as never);
		const ctx = {
			ui: {
				setStatus: (_key: string, value: string | undefined) => { status = value; },
				setWidget: (_key: string, value: unknown) => {
					if (typeof value !== "function") return;
					const widget = (value as () => { renderNative: () => { blocks: Array<{ rows: Row[] }> } })();
					row = widget.renderNative().blocks[0]?.rows[0];
				},
			},
			sessionManager: { getSessionId: () => "parent-1", getEntries: () => [] },
		};
		handlers.get("session_start")?.({}, ctx);
		expect(tool).toBeDefined();
		await tool!.execute("call-1", { action: "launch", workspace: "oppi", prompt: "Hello", name: "child", model: "test/model" }, null, null, ctx);
		expect(getChildren).toHaveLength(1);
		const waitChild = waitChildren[0];
		expect(waitChild).toBeDefined();
		waitChild!.stdout.emit("data", '{"ok":true,"data":{"session_id":"child-1","status":"busy","pending_dialogs":1,"reason":"attention"}}');
		waitChild!.emit("close", 0);
		expect(status).toBe("Needs attention");
		getChildren[0]!.stdout.emit("data", '{"ok":true,"data":{"session":{"id":"child-1","status":"busy","model":"test/model","contextTokens":50000,"contextWindow":100000}}}');
		getChildren[0]!.emit("close", 0);
		await new Promise<void>((resolve) => setImmediate(resolve));
		expect(row?.state).toBe("warning");
		expect(row?.subtitle).toBe("Needs attention · model");
		expect(row?.detail).toBe("50%");
		expect(row?.progress).toBeCloseTo(0.5);
		const idleWait = waitChildren[1];
		expect(idleWait).toBeDefined();
		idleWait!.stdout.emit("data", '{"ok":true,"data":{"session_id":"child-1","status":"ready","reason":"idle"}}');
		idleWait!.emit("close", 0);
		expect(status).toBe("Done");
		expect(calls.filter((args) => args[1] === "get")).toHaveLength(1);
		expect(intervals).toEqual([]);
		handlers.get("session_shutdown")?.();
	});
});

describe("subagent launch model", () => {
	test("a launch that would inherit the parent's model errors before any session create", async () => {
		let tool: { execute: (...args: unknown[]) => Promise<{ isError?: boolean }> } | undefined;
		const ctx = {
			ui: { setStatus: () => {}, setWidget: () => {} },
			sessionManager: { getSessionId: () => "parent-2", getEntries: () => [] },
		};
		const handlers = new Map<string, (...args: unknown[]) => void>();
		const { default: extension } = await import("./index.ts");
		extension({
			on: (event: string, handler: (...args: unknown[]) => void) => { handlers.set(event, handler); },
			registerTool: (definition: typeof tool) => { tool = definition; },
			appendEntry: () => {},
			sendMessage: () => {},
		} as never);
		handlers.get("session_start")?.({}, ctx);
		const createsBefore = calls.filter((args) => args[1] === "create").length;
		for (const agent of [undefined, "workspace_default", "default"]) {
			const result = await tool!.execute("call-x", { action: "launch", workspace: "oppi", prompt: "Hi", agent }, null, null, ctx);
			expect(result.isError).toBe(true);
		}
		expect(calls.filter((args) => args[1] === "create").length).toBe(createsBefore);
	});
});
