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

export interface BackgroundWidgetJob {
	id: string;
	command: string;
	status: JobStatus;
	startedAt?: number;
	finishedAt?: number;
	output?: string;
}

/** Theme hooks for the terminal band. Plain text uses identity functions. */
export interface WidgetStyle {
	accent: (text: string) => string;
	success: (text: string) => string;
	warning: (text: string) => string;
	error: (text: string) => string;
	muted: (text: string) => string;
	dim: (text: string) => string;
	title: (text: string) => string;
	output: (text: string) => string;
	rule: (text: string) => string;
	bold: (text: string) => string;
}

export interface BackgroundPill {
	status: string;
	title: string;
	subtitle: string;
	/** Collapsed terminal band. The TUI re-renders this from widgetJobs so it can expand. */
	lines: string[];
	/** Same collapsed band, for a client that cannot draw the native surface. */
	summary: string[];
	/** Live source for the terminal widget. Not a protocol field. */
	widgetJobs: BackgroundWidgetJob[];
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
	jobs: Array<{
		id: string;
		command: string;
		status: JobStatus;
		backgrounded: boolean;
		output?: string;
		startedAt?: number;
		finishedAt?: number;
	}>,
	now = Date.now(),
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
	const elapsed = bandElapsed(running.length > 0 ? running : finished, now);
	const ready = running.length > 0 && finished.length > 0 ? `${finished.length} ready` : undefined;
	const status = [title, elapsed, ready].filter(Boolean).join(" · ").slice(0, 160);
	const widgetJobs = visible.map((job) => ({
		id: job.id,
		command: job.command,
		status: job.status,
		startedAt: job.startedAt,
		finishedAt: job.finishedAt,
		output: job.output,
	}));
	const lines = renderBackgroundWidget(widgetJobs, { now });
	const withOutput = visible.filter((job) => (job.output ?? "").trim().length > 0).length;
	const rowBytes = Math.min(ROW_OUTPUT_MAX_BYTES, Math.floor(ROW_OUTPUT_TOTAL_BYTES / Math.max(1, withOutput)));
	return {
		status,
		title,
		subtitle,
		lines,
		summary: lines,
		widgetJobs,
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

const ACTIVITY_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
export const ACTIVITY_FRAME_MS = 80;
const EXPANDED_OUTPUT_LINES = 24;
const plainStyle: WidgetStyle = {
	accent: (text) => text,
	success: (text) => text,
	warning: (text) => text,
	error: (text) => text,
	muted: (text) => text,
	dim: (text) => text,
	title: (text) => text,
	output: (text) => text,
	rule: (text) => text,
	bold: (text) => text,
};

/** Braille activity frame on a shared clock, same 80ms cadence as OMP's status band. */
export function activityFrame(now = Date.now()): string {
	return ACTIVITY_FRAMES[Math.floor(now / ACTIVITY_FRAME_MS) % ACTIVITY_FRAMES.length] ?? "⠋";
}

/** Whole-unit age: 12s, then 3m, then 1h. Matches OMP's status-band timer. */
export function formatJobElapsed(ms: number): string {
	const seconds = Math.max(0, Math.floor(ms / 1000));
	if (seconds < 60) return `${seconds}s`;
	if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
	return `${Math.min(99, Math.floor(seconds / 3600))}h`;
}

export function backgroundWidgetExpands(jobs: readonly BackgroundWidgetJob[]): boolean {
	return jobs.some((job) => {
		const lines = displayLines(job.output ?? "");
		return lines.length > 1 || lines.some((line) => line.length > 72) || displayCommand(job.command).length > 48;
	});
}

/**
 * Terminal band for live jobs. Collapsed keeps one output line and an expand
 * hint. Expanded reveals the tail; the caller wraps those lines to the pane.
 */
export function renderBackgroundWidget(
	jobs: readonly BackgroundWidgetJob[],
	options: { now?: number; expanded?: boolean; frame?: string; style?: WidgetStyle; hint?: string } = {},
): string[] {
	if (jobs.length === 0) return [];
	const now = options.now ?? Date.now();
	const style = options.style ?? plainStyle;
	const expanded = options.expanded === true;
	const hint = options.hint ?? "ctrl+o";
	const running = jobs.filter((job) => job.status === "running");
	const finished = jobs.filter((job) => job.status !== "running");
	const title =
		running.length > 0
			? running.length === 1
				? "1 job"
				: `${running.length} jobs`
			: finished.length === 1
				? "1 result"
				: `${finished.length} results`;
	const headerMark = running.length > 0 ? (options.frame ?? "⚙") : headerGlyph(jobs);
	const headerColor = running.length > 0 ? style.accent : statePaint(style, pillState(worstStatus(jobs)));
	const meta = [bandElapsed(running.length > 0 ? running : finished, now), readyLabel(running.length, finished.length)]
		.filter(Boolean)
		.join(" · ");
	const lines = [
		joinParts([
			style.rule("│"),
			headerColor(headerMark),
			style.bold(headerColor(title)),
			meta ? style.dim(`· ${meta}`) : "",
		]),
	];
	for (const job of jobs) {
		const paint = statePaint(style, pillState(job.status));
		const age = jobElapsed(job, now);
		lines.push(
			joinParts([
				style.rule("│"),
				paint(job.status === "running" ? "●" : headerGlyph([job])),
				style.bold(style.title(job.id)),
				paint(`[${badgeLabel(job.status)}]`),
				age ? style.dim(`· ${age}`) : "",
				style.dim("·"),
				style.muted(displayCommand(job.command)),
			]),
		);
	}
	const hidden = hiddenOutputCount(jobs, expanded);
	for (const block of outputBlocks(jobs, expanded)) {
		if (jobs.length > 1) lines.push(joinParts([style.rule("│"), style.dim(`# ${block.id}`)]));
		for (const line of block.lines) {
			lines.push(joinParts([style.rule("│"), style.output(`  ${line}`)]));
		}
	}
	if (!expanded && backgroundWidgetExpands(jobs)) {
		const more = hidden > 0 ? ` · +${hidden} lines` : "";
		lines.push(joinParts([style.rule("│"), style.dim(`[${hint}: expand${more}]`)]));
	} else if (expanded && backgroundWidgetExpands(jobs)) {
		lines.push(joinParts([style.rule("│"), style.dim(`[${hint}: collapse]`)]));
	}
	return lines;
}

function joinParts(parts: string[]): string {
	return parts.filter((part) => part.length > 0).join(" ");
}

function readyLabel(running: number, finished: number): string | undefined {
	return running > 0 && finished > 0 ? `${finished} ready` : undefined;
}

function bandElapsed(jobs: readonly BackgroundWidgetJob[], now: number): string | undefined {
	let oldestMs: number | undefined;
	for (const job of jobs) {
		if (job.startedAt === undefined || !Number.isFinite(job.startedAt)) continue;
		const end = job.status !== "running" && job.finishedAt !== undefined ? job.finishedAt : now;
		const age = end - job.startedAt;
		if (oldestMs === undefined || age > oldestMs) oldestMs = age;
	}
	return oldestMs === undefined ? undefined : formatJobElapsed(oldestMs);
}

function jobElapsed(job: BackgroundWidgetJob, now: number): string | undefined {
	if (job.startedAt === undefined || !Number.isFinite(job.startedAt)) return undefined;
	const end = job.status !== "running" && job.finishedAt !== undefined ? job.finishedAt : now;
	return formatJobElapsed(end - job.startedAt);
}

function headerGlyph(jobs: readonly BackgroundWidgetJob[]): string {
	const status = worstStatus(jobs);
	if (status === "running") return "●";
	if (status === "completed") return "✓";
	if (status === "cancelled") return "!";
	return "✗";
}

function worstStatus(jobs: readonly BackgroundWidgetJob[]): JobStatus {
	if (jobs.some((job) => job.status === "failed" || job.status === "timed_out")) return "failed";
	if (jobs.some((job) => job.status === "cancelled")) return "cancelled";
	if (jobs.some((job) => job.status === "running")) return "running";
	return "completed";
}

function badgeLabel(status: JobStatus): string {
	if (status === "running") return "running";
	if (status === "completed") return "done";
	if (status === "cancelled") return "cancelled";
	if (status === "timed_out") return "timed out";
	return "failed";
}

function statePaint(style: WidgetStyle, state: ReturnType<typeof pillState>): (text: string) => string {
	if (state === "success") return style.success;
	if (state === "warning") return style.warning;
	if (state === "error") return style.error;
	return style.accent;
}

function displayCommand(command: string): string {
	return command.replace(/\s+/g, " ").trim();
}

function displayLines(output: string): string[] {
	// ANSI escape stripping needs the ESC and BEL control characters.
	const stripped = output
		// eslint-disable-next-line no-control-regex
		.replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/g, "")
		// eslint-disable-next-line no-control-regex
		.replace(/\u001b\][^\u0007\u001b]*(?:\u0007|\u001b\\)/g, "")
		// eslint-disable-next-line no-control-regex
		.replace(/\u001b./g, "");
	const lines: string[] = [];
	let current = "";
	for (const char of stripped) {
		if (char === "\n") {
			if (current.trim()) lines.push(current.replace(/\s+$/u, ""));
			current = "";
		} else if (char === "\r") {
			current = "";
		} else {
			current += char;
		}
	}
	if (current.trim()) lines.push(current.replace(/\s+$/u, ""));
	return lines;
}

function outputBlocks(
	jobs: readonly BackgroundWidgetJob[],
	expanded: boolean,
): Array<{ id: string; lines: string[] }> {
	const blocks: Array<{ id: string; lines: string[] }> = [];
	for (const job of jobs) {
		const lines = displayLines(job.output ?? "");
		if (lines.length === 0) continue;
		blocks.push({
			id: job.id,
			lines: expanded ? lines.slice(-EXPANDED_OUTPUT_LINES) : lines.slice(-1),
		});
	}
	return blocks;
}

function hiddenOutputCount(jobs: readonly BackgroundWidgetJob[], expanded: boolean): number {
	if (expanded) return 0;
	return jobs.reduce((sum, job) => sum + Math.max(0, displayLines(job.output ?? "").length - 1), 0);
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

	const notify = (): void => options.onChange?.();
	const scheduleOutputRefresh = (): void => {
		if (outputTimer) return;
		outputTimer = setTimeout(() => {
			outputTimer = undefined;
			notify();
		}, 400);
		outputTimer.unref?.();
	};

	const deliver = (job: RunningJob): void => {
		if (!job.pendingDelivery || job.delivered || job.suppressDelivery || job.holdDelivery || closed) return;
		job.delivered = true;
		options.onDeliver(job.pendingDelivery);
		notify();
	};

	const settle = (job: RunningJob, outcome: Outcome): void => {
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

function appendOutput(job: RunningJob, text: string, maxStoredChars: number): void {
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
		const onAbort = (): void => {
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
	const onAbort = (): void => controller.abort();
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
