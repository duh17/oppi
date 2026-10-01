import { describe, expect, test } from "bun:test";
import {
	attentionText,
	cacheWarmingOverride,
	isFailedWaitEnvelope,
	isSettledStatus,
	launchPlan,
	launchReceipt,
	missingModelError,
	needsAttention,
	nextStall,
	parentDelivery,
	readWait,
	reduceWait,
	restoreSupervised,
	settlementText,
	shouldClearAttention,
	waitPlan,
	type WatchChild,
} from "./supervise.ts";

const running: WatchChild = {
	id: "child-1111-1111-1111-111111111111",
	name: "scout",
	supervise: true,
	attentionDelivered: false,
};

describe("subagent cache warming", () => {
	test("asks Pi to warm only when a pending child makes the refresh worth its cost", () => {
		expect(
			cacheWarmingOverride({ pendingSupervised: true, action: "stop", warmCost: 0.01, missCost: 0.08 }),
		).toEqual({ action: "warm" });
		expect(
			cacheWarmingOverride({ pendingSupervised: true, action: "warm", warmCost: 0.01, missCost: 0.08 }),
		).toBeUndefined();
		expect(
			cacheWarmingOverride({ pendingSupervised: false, action: "stop", warmCost: 0.01, missCost: 0.08 }),
		).toBeUndefined();
		expect(
			cacheWarmingOverride({ pendingSupervised: true, action: "stop", warmCost: 0.05, missCost: 0.09 }),
		).toBeUndefined();
		expect(
			cacheWarmingOverride({ pendingSupervised: true, action: "stop", warmCost: Number.NaN, missCost: 1 }),
		).toBeUndefined();
	});

	test("launch receipt tells the parent not to wait, and attention pauses the warm", () => {
		expect(launchReceipt({ name: "scout", id: running.id, supervise: true, link: "oppi://session/x" })).toContain(
			"Do not poll with session wait",
		);
		expect(launchReceipt({ name: "scout", id: running.id, supervise: true, link: "oppi://session/x" })).toContain(
			"Inspect a settled child only when",
		);
		expect(launchReceipt({ name: "scout", id: running.id, supervise: false, link: "oppi://session/x" })).toContain(
			"Not supervising",
		);
		expect(attentionText({ name: "scout", link: "oppi://session/x" })).toContain("pause");
		expect(isSettledStatus("ready")).toBe(true);
		expect(isSettledStatus("busy")).toBe(false);
		expect(needsAttention(1)).toBe(true);
		expect(needsAttention(0)).toBe(false);
	});

	test("settlement is one message with the session link and a clipped reply", () => {
		const text = settlementText([
			{
				name: "scout",
				id: running.id,
				status: "stopped",
				link: `oppi://session/${running.id}`,
				lastMessage: "x".repeat(2000),
			},
		]);
		expect(text).toContain(`oppi://session/${running.id}`);
		expect(text).toContain("stopped");
		expect(text.length).toBeLessThan(1800);
		expect(text).toContain("do not relaunch");
	});
});

describe("wait reading", () => {
	test("a timeout with pending dialogs is attention, and ready is settled", () => {
		const reading = readWait({
			ok: true,
			data: {
				timed_out: true,
				sessions: [
					{ session_id: "busy-1", status: "busy", pending_dialogs: 0, last: "working" },
					{ session_id: "ask-1", status: "busy", pending_dialogs: 1 },
					{ session_id: "done-1", status: "ready", pending_dialogs: 0, last: "finished" },
				],
			},
		});
		expect(reading.timedOut).toBe(true);
		expect(reading.running.map((item) => item.id)).toEqual(["busy-1"]);
		expect(reading.attention.map((item) => item.id)).toEqual(["ask-1"]);
		expect(reading.settled.map((item) => item.id)).toEqual(["done-1"]);
		const first = nextStall(undefined, "busy:working", 0);
		expect(first.stalled).toBe(false);
		const stalled = nextStall(first.state, "busy:working", 30 * 60 * 1000);
		expect(stalled.stalled).toBe(true);
		expect(nextStall(stalled.state, "busy:working", 40 * 60 * 1000).stalled).toBe(false);
	});
});

describe("supervision loop", () => {
	const latched: WatchChild = { ...running, id: "latched-1", name: "ask", attentionDelivered: true };
	const active: WatchChild = { ...running, id: "active-1", name: "worker", attentionDelivered: false };

	test("a latched sibling stays on an idle wait while another child stays on either", () => {
		const plan = waitPlan([latched, active], new Set());
		expect(plan.eitherIds).toEqual(["active-1"]);
		expect(plan.idleIds).toEqual(["latched-1"]);
	});

	test("a detached or bash launch is waited for widget updates without a parent settle turn", () => {
		const widgetOnly: WatchChild = { ...running, id: "bash-1", name: "from-bash", supervise: false };
		const plan = waitPlan([widgetOnly, active], new Set());
		expect(plan.eitherIds).toEqual(["bash-1", "active-1"]);
		const effect = reduceWait({
			children: [widgetOnly, active],
			settledIds: new Set(),
			reading: readWait({
				ok: true,
				data: { session_id: "bash-1", status: "ready", reason: "idle" },
			}),
			now: 10_000,
			stalls: new Map(),
		});
		expect(effect.settle).toEqual([]);
		expect(effect.widgetSettle).toEqual(["bash-1"]);
		const afterRelease = waitPlan([widgetOnly, active], new Set(["active-1"]));
		expect(afterRelease.eitherIds).toEqual(["bash-1"]);
		expect(afterRelease.idleIds).toEqual([]);
	});

	test("a latched child that becomes ready still settles", () => {
		const effect = reduceWait({
			children: [latched, active],
			settledIds: new Set(),
			reading: readWait({ ok: true, data: { session_id: "latched-1", status: "ready", reason: "idle", output_delta: "done" } }),
			now: 10_000,
			stalls: new Map(),
		});
		expect(effect.settle.map((item) => item.id)).toEqual(["latched-1"]);
	});

	test("a timeout without pending_dialogs does not clear attention", () => {
		expect(shouldClearAttention(undefined)).toBe(false);
		expect(shouldClearAttention(0)).toBe(true);
		const effect = reduceWait({
			children: [latched],
			settledIds: new Set(),
			reading: readWait({ ok: true, data: { timed_out: true, sessions: [{ session_id: "latched-1", status: "busy" }] } }),
			now: 1,
			stalls: new Map(),
		});
		expect(effect.clearAttention).toEqual([]);
		expect(effect.attention).toEqual([]);
		expect(effect.stall).toEqual([]);
	});

	test("a failed wait envelope is not a successful timeout", () => {
		expect(isFailedWaitEnvelope({ ok: false, error: { message: "missing" } }, 1)).toBe(true);
		expect(isFailedWaitEnvelope({ ok: true, data: { timed_out: true, sessions: [] } }, 0)).toBe(false);
	});

	test("settlement starts a visible parent turn and there is no cache-touch delivery", () => {
		expect(parentDelivery("settled")).toEqual({
			customType: "subagent-settled",
			display: true,
			deliverAs: "followUp",
			triggerTurn: true,
		});
		expect(parentDelivery("attention").customType).toBe("subagent-attention");
		expect(parentDelivery("failure").triggerTurn).toBe(true);
	});
});

describe("subagent model requirement", () => {
	test("rejects a launch that would silently inherit the parent's model", () => {
		expect(missingModelError({})).toContain("Pass model");
		expect(missingModelError({ model: "  " })).toContain("Pass model");
		expect(missingModelError({ agent: "workspace_default" })).toContain("Pass model");
	});

	test("accepts an explicit model, or a saved agent that brings its own default", () => {
		expect(missingModelError({ model: "openai/gpt-6.1-sol" })).toBeNull();
		expect(missingModelError({ model: "openai/gpt-6-astra", agent: "workspace_default" })).toBeNull();
		expect(missingModelError({ agent: "LHSj_iDJ" })).toBeNull();
	});
});

describe("subagent launch plan", () => {
	test("creates through the caller env and does not wait or list", () => {
		const plan = launchPlan({
			workspace: "oppi",
			prompt: "Find the owner.",
			name: "scout",
			model: "openai-codex/gpt-5.6-luna",
			thinking: "medium",
			agent: "Scout",
			autoStop: true,
			supervise: true,
			parentId: "parent-1",
			idempotencyKey: "scout-owner",
		});
		expect(plan.args).toContain("create");
		expect(plan.args).toContain("--prompt");
		expect(plan.args).toContain("@-");
		expect(plan.stdin).toBe("Find the owner.");
		expect(plan.env.OPPI_CALLER_SESSION_ID).toBe("parent-1");
		expect(plan.args.join(" ")).not.toMatch(/\bwait\b/);
		expect(plan.args.join(" ")).not.toContain("list");
	});

	test("restore resumes only supervised launches and drops a release", () => {
		const restored = restoreSupervised([
			{ type: "custom", customType: "subagent-supervised", data: { id: "a", name: "scout", supervise: true } },
			{ type: "custom", customType: "subagent-supervised", data: { id: "b", name: "later", supervise: false } },
			{ type: "custom", customType: "other", data: { id: "c", name: "nope", supervise: true } },
			{ type: "custom", customType: "subagent-supervised", data: { id: "a", name: "scout", supervise: true, released: true } },
			{ type: "custom", customType: "subagent-supervised", data: { id: "d", name: "worker", supervise: true } },
		]);
		expect(restored.map((item) => item.id)).toEqual(["d"]);
		expect(restored[0]?.supervise).toBe(true);
	});
});
