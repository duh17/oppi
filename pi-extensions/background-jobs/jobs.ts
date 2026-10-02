/**
 * Background shell jobs for the Pi extension.
 *
 * A start returns immediately. The runner keeps the process alive, and the
 * manager records one result when it ends. The extension batches those
 * results. Shutdown suppresses delivery so a dying session does not start
 * another turn.
 */

export const POLL_RULE =
	"Do NOT poll for it (no `sleep`, `ps`, `pgrep`, `top`, `pidwait`, log tailing): every poll is a wasted turn. Do other work, or end your reply and wait to be woken.";

const MAX_TIMEOUT_SECONDS = 2_147_483_647 / 1000;
const DEFAULT_MAX_RUNNING = 8;
const DEFAULT_MAX_STORED_CHARS = 64_000;

export function formatBackgroundNotice(jobId: string): string {
	return `Backgrounded as job ${jobId}; its output is delivered in a batched follow-up, not one reply per job. ${POLL_RULE}`;
}

export const BACKGROUND_POLICY = {
	foregroundWaitMs: 15_000,
	immediate: "A bash command ending in & is backgrounded immediately.",
	afterWait: "Any other bash command runs in the foreground for 15 seconds. If it is still running, it becomes a background job.",
	stayForeground: "A timeout of 1 second or less stays in the foreground and is killed by that timeout.",
} as const;

export function bashBackgroundAdvice(command: string, hasRunningJob: boolean): string | undefined {
	const trimmed = command.trim();
	if (hasRunningJob && isPollCommand(trimmed)) {
		return `A background job is already running. ${POLL_RULE}`;
	}
	return undefined;
}

export type BackgroundDisposition = {
	mode: "immediate" | "after-wait" | "foreground-only";
	command: string;
	waitMs: number;
};

export function backgroundDisposition(
	command: string,
	options: { timeoutSeconds?: number; thresholdMs?: number } = {},
): BackgroundDisposition {
	const thresholdMs = options.thresholdMs ?? BACKGROUND_POLICY.foregroundWaitMs;
	const trimmed = command.trim();
	const stripped = stripBackgroundOperator(trimmed);
	if (stripped !== undefined) {
		return { mode: "immediate", command: stripped, waitMs: 0 };
	}
	if (options.timeoutSeconds !== undefined) {
		const roomMs = options.timeoutSeconds * 1000 - 1000;
		if (roomMs <= 0) return { mode: "foreground-only", command: trimmed, waitMs: 0 };
		return { mode: "after-wait", command: trimmed, waitMs: Math.min(thresholdMs, roomMs) };
	}
	return { mode: "after-wait", command: trimmed, waitMs: thresholdMs };
}

/** Native disclosure content for one job row: its raw output tail, or a placeholder. */
export type JobOutputBlock =
	| { type: "terminal"; id: string; text: string }
	| { type: "text"; id: string; spans: Array<{ text: string; role: "muted" }> };

export interface BackgroundPill {
	status: string;
	title: string;
	subtitle: string;
	/** Terminal widget: summary, job rows, then the last output lines. */
	lines: string[];
	/** Summary and job rows only, for the native fallback. */
	summary: string[];
	/** Tapping a row shows that job's output. Display only; it is not a model update. */
	rows: Array<{
		id: string;
		title: string;
		subtitle: string;
		state: "running" | "success" | "warning" | "error";
		blocks: JobOutputBlock[];
	}>;
}

/** Raw output shared by every row of one snapshot; keeps the widget under Oppi's surface text budget. */
const ROW_OUTPUT_TOTAL_BYTES = 12 * 1024;
const ROW_OUTPUT_MAX_BYTES = 4 * 1024;
const ROW_OUTPUT_MAX_LINES = 30;

export function backgroundPill(
	jobs: Array<{ id: string; command: string; status: JobStatus; backgrounded: boolean; output?: string }>,
): BackgroundPill | undefined {
	const visible = jobs.filter((job) => job.backgrounded);
	const running = visible.filter((job) => job.status === "running");
	const finished = visible.filter((job) => job.status !== "running");
	if (running.length === 0 && finished.length === 0) return undefined;
	const title =
		running.length > 0
			? running.length === 1
				? "1 job"
				: `${running.length} jobs`
			: finished.length === 1
				? "1 result"
				: `${finished.length} results`;
	const first = compactCommand((running[0] ?? finished[0])?.command ?? "");
	const runningSubtitle = running.length <= 1 ? first : `${first} +${running.length - 1}`;
	const subtitle =
		running.length > 0 && finished.length > 0
			? `${runningSubtitle} · ${finished.length} ready`
			: running.length > 0
				? runningSubtitle
				: first;
	const status = `${title} · ${subtitle}`.slice(0, 160);
	const summary = [status, ...visible.map((job) => `${job.id} ${job.status} ${compactCommand(job.command)}`)];
	const withOutput = visible.filter((job) => (job.output ?? "").trim().length > 0).length;
	const rowBytes = Math.min(ROW_OUTPUT_MAX_BYTES, Math.floor(ROW_OUTPUT_TOTAL_BYTES / Math.max(1, withOutput)));
	return {
		status,
		title,
		subtitle,
		lines: [...summary, ...terminalTail(visible)],
		summary,
		rows: visible.map((job) => {
			const text = rawOutputTail(job.output ?? "", rowBytes, ROW_OUTPUT_MAX_LINES);
			return {
				id: job.id,
				title: job.id,
				subtitle: compactCommand(job.command),
				state: pillState(job.status),
				blocks: [
					text
						? { type: "terminal", id: `output:${job.id}`, text }
						: { type: "text", id: `output:${job.id}`, spans: [{ text: "No output yet", role: "muted" }] },
				],
			};
		}),
	};
}

/**
 * Last raw output, escapes and carriage returns kept, for a client terminal
 * renderer. Starts on a line boundary when cut, so no escape sequence or
 * codepoint is split at the front.
 */
export function rawOutputTail(output: string, maxBytes: number, maxLines: number): string {
	let tail = output.replace(/\s+$/u, "");
	if (Buffer.byteLength(tail, "utf8") > maxBytes) {
		const bytes = Buffer.from(tail, "utf8");
		tail = bytes.subarray(bytes.length - maxBytes).toString("utf8");
		const newline = tail.indexOf("\n");
		// One overlong line has no boundary; drop only a split leading codepoint.
		tail = newline >= 0 ? tail.slice(newline + 1) : tail.replace(/^\uFFFD+/u, "");
	}
	const lines = tail.split("\n");
	return lines.length > maxLines ? lines.slice(-maxLines).join("\n") : tail;
}

function pillState(status: JobStatus): "running" | "success" | "warning" | "error" {
	if (status === "running") return "running";
	if (status === "completed") return "success";
	if (status === "cancelled") return "warning";
	return "error";
}

export function outputTail(output: string, maxLines = 16): string[] {
	const lines = output.replace(/\s+$/u, "").split("\n").filter((line) => line.length > 0);
	return lines.slice(-maxLines).map((line) => (line.length > 200 ? `${line.slice(0, 199)}…` : line));
}

function terminalTail(
	jobs: Array<{ id: string; output?: string }>,
): string[] {
	const lines: string[] = [];
	for (const job of jobs) {
		const tail = outputTail(job.output ?? "");
		if (tail.length === 0) continue;
		lines.push(`# ${job.id}`);
		lines.push(...tail);
	}
	return lines.slice(-40);
}

export interface SessionExports {
	sessionId?: string;
	sessionFile?: string;
	provider?: string;
	model?: string;
	reasoning?: string;
}

export function wrapBackgroundCommand(
	command: string,
	options: { prefix?: string; session?: SessionExports } = {},
): string {
	const parts: string[] = [];
	const session = options.session;
	if (session?.sessionId) {
		parts.push(shellExport("PI_SESSION_ID", session.sessionId));
		parts.push(shellExport("OPPI_CALLER_SESSION_ID", session.sessionId));
	}
	if (session?.sessionFile) parts.push(shellExport("PI_SESSION_FILE", session.sessionFile));
	if (session?.provider) parts.push(shellExport("PI_PROVIDER", session.provider));
	if (session?.model) parts.push(shellExport("PI_MODEL", session.model));
	if (session?.reasoning) parts.push(shellExport("PI_REASONING_LEVEL", session.reasoning));
	if (options.prefix) parts.push(options.prefix);
	parts.push(command);
	return parts.join("\n");
}

export interface JobExecRequest {
	command: string;
	cwd: string;
	env?: NodeJS.ProcessEnv;
	timeout?: number;
	signal: AbortSignal;
	onData: (chunk: Buffer) => void;
}

export interface JobDelivery {
	jobId: string;
	status: JobStatus;
	text: string;
	foregroundText: string;
	isError: boolean;
}

export type JobStatus = "running" | "completed" | "failed" | "cancelled" | "timed_out";

export interface JobSnapshot {
	id: string;
	command: string;
	cwd: string;
	status: JobStatus;
	backgrounded: boolean;
	startedAt: number;
	finishedAt?: number;
	exitCode?: number | null;
	output?: string;
}

export interface JobStartInput {
	command: string;
	cwd: string;
	timeout?: number;
	env?: NodeJS.ProcessEnv;
	prefix?: string;
	session?: SessionExports;
	/** When true, the follow-up is held until release(). */
	holdDelivery?: boolean;
	/** Visible running jobs are the ones that show the pill. Default true. */
	backgrounded?: boolean;
}

export interface StartedJob {
	jobId: string;
	notice: string;
	settled: Promise<JobDelivery>;
	background(): void;
	release(): void;
	claim(): JobDelivery | undefined;
	suppress(): void;
	cancel(): void;
}

export type JobStartResult = StartedJob | { error: string };

export interface JobManager {
	start(input: JobStartInput): JobStartResult;
	cancel(jobId: string): { ok: true; text: string } | { ok: false; error: string };
	hasRunning(): boolean;
	visibleRunning(): JobSnapshot[];
	list(): JobSnapshot[];
	shutdown(): void;
}

export function createJobManager(options: {
	exec: (request: JobExecRequest) => Promise<{ exitCode: number | null }>;
	onDeliver: (delivery: JobDelivery) => void;
	onChange?: () => void;
	now?: () => number;
	maxRunning?: number;
	maxStoredChars?: number;
}): JobManager {
	const now = options.now ?? Date.now;
	const maxRunning = options.maxRunning ?? DEFAULT_MAX_RUNNING;
	const maxStoredChars = options.maxStoredChars ?? DEFAULT_MAX_STORED_CHARS;
	const jobs = new Map<string, RunningJob>();
	let seq = 0;
	let closed = false;
	let outputTimer: ReturnType<typeof setTimeout> | undefined;

	const notify = () => options.onChange?.();
	const scheduleOutputRefresh = () => {
		if (outputTimer) return;
		outputTimer = setTimeout(() => {
			outputTimer = undefined;
			notify();
		}, 400);
		outputTimer.unref?.();
	};

	const deliver = (job: RunningJob) => {
		if (!job.pendingDelivery || job.delivered || job.suppressDelivery || job.holdDelivery || closed) return;
		job.delivered = true;
		options.onDeliver(job.pendingDelivery);
		notify();
	};

	const settle = (job: RunningJob, outcome: Outcome) => {
		if (job.settled) return;
		job.settled = true;
		job.status = outcome.status;
		job.finishedAt = now();
		job.exitCode = outcome.exitCode;
		const delivery = deliveryFor(job, outcome);
		job.pendingDelivery = delivery;
		job.resolveSettled?.(delivery);
		deliver(job);
		notify();
	};

	return {
		start(input) {
			if (closed) return { error: "Background jobs are shut down. Do not poll." };
			const command = input.command.trim();
			if (!command) return { error: "background_job start requires a command." };
			const timeoutError = validateTimeout(input.timeout);
			if (timeoutError) return { error: timeoutError };
			const running = [...jobs.values()].filter((job) => !job.settled).length;
			if (running >= maxRunning) {
				return {
					error: `Too many background jobs are already running. Cancel one, or end your reply and wait to be woken. Do not poll.`,
				};
			}

			seq += 1;
			const id = `bash-${seq}`;
			const controller = new AbortController();
			let resolveSettled: (delivery: JobDelivery) => void = () => {};
			const settledPromise = new Promise<JobDelivery>((resolve) => {
				resolveSettled = resolve;
			});
			const job: RunningJob = {
				id,
				command,
				cwd: input.cwd,
				status: "running",
				backgrounded: input.backgrounded ?? true,
				startedAt: now(),
				output: "",
				truncated: false,
				settled: false,
				delivered: false,
				holdDelivery: input.holdDelivery ?? false,
				suppressDelivery: false,
				cancelRequested: false,
				timeout: input.timeout,
				controller,
				settledPromise,
				resolveSettled,
			};
			jobs.set(id, job);
			notify();

			const wrapped = wrapBackgroundCommand(command, {
				prefix: input.prefix,
				session: input.session,
			});
			void options
				.exec({
					command: wrapped,
					cwd: input.cwd,
					env: input.env,
					timeout: input.timeout,
					signal: controller.signal,
					onData: (chunk) => {
						appendOutput(job, chunk.toString(), maxStoredChars);
						if (!job.settled) scheduleOutputRefresh();
					},
				})
				.then(
					(result) => {
						if (job.cancelRequested) {
							settle(job, { status: "cancelled", exitCode: result.exitCode, timeoutSeconds: input.timeout });
							return;
						}
						const status = result.exitCode === 0 ? "completed" : "failed";
						settle(job, { status, exitCode: result.exitCode, timeoutSeconds: input.timeout });
					},
					(error: unknown) => {
						const message = error instanceof Error ? error.message : String(error);
						if (job.cancelRequested || message === "aborted") {
							settle(job, { status: "cancelled", exitCode: null, timeoutSeconds: input.timeout });
							return;
						}
						if (message.startsWith("timeout:")) {
							const seconds = Number(message.slice("timeout:".length));
							settle(job, {
								status: "timed_out",
								exitCode: null,
								timeoutSeconds: Number.isFinite(seconds) ? seconds : input.timeout,
							});
							return;
						}
						appendOutput(job, message, maxStoredChars);
						settle(job, { status: "failed", exitCode: null, timeoutSeconds: input.timeout });
					},
				);

			return {
				jobId: id,
				notice: formatBackgroundNotice(id),
				settled: settledPromise,
				background() {
					job.backgrounded = true;
					notify();
				},
				release() {
					job.holdDelivery = false;
					deliver(job);
				},
				claim() {
					job.suppressDelivery = true;
					job.holdDelivery = false;
					return job.pendingDelivery;
				},
				suppress() {
					job.suppressDelivery = true;
					job.holdDelivery = false;
				},
				cancel() {
					job.suppressDelivery = true;
					job.holdDelivery = false;
					if (!job.settled) {
						job.cancelRequested = true;
						job.controller.abort();
					}
				},
			};
		},

		cancel(jobId) {
			const job = jobs.get(jobId);
			if (!job) return { ok: false, error: `No background job ${jobId}.` };
			if (job.settled) {
				return {
					ok: false,
					error: `${jobId} already finished. Its result is delivered with other finished jobs. Do not poll.`,
				};
			}
			job.cancelRequested = true;
			job.controller.abort();
			return {
				ok: true,
				text: `Cancel requested for ${jobId}. You will be told when it stops. Do not poll.`,
			};
		},

		hasRunning() {
			return [...jobs.values()].some((job) => !job.settled);
		},

		visibleRunning() {
			return [...jobs.values()].filter((job) => !job.settled && job.backgrounded).map(snapshot);
		},

		list() {
			return [...jobs.values()].map(snapshot);
		},

		shutdown() {
			closed = true;
			if (outputTimer) clearTimeout(outputTimer);
			outputTimer = undefined;
			for (const job of jobs.values()) {
				if (job.settled) continue;
				job.suppressDelivery = true;
				job.controller.abort();
			}
		},
	};
}

function snapshot(job: RunningJob): JobSnapshot {
	return {
		id: job.id,
		command: job.command,
		cwd: job.cwd,
		status: job.status,
		backgrounded: job.backgrounded,
		startedAt: job.startedAt,
		finishedAt: job.finishedAt,
		exitCode: job.exitCode,
		output: job.output,
	};
}

function deliveryFor(job: RunningJob, outcome: Outcome): JobDelivery {
	const text = formatDelivery(job, outcome);
	const foreground = formatForegroundResult(job, outcome);
	return {
		jobId: job.id,
		status: job.status,
		text,
		foregroundText: foreground.text,
		isError: foreground.isError,
	};
}

interface RunningJob {
	id: string;
	command: string;
	cwd: string;
	status: JobStatus;
	backgrounded: boolean;
	startedAt: number;
	finishedAt?: number;
	exitCode?: number | null;
	output: string;
	truncated: boolean;
	settled: boolean;
	delivered: boolean;
	holdDelivery: boolean;
	suppressDelivery: boolean;
	cancelRequested: boolean;
	timeout?: number;
	controller: AbortController;
	settledPromise: Promise<JobDelivery>;
	resolveSettled?: (delivery: JobDelivery) => void;
	pendingDelivery?: JobDelivery;
}

interface Outcome {
	status: Exclude<JobStatus, "running">;
	exitCode: number | null;
	timeoutSeconds?: number;
}

function appendOutput(job: RunningJob, text: string, maxStoredChars: number) {
	if (!text) return;
	job.output += text;
	if (job.output.length > maxStoredChars) {
		job.truncated = true;
		job.output = job.output.slice(-maxStoredChars);
	}
}

function formatDelivery(job: RunningJob, outcome: Outcome): string {
	const headline = deliveryHeadline(job.id, outcome);
	const output = job.output.trim() ? job.output.replace(/\s+$/u, "") : "(no output)";
	const truncation = job.truncated
		? `Output truncated to the last ${job.output.length} characters. Earlier output was dropped.`
		: undefined;
	return [
		headline,
		"",
		`command: ${job.command}`,
		`cwd: ${job.cwd}`,
		"",
		truncation,
		"output:",
		output,
		"",
		"This is the final result. Do not poll for this job.",
	]
		.filter((line) => line !== undefined)
		.join("\n");
}

function deliveryHeadline(jobId: string, outcome: Outcome): string {
	if (outcome.status === "completed") return `Background job ${jobId} finished (exit ${outcome.exitCode}).`;
	if (outcome.status === "failed") {
		const exit = outcome.exitCode === null ? "no exit code" : `exit ${outcome.exitCode}`;
		return `Background job ${jobId} failed (${exit}).`;
	}
	if (outcome.status === "timed_out") {
		const seconds = outcome.timeoutSeconds ?? "the configured";
		return `Background job ${jobId} timed out after ${seconds} seconds and was killed.`;
	}
	return `Background job ${jobId} was cancelled.`;
}

function validateTimeout(timeout: number | undefined): string | undefined {
	if (timeout === undefined) return undefined;
	if (!Number.isFinite(timeout) || timeout <= 0) {
		return "Invalid timeout: must be a finite number of seconds greater than 0.";
	}
	if (timeout > MAX_TIMEOUT_SECONDS) {
		return `Invalid timeout: maximum is ${MAX_TIMEOUT_SECONDS} seconds.`;
	}
	return undefined;
}

function endsWithBackgroundOperator(command: string): boolean {
	return /(^|[^&>])&\s*$/u.test(command);
}

function stripBackgroundOperator(command: string): string | undefined {
	if (!endsWithBackgroundOperator(command)) return undefined;
	const stripped = command.replace(/&\s*$/u, "").trim();
	return stripped || undefined;
}

function compactCommand(command: string): string {
	const oneLine = command.replace(/\s+/g, " ").trim();
	return oneLine.length > 48 ? `${oneLine.slice(0, 47)}…` : oneLine;
}

export function formatForegroundResult(
	job: { output: string; truncated: boolean },
	outcome: Outcome,
): { text: string; isError: boolean } {
	const output = job.output.replace(/\s+$/u, "");
	const truncation = job.truncated
		? "\n\nOutput truncated to the last characters. Earlier output was dropped."
		: "";
	if (outcome.status === "completed") {
		return { text: `${output || "(no output)"}${truncation}`, isError: false };
	}
	if (outcome.status === "timed_out") {
		return {
			text: appendStatus(output, `Command timed out after ${outcome.timeoutSeconds ?? "the configured"} seconds`),
			isError: true,
		};
	}
	if (outcome.status === "cancelled") {
		return { text: appendStatus(output, "Command aborted"), isError: true };
	}
	const exit = outcome.exitCode === null ? "without an exit code" : `with code ${outcome.exitCode}`;
	return { text: appendStatus(output, `Command exited ${exit}`), isError: true };
}

function appendStatus(text: string, status: string): string {
	return `${text ? `${text}\n\n` : ""}${status}`;
}

export async function awaitForegroundOrBackground(input: {
	started: StartedJob;
	waitMs: number;
	signal?: AbortSignal;
	wait?: (ms: number, signal?: AbortSignal) => Promise<void>;
}): Promise<
	| { kind: "foreground"; text: string; isError: boolean }
	| { kind: "background"; jobId: string; notice: string }
	| { kind: "aborted"; text: string }
> {
	const wait = input.wait ?? waitForForeground;
	try {
		if (input.signal?.aborted) throw new Error("aborted");
		const winner = await Promise.race([
			input.started.settled.then(() => "settled" as const),
			wait(input.waitMs, input.signal).then(() => "wait" as const),
		]);
		if (winner === "settled") {
			const delivery = input.started.claim();
			return {
				kind: "foreground",
				text: delivery?.foregroundText ?? "(no output)",
				isError: delivery?.isError ?? true,
			};
		}
		input.started.background();
		input.started.release();
		return { kind: "background", jobId: input.started.jobId, notice: input.started.notice };
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		if (message === "aborted" || input.signal?.aborted) {
			input.started.suppress();
			input.started.cancel();
			return { kind: "aborted", text: "Command aborted" };
		}
		throw error;
	}
}

export function waitForForeground(ms: number, signal?: AbortSignal): Promise<void> {
	return new Promise((resolve, reject) => {
		if (signal?.aborted) {
			reject(new Error("aborted"));
			return;
		}
		const timer = setTimeout(() => {
			signal?.removeEventListener("abort", onAbort);
			resolve();
		}, ms);
		const onAbort = () => {
			clearTimeout(timer);
			reject(new Error("aborted"));
		};
		signal?.addEventListener("abort", onAbort, { once: true });
	});
}

export interface PolicyResult {
	text: string;
	isError: boolean;
	backgrounded: boolean;
	jobId?: string;
}

export function runBackgroundPolicy(input: {
	manager: JobManager;
	exec: (request: JobExecRequest) => Promise<{ exitCode: number | null }>;
	command: string;
	cwd: string;
	timeout?: number;
	signal?: AbortSignal;
	prefix?: string;
	session?: SessionExports;
	env?: NodeJS.ProcessEnv;
	wait?: (ms: number, signal?: AbortSignal) => Promise<void>;
	thresholdMs?: number;
}): Promise<PolicyResult> {
	const disposition = backgroundDisposition(input.command, {
		timeoutSeconds: input.timeout,
		thresholdMs: input.thresholdMs,
	});
	if (disposition.mode === "foreground-only") return runDirect(input, disposition.command);
	const started = input.manager.start({
		command: disposition.command,
		cwd: input.cwd,
		timeout: input.timeout,
		env: input.env,
		prefix: input.prefix,
		session: input.session,
		holdDelivery: disposition.mode === "after-wait",
		backgrounded: disposition.mode === "immediate",
	});
	if ("error" in started) return runDirect(input, disposition.command);
	if (disposition.mode === "immediate") {
		return Promise.resolve({
			text: `${started.notice}\n\ncommand: ${disposition.command}`,
			isError: false,
			backgrounded: true,
			jobId: started.jobId,
		});
	}
	return awaitForegroundOrBackground({
		started,
		waitMs: disposition.waitMs,
		signal: input.signal,
		wait: input.wait,
	}).then((result) => {
		if (result.kind === "foreground") {
			return { text: result.text, isError: result.isError, backgrounded: false, jobId: started.jobId };
		}
		if (result.kind === "aborted") {
			return { text: result.text, isError: true, backgrounded: false };
		}
		return {
			text: `${started.notice}\n\ncommand: ${disposition.command}`,
			isError: false,
			backgrounded: true,
			jobId: started.jobId,
		};
	});
}

function runDirect(
	input: {
		exec: (request: JobExecRequest) => Promise<{ exitCode: number | null }>;
		cwd: string;
		timeout?: number;
		signal?: AbortSignal;
		prefix?: string;
		session?: SessionExports;
		env?: NodeJS.ProcessEnv;
	},
	command: string,
): Promise<PolicyResult> {
	const controller = new AbortController();
	const onAbort = () => controller.abort();
	input.signal?.addEventListener("abort", onAbort);
	let output = "";
	let truncated = false;
	const pending = input.exec({
		command: wrapBackgroundCommand(command, { prefix: input.prefix, session: input.session }),
		cwd: input.cwd,
		env: input.env,
		timeout: input.timeout,
		signal: controller.signal,
		onData: (chunk) => {
			output += chunk.toString();
			if (output.length > DEFAULT_MAX_STORED_CHARS) {
				truncated = true;
				output = output.slice(-DEFAULT_MAX_STORED_CHARS);
			}
		},
	});
	return pending.then(
		(result) => {
			input.signal?.removeEventListener("abort", onAbort);
			const status = result.exitCode === 0 ? "completed" : "failed";
			const formatted = formatForegroundResult({ output, truncated }, { status, exitCode: result.exitCode });
			return { text: formatted.text, isError: formatted.isError, backgrounded: false };
		},
		(error: unknown) => {
			input.signal?.removeEventListener("abort", onAbort);
			const message = error instanceof Error ? error.message : String(error);
			if (message === "aborted" || input.signal?.aborted) {
				return { text: "Command aborted", isError: true, backgrounded: false };
			}
			if (message.startsWith("timeout:")) {
				const seconds = Number(message.slice("timeout:".length));
				const formatted = formatForegroundResult(
					{ output, truncated },
					{ status: "timed_out", exitCode: null, timeoutSeconds: Number.isFinite(seconds) ? seconds : input.timeout },
				);
				return { text: formatted.text, isError: true, backgrounded: false };
			}
			return { text: message || "Command failed", isError: true, backgrounded: false };
		},
	);
}

function isPollCommand(command: string): boolean {
	if (/^(sleep\s+\d+(?:\.\d+)?|ps(?:\s|$)|pgrep\b|pidwait\b|top\b|tail\s+-[fF]\b)/u.test(command)) {
		return true;
	}
	return /^sleep\s+\d+(?:\.\d+)?\s*(?:&&|;)\s*(ps|pgrep|pidwait|top|tail)\b/u.test(command);
}

function shellExport(name: string, value: string): string {
	return `export ${name}=${shellSingleQuote(value)}`;
}

function shellSingleQuote(value: string): string {
	return `'${value.replaceAll("'", `'\\''`)}'`;
}
