/**
 * Batches background-job results so one model wake can carry many completions.
 *
 * The extension decides when a batch is appended or sent. This module formats
 * the batch, tracks which job ids have already been handed off, and chooses
 * the idle debounce. It does not call Pi.
 */

export const RESULT_BATCH_BUDGET = 24_000;
export const IDLE_FLUSH_MS = 750;
export const IDLE_FLUSH_MAX_MS = 5_000;

export const RESULT_GUIDANCE =
	"These are background job results, not a new user request. Integrate useful findings, changes, failures, or blockers. Do not reply only to acknowledge results that are already covered.";

export type ActivityOutcome = "completed" | "aborted" | "error";

export interface PendingJobResult {
	jobId: string;
	status: string;
	text: string;
}

export interface JobResultBatch {
	content: string;
	jobIds: string[];
	statuses: string[];
	omitted: number;
}

export interface BoundaryDelivery {
	/** Append the batch to the transcript. */
	append: boolean;
	/** Ask Pi for one more model request. Omit this when another continuation already exists. */
	continue: boolean;
}

export function formatJobResultBatch(
	results: readonly PendingJobResult[],
	budget = RESULT_BATCH_BUDGET,
): JobResultBatch | undefined {
	if (results.length === 0) return undefined;
	const included: PendingJobResult[] = [];
	let used = RESULT_GUIDANCE.length + 2;
	for (const result of results) {
		const block = result.text.trim();
		const next = used + block.length + 2;
		if (included.length > 0 && next > budget) break;
		included.push(result);
		used = next;
		if (used >= budget) break;
	}
	const omitted = results.length - included.length;
	const parts = [RESULT_GUIDANCE, "", ...included.map((result) => result.text.trim())];
	if (omitted > 0) {
		parts.push(
			"",
			`${omitted} more result${omitted === 1 ? "" : "s"} remain and will arrive in a later batch.`,
		);
	}
	return {
		content: parts.join("\n"),
		jobIds: included.map((result) => result.jobId),
		statuses: included.map((result) => result.status),
		omitted,
	};
}

/**
 * A completed turn ends on an assistant message, so Pi's pre-append
 * `canContinue` is often false. Appending the batch makes the next model
 * message legal. A stop or error must not undo that stop, so those outcomes
 * keep the buffer for a later authorized turn.
 */
export function boundaryDelivery(input: {
	pending: number;
	outcome: ActivityOutcome;
	alreadyContinuing: boolean;
}): BoundaryDelivery {
	if (input.pending <= 0 || input.outcome !== "completed") {
		return { append: false, continue: false };
	}
	return { append: true, continue: !input.alreadyContinuing };
}

/** A stop blocks only the settle that follows it. A later idle completion may wake. */
export function consumeSettleSuppression(suppressIdleWake: boolean): {
	flush: boolean;
	suppressIdleWake: boolean;
} {
	return { flush: !suppressIdleWake, suppressIdleWake: false };
}

/**
 * An active run queues a follow-up on the agent, which survives reload.
 * An idle shutdown, including reload, only appends. `triggerTurn: true`
 * while idle starts a turn and then loses it when the runner is replaced.
 */
export function shutdownDelivery(input: { runActive: boolean }): "followUp" | "append" {
	return input.runActive ? "followUp" : "append";
}

export function nextIdleFlushDelay(
	now: number,
	startedAt: number | undefined,
): { delay: number; startedAt: number } {
	const start = startedAt ?? now;
	const waited = Math.max(0, now - start);
	return {
		delay: waited >= IDLE_FLUSH_MAX_MS ? 0 : IDLE_FLUSH_MS,
		startedAt: start,
	};
}

export function createResultBuffer() {
	const pending: PendingJobResult[] = [];
	const handedOff = new Set<string>();

	const remove = (ids: readonly string[]): PendingJobResult[] => {
		const taken = new Set(ids);
		const removed: PendingJobResult[] = [];
		for (let index = pending.length - 1; index >= 0; index -= 1) {
			const item = pending[index];
			if (!item || !taken.has(item.jobId)) continue;
			removed.push(item);
			pending.splice(index, 1);
		}
		return removed.reverse();
	};

	return {
		enqueue(result: PendingJobResult): boolean {
			if (!result.jobId || handedOff.has(result.jobId) || pending.some((item) => item.jobId === result.jobId)) {
				return false;
			}
			pending.push(result);
			return true;
		},
		pendingCount(): number {
			return pending.length;
		},
		pendingIds(): string[] {
			return pending.map((item) => item.jobId);
		},
		take(budget = RESULT_BATCH_BUDGET): { batch: JobResultBatch; undo: () => void } | undefined {
			const batch = formatJobResultBatch(pending, budget);
			if (!batch) return undefined;
			const removed = remove(batch.jobIds);
			for (const id of batch.jobIds) handedOff.add(id);
			return {
				batch,
				undo: () => {
					for (const id of batch.jobIds) handedOff.delete(id);
					pending.unshift(...removed);
				},
			};
		},
		clear(): void {
			pending.length = 0;
			handedOff.clear();
		},
	};
}
