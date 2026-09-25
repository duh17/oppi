import { describe, expect, test } from "bun:test";
import {
	IDLE_FLUSH_MAX_MS,
	IDLE_FLUSH_MS,
	RESULT_GUIDANCE,
	boundaryDelivery,
	consumeSettleSuppression,
	createResultBuffer,
	formatJobResultBatch,
	nextIdleFlushDelay,
	shutdownDelivery,
} from "./delivery.ts";

describe("background result batches", () => {
	test("one batch keeps every job identity and tells the model not to acknowledge", () => {
		const batch = formatJobResultBatch([
			{ jobId: "bash-1", status: "completed", text: "bash-1 finished\noutput: one" },
			{ jobId: "bash-2", status: "failed", text: "bash-2 failed\noutput: two" },
		]);
		expect(batch?.jobIds).toEqual(["bash-1", "bash-2"]);
		expect(batch?.statuses).toEqual(["completed", "failed"]);
		expect(batch?.content).toContain(RESULT_GUIDANCE);
		expect(batch?.content).toContain("bash-1 finished");
		expect(batch?.content).toContain("bash-2 failed");
		expect(batch?.omitted).toBe(0);
	});

	test("a budget keeps the overflow for a later batch instead of merging jobs", () => {
		const batch = formatJobResultBatch(
			[
				{ jobId: "bash-1", status: "completed", text: "one".repeat(40) },
				{ jobId: "bash-2", status: "completed", text: "two".repeat(40) },
			],
			RESULT_GUIDANCE.length + 50,
		);
		expect(batch?.jobIds).toEqual(["bash-1"]);
		expect(batch?.omitted).toBe(1);
		expect(batch?.content).toContain("1 more result");
		expect(batch?.content).not.toContain("two");
	});

	test("a completed turn consumes the buffer once; a stop does not wake", () => {
		expect(boundaryDelivery({ pending: 3, outcome: "completed", alreadyContinuing: false })).toEqual({
			append: true,
			continue: true,
		});
		expect(boundaryDelivery({ pending: 3, outcome: "completed", alreadyContinuing: true })).toEqual({
			append: true,
			continue: false,
		});
		expect(boundaryDelivery({ pending: 3, outcome: "aborted", alreadyContinuing: false })).toEqual({
			append: false,
			continue: false,
		});
		expect(boundaryDelivery({ pending: 0, outcome: "completed", alreadyContinuing: false }).append).toBe(false);
	});

	test("an idle burst debounces, then a later result can wake again", () => {
		expect(nextIdleFlushDelay(1_000, undefined)).toEqual({ delay: IDLE_FLUSH_MS, startedAt: 1_000 });
		expect(nextIdleFlushDelay(1_400, 1_000).delay).toBe(IDLE_FLUSH_MS);
		expect(nextIdleFlushDelay(1_000 + IDLE_FLUSH_MAX_MS, 1_000).delay).toBe(0);
	});

	test("a stop blocks only that settle, and a later idle completion can carry the backlog", () => {
		expect(consumeSettleSuppression(true)).toEqual({ flush: false, suppressIdleWake: false });
		expect(consumeSettleSuppression(false)).toEqual({ flush: true, suppressIdleWake: false });
	});

	test("an active shutdown queues a follow-up, and an idle one only appends", () => {
		expect(shutdownDelivery({ runActive: true })).toBe("followUp");
		expect(shutdownDelivery({ runActive: false })).toBe("append");
	});

	test("repeated takes drain a budget overflow instead of dropping the tail", () => {
		const buffer = createResultBuffer();
		buffer.enqueue({ jobId: "bash-1", status: "completed", text: "one".repeat(40) });
		buffer.enqueue({ jobId: "bash-2", status: "completed", text: "two".repeat(40) });
		const first = buffer.take(80);
		expect(first?.batch.jobIds).toEqual(["bash-1"]);
		expect(first?.batch.omitted).toBe(1);
		const second = buffer.take(80);
		expect(second?.batch.jobIds).toEqual(["bash-2"]);
		expect(buffer.pendingCount()).toBe(0);
	});

	test("the same job is handed off once, and a failed send can put it back", () => {
		const buffer = createResultBuffer();
		expect(buffer.enqueue({ jobId: "bash-1", status: "completed", text: "one" })).toBe(true);
		expect(buffer.enqueue({ jobId: "bash-1", status: "completed", text: "again" })).toBe(false);
		const taken = buffer.take();
		expect(taken?.batch.jobIds).toEqual(["bash-1"]);
		expect(buffer.pendingCount()).toBe(0);
		expect(buffer.enqueue({ jobId: "bash-1", status: "completed", text: "late" })).toBe(false);
		taken?.undo();
		expect(buffer.pendingIds()).toEqual(["bash-1"]);
		expect(buffer.enqueue({ jobId: "bash-2", status: "failed", text: "two" })).toBe(true);
		expect(buffer.take()?.batch.jobIds).toEqual(["bash-1", "bash-2"]);
	});
});
