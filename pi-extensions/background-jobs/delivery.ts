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
	/** Unique across processes. Job ids restart at bash-1 in every extension instance. Defaults to jobId. */
	key?: string;
	jobId: string;
	status: string;
	text: string;
}

export interface JobResultBatch {
	content: string;
	keys: string[];
	jobIds: string[];
	statuses: string[];
	omitted: number;
}

const keyOf = (result: PendingJobResult): string => result.key ?? result.jobId;

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
		keys: included.map(keyOf),
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

/** Custom entry recording a backgrounded job, so a later process can tell it never reported. */
export const STARTED_ENTRY = "background-job-started";

export interface StartedJobRecord {
	key: string;
	jobId: string;
	command: string;
	cwd: string;
}

/**
 * Backgrounded jobs whose result never reached the transcript. Their process died with the
 * previous extension instance (server restart, reload, crash, or stop). A delivered batch
 * names its jobs in `details.keys`. Only records `sessionId` wrote count: a fork copies the
 * source's records while the source may still be running those jobs.
 */
export function unreportedJobs(entries: readonly unknown[], sessionId: string): StartedJobRecord[] {
	const started = new Map<string, StartedJobRecord>();
	const reported = new Set<string>();
	for (const entry of entries) {
		if (!entry || typeof entry !== "object") continue;
		const item = entry as { type?: unknown; customType?: unknown; data?: unknown; details?: unknown };
		if (item.type === "custom" && item.customType === STARTED_ENTRY) {
			const data = item.data as (Partial<StartedJobRecord> & { sessionId?: unknown }) | undefined;
			if (typeof data?.key !== "string" || typeof data.jobId !== "string" || data.sessionId !== sessionId) continue;
			started.set(data.key, {
				key: data.key,
				jobId: data.jobId,
				command: typeof data.command === "string" ? data.command : "",
				cwd: typeof data.cwd === "string" ? data.cwd : "",
			});
		} else if (item.type === "custom_message" && item.customType === "background-job") {
			const keys = (item.details as { keys?: unknown } | undefined)?.keys;
			if (Array.isArray(keys)) for (const key of keys) if (typeof key === "string") reported.add(key);
		}
	}
	return [...started.values()].filter((job) => !reported.has(job.key));
}

export function unreportedJobText(job: StartedJobRecord): string {
	return [
		`Background job ${job.jobId} never reported back: the session restarted, reloaded, or was stopped while it ran, which killed it. Whether it finished is unknown, and it was not rerun. Check its effects before relying on them. If the session was stopped on purpose, do not rerun it unless the user asks.`,
		"",
		`command: ${job.command}`,
		`cwd: ${job.cwd}`,
		"",
		"This is the final result. Do not poll for this job.",
	].join("\n");
}

export interface ResultBuffer {
	enqueue(result: PendingJobResult): boolean;
	pendingCount(): number;
	pendingKeys(): string[];
	take(budget?: number): { batch: JobResultBatch; undo: () => void } | undefined;
	clear(): void;
}

export function createResultBuffer(): ResultBuffer {
	const pending: PendingJobResult[] = [];
	const handedOff = new Set<string>();

	const remove = (keys: readonly string[]): PendingJobResult[] => {
		const taken = new Set(keys);
		const removed: PendingJobResult[] = [];
		for (let index = pending.length - 1; index >= 0; index -= 1) {
			const item = pending[index];
			if (!item || !taken.has(keyOf(item))) continue;
			removed.push(item);
			pending.splice(index, 1);
		}
		return removed.reverse();
	};

	return {
		enqueue(result: PendingJobResult): boolean {
			const key = keyOf(result);
			if (!key || handedOff.has(key) || pending.some((item) => keyOf(item) === key)) {
				return false;
			}
			pending.push(result);
			return true;
		},
		pendingCount(): number {
			return pending.length;
		},
		pendingKeys(): string[] {
			return pending.map(keyOf);
		},
		take(budget = RESULT_BATCH_BUDGET): { batch: JobResultBatch; undo: () => void } | undefined {
			const batch = formatJobResultBatch(pending, budget);
			if (!batch) return undefined;
			const removed = remove(batch.keys);
			for (const key of batch.keys) handedOff.add(key);
			return {
				batch,
				undo: () => {
					for (const key of batch.keys) handedOff.delete(key);
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
