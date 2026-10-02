/**
 * Background shell jobs.
 *
 * Bash waits 15 seconds. If the command is still running, it becomes a
 * background job and the composer pill shows it. Finished results are batched
 * at a safe model boundary, or sent once when the session is idle. In an Oppi
 * auto-stop session (or when that cannot be confirmed), a final turn stays
 * busy while jobs run; Stop and queued input interrupt that wait. A trailing
 * `&` backgrounds immediately. Polling a running job is blocked.
 */

import type {
	AgentBeforeSettleEvent,
	ExtensionAPI,
	ExtensionContext,
	ExtensionUIContext,
	SessionShutdownEvent,
	TurnEndEvent,
} from "@earendil-works/pi-coding-agent";
import { createLocalBashOperations } from "@earendil-works/pi-coding-agent";
import { StringEnum } from "@earendil-works/pi-ai";
import { Type } from "@sinclair/typebox";
import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import {
	boundaryDelivery,
	consumeSettleSuppression,
	createResultBuffer,
	nextIdleFlushDelay,
	shutdownDelivery,
} from "./delivery.ts";
import {
	BACKGROUND_POLICY,
	backgroundPill,
	bashBackgroundAdvice,
	createJobManager,
	runBackgroundPolicy,
	type SessionExports,
} from "./jobs.ts";

const PILL_KEY = "background-jobs";
const AUTO_STOP_LOOKUP_TIMEOUT_MS = 5_000;

/**
 * Ask Oppi once whether this session auto-stops. Pi's session id is Oppi's
 * session id. Resolves undefined when that cannot be confirmed: plain Pi, no
 * `oppi` CLI, an unknown session, or any error.
 */
function lookupOppiAutoStop(sessionId: string): Promise<boolean | undefined> {
	return new Promise((resolve) => {
		execFile(
			"oppi",
			["session", "get", sessionId, "--json"],
			{ timeout: AUTO_STOP_LOOKUP_TIMEOUT_MS, maxBuffer: 4 * 1024 * 1024 },
			(error, stdout) => {
				if (error) return resolve(undefined);
				try {
					const parsed = JSON.parse(String(stdout)) as {
						ok?: unknown;
						data?: { session?: { launch?: { autoStop?: unknown } } };
					};
					const session = parsed.ok === true ? parsed.data?.session : undefined;
					resolve(session ? session.launch?.autoStop === true : undefined);
				} catch {
					resolve(undefined);
				}
			},
		);
	});
}

const ActionSchema = StringEnum(["start", "cancel"] as const, {
	description: "start runs a command in the background. cancel stops a job. Neither is a status poll.",
});

interface ShellSettings {
	shellPath?: string;
	shellCommandPrefix?: string;
}

function readShellSettings(): ShellSettings {
	try {
		const raw = readFileSync(join(homedir(), ".pi", "agent", "settings.json"), "utf8");
		const parsed = JSON.parse(raw) as { shellPath?: unknown; shellCommandPrefix?: unknown };
		return {
			shellPath: typeof parsed.shellPath === "string" ? parsed.shellPath : undefined,
			shellCommandPrefix:
				typeof parsed.shellCommandPrefix === "string" ? parsed.shellCommandPrefix : undefined,
		};
	} catch {
		return {};
	}
}

function sessionExports(ctx: ExtensionContext): SessionExports {
	const model = ctx.model;
	return {
		sessionId: ctx.sessionManager.getSessionId(),
		sessionFile: ctx.sessionManager.getSessionFile(),
		provider: model?.provider,
		model: model?.id,
		reasoning: ctx.thinkingLevel,
	};
}

export default function backgroundJobsExtension(pi: ExtensionAPI) {
	const shell = readShellSettings();
	const operations = createLocalBashOperations({ shellPath: shell.shellPath });
	let closed = false;
	let idle = true;
	let suppressIdleWake = false;
	let generation = 0;
	let flushTimer: ReturnType<typeof setTimeout> | undefined;
	let flushStartedAt: number | undefined;
	let latestUi: ExtensionUIContext | undefined;
	let wakeTurnWait: (() => void) | undefined;
	// Holding the final turn exists only so Oppi auto-stop cannot end the session
	// before job results arrive. Pi cannot tell this wait about custom messages
	// other extensions queue (hasPendingMessages counts user input only), so a
	// hold starves them. Hold unless Oppi confirms the session will not
	// auto-stop; its idle timeout ignores open runs, so holding there protects
	// nothing. Asked lazily, at most once per session, only when a hold would start.
	let autoStopLookup: Promise<boolean | undefined> | undefined;
	const buffer = createResultBuffer();
	const cancelFlush = () => {
		if (flushTimer) clearTimeout(flushTimer);
		flushTimer = undefined;
		flushStartedAt = undefined;
	};
	const refreshPill = () => {
		const ui = latestUi;
		if (!ui) return;
		const pending = new Set(buffer.pendingIds());
		const visible = manager
			.list()
			.filter((job) => job.backgrounded && (job.status === "running" || pending.has(job.id)));
		const pill = backgroundPill(visible);
		if (!pill) {
			ui.setStatus(PILL_KEY, undefined);
			ui.setWidget(PILL_KEY, undefined);
			return;
		}
		ui.setStatus(PILL_KEY, pill.status);
		ui.setWidget(PILL_KEY, () => ({
			render: () => pill.lines,
			renderNative: () => ({
				version: 1,
				id: `widget:${PILL_KEY}`,
				source: "widget",
				presentation: {
					style: "surfacePanel",
					title: pill.title,
					subtitle: pill.subtitle,
				},
				// Each row discloses its own output tail; Oppi resolves it like bash output.
				blocks: [{ type: "activityList", id: "jobs", rows: pill.rows }],
				fallback: { lines: pill.summary },
			}),
			invalidate() {},
		}));
	};
	const sendBatch = (content: string, details: Record<string, unknown>) => {
		pi.sendMessage(
			{
				customType: "background-job",
				content,
				display: true,
				details,
			},
			{ deliverAs: "followUp", triggerTurn: true },
		);
	};
	const scheduleIdleFlush = () => {
		if (closed || suppressIdleWake || buffer.pendingCount() === 0) return;
		const scheduled = generation;
		const next = nextIdleFlushDelay(Date.now(), flushStartedAt);
		flushStartedAt = next.startedAt;
		if (flushTimer) clearTimeout(flushTimer);
		flushTimer = setTimeout(() => {
			flushTimer = undefined;
			flushStartedAt = undefined;
			if (closed || suppressIdleWake || scheduled !== generation || !idle) return;
			const taken = buffer.take();
			if (!taken) return;
			try {
				sendBatch(taken.batch.content, {
					jobIds: taken.batch.jobIds,
					statuses: taken.batch.statuses,
					omitted: taken.batch.omitted,
				});
			} catch {
				taken.undo();
			}
			refreshPill();
			if (buffer.pendingCount() > 0) scheduleIdleFlush();
		}, next.delay);
		flushTimer.unref?.();
	};
	const drainBoundary = (event: TurnEndEvent | AgentBeforeSettleEvent) => {
		if (event.outcome !== "completed") {
			suppressIdleWake = true;
			cancelFlush();
			return undefined;
		}
		const decision = boundaryDelivery({
			pending: buffer.pendingCount(),
			outcome: event.outcome,
			alreadyContinuing: event.continue,
		});
		if (!decision.append) return undefined;
		const taken = buffer.take();
		if (!taken) return undefined;
		refreshPill();
		return {
			entries: [
				...event.entries,
				{
					type: "custom_message" as const,
					customType: "background-job",
					content: taken.batch.content,
					display: true,
					details: {
						jobIds: taken.batch.jobIds,
						statuses: taken.batch.statuses,
						omitted: taken.batch.omitted,
					},
				},
			],
			...(decision.continue ? { continue: true } : {}),
		};
	};
	const manager = createJobManager({
		exec: (request) => operations.exec(request.command, request.cwd, request),
		onChange: refreshPill,
		onDeliver: (delivery) => {
			if (closed) return;
			buffer.enqueue({ jobId: delivery.jobId, status: delivery.status, text: delivery.text });
			wakeTurnWait?.();
			refreshPill();
			if (idle && !suppressIdleWake) scheduleIdleFlush();
		},
	});

	const rememberUi = (ctx: ExtensionContext) => {
		latestUi = ctx.ui;
	};

	pi.registerTool({
		name: "bash",
		label: "bash",
		description: `Execute a bash command. ${BACKGROUND_POLICY.afterWait} ${BACKGROUND_POLICY.immediate} ${BACKGROUND_POLICY.stayForeground} A backgrounded command shows a job pill. Finished output is delivered in one batch, not one reply per job. Do not poll for it.`,
		promptSnippet: "Execute bash commands. Commands still running after 15s become background jobs.",
		promptGuidelines: [
			BACKGROUND_POLICY.afterWait,
			BACKGROUND_POLICY.immediate,
			"A running background job shows a pill. Finished results arrive together at the next safe boundary, or once if this session is idle. Do not reply only to acknowledge them. Never poll with sleep, ps, pgrep, top, pidwait, or log tailing.",
			"Do not use bash or background_job for commands that read or print secrets. Use secret_run.",
		],
		executionMode: "parallel",
		parameters: Type.Object({
			command: Type.String({ description: "Bash command to execute" }),
			timeout: Type.Optional(
				Type.Number({
					description: "Timeout in seconds. Optional. A timeout of 1 second or less stays in the foreground.",
				}),
			),
		}),
		async execute(_toolCallId, params, signal, _onUpdate, ctx) {
			rememberUi(ctx);
			const result = await runBackgroundPolicy({
				manager,
				exec: (request) => operations.exec(request.command, request.cwd, request),
				command: params.command,
				cwd: ctx.cwd,
				timeout: params.timeout,
				signal,
				prefix: shell.shellCommandPrefix,
				session: sessionExports(ctx),
			});
			refreshPill();
			return {
				content: [{ type: "text", text: result.text }],
				details: { jobId: result.jobId, backgrounded: result.backgrounded },
				isError: result.isError,
			};
		},
	});

	pi.registerTool({
		name: "background_job",
		label: "background job",
		description:
			"Start or cancel a background shell job. Use start for builds, tests, servers, watchers, installs, and any command you would otherwise background or poll. Returns immediately. Output is delivered in one batch when it is safe to read, not once per job. Do not poll with sleep, ps, pgrep, top, pidwait, or log tailing. Do other work, or end your reply and wait to be woken. cancel stops a job; it is not a status check.",
		promptSnippet: "Run a long shell command in the background and receive its output in a batched follow-up",
		promptGuidelines: [
			"background_job start backgrounds immediately. Ordinary bash already backgrounds itself after 15 seconds, or immediately when the command ends in &.",
			"Use background_job cancel only to stop a job. Do not call it to check whether a job finished.",
		],
		executionMode: "parallel",
		parameters: Type.Object({
			action: ActionSchema,
			command: Type.Optional(
				Type.String({
					description: "Shell command to run in the background. Required for start.",
				}),
			),
			timeout: Type.Optional(
				Type.Number({
					description:
						"Kill the job after this many seconds. Optional. You are still woken when it ends; this does not make polling useful.",
				}),
			),
			job_id: Type.Optional(
				Type.String({
					description: "Job id returned by start. Required for cancel.",
				}),
			),
		}),
		async execute(_toolCallId, params, signal, _onUpdate, ctx) {
			if (signal?.aborted) {
				return {
					content: [{ type: "text", text: "Command aborted" }],
					details: { aborted: true },
					isError: true,
				};
			}
			rememberUi(ctx);
		if (params.action === "cancel") {
				if (!params.job_id) {
					return {
						content: [{ type: "text", text: "cancel requires job_id." }],
						details: { error: "missing job_id" },
						isError: true,
					};
				}
				const cancelled = manager.cancel(params.job_id);
				return {
					content: [{ type: "text", text: cancelled.ok ? cancelled.text : cancelled.error }],
					details: { jobId: params.job_id, cancelled: cancelled.ok },
					isError: !cancelled.ok,
				};
			}
			if (!params.command?.trim()) {
				return {
					content: [{ type: "text", text: "start requires command." }],
					details: { error: "missing command" },
					isError: true,
				};
			}
			const started = manager.start({
				command: params.command,
				cwd: ctx.cwd,
				timeout: params.timeout,
				prefix: shell.shellCommandPrefix,
				session: sessionExports(ctx),
			});
			if ("error" in started) {
				return {
					content: [{ type: "text", text: started.error }],
					details: { error: started.error },
					isError: true,
				};
			}
			return {
				content: [{ type: "text", text: `${started.notice}\n\ncommand: ${params.command.trim()}` }],
				details: { jobId: started.jobId, status: "running" },
			};
		},
	});

	pi.on("session_start", (_event, ctx) => {
		generation += 1;
		autoStopLookup = undefined;
		cancelFlush();
		buffer.clear();
		closed = false;
		idle = true;
		suppressIdleWake = false;
		rememberUi(ctx);
		refreshPill();
	});

	pi.on("agent_start", () => {
		idle = false;
		suppressIdleWake = false;
		cancelFlush();
	});

	pi.on("turn_end", async (event, ctx) => {
		const signal = ctx.signal;
		// Wait only when the model would otherwise finish. Tool results, buffered
		// job results, and already-queued continuations must keep moving normally.
		// turn_end still has Pi's live abort signal; agent_before_settle does not.
		const wouldFinishWithJobsRunning = () =>
			!closed && !signal?.aborted && event.outcome === "completed" &&
			!event.continue && !event.context.canContinue && !ctx.hasPendingMessages() &&
			buffer.pendingCount() === 0 && manager.visibleRunning().length > 0;
		if (signal && wouldFinishWithJobsRunning()) {
			autoStopLookup ??= lookupOppiAutoStop(ctx.sessionManager.getSessionId());
			const autoStop = await autoStopLookup;
			// A result, Stop, or input can arrive during the one-time lookup.
			if (autoStop !== false && wouldFinishWithJobsRunning()) {
				await new Promise<void>((resolve) => {
					const finish = () => {
						clearInterval(inputCheck);
						signal.removeEventListener("abort", finish);
						wakeTurnWait = undefined;
						resolve();
					};
					// Pi exposes no queue-change event to extensions. Check only its
					// in-memory input queue, never shell/process state or the provider.
					const inputCheck = setInterval(() => {
						if (ctx.hasPendingMessages()) finish();
					}, 100);
					wakeTurnWait = finish;
					signal.addEventListener("abort", finish, { once: true });
				});
			}
		}
		if (closed) return undefined;
		// A result and Stop can arrive together. Retain the result without
		// asking for another model request after the user has stopped the run.
		return drainBoundary(signal?.aborted ? { ...event, outcome: "aborted" } : event);
	});
	pi.on("agent_before_settle", (event) => drainBoundary(event));

	pi.on("agent_settled", () => {
		idle = true;
		const settled = consumeSettleSuppression(suppressIdleWake);
		suppressIdleWake = settled.suppressIdleWake;
		if (settled.flush) scheduleIdleFlush();
	});

	pi.on("tool_call", (event) => {
		if (event.toolName !== "bash" || typeof event.input.command !== "string") return;
		const reason = bashBackgroundAdvice(event.input.command, manager.hasRunning());
		if (!reason) return;
		return { block: true, reason };
	});

	pi.registerCommand("jobs", {
		description: "List background shell jobs",
		handler: async (_args, ctx) => {
			const jobs = manager.list();
			const policy = `Policy: bash waits ${BACKGROUND_POLICY.foregroundWaitMs / 1000}s, then backgrounds. A trailing & backgrounds immediately.`;
			const text =
				jobs.length === 0
					? `${policy}\nNo background jobs.`
					: [policy, ...jobs.map((job) => `${job.id} ${job.status} ${job.command}`)].join("\n");
			ctx.ui.notify(text, "info");
		},
	});

	pi.on("session_shutdown", (_event: SessionShutdownEvent) => {
		generation += 1;
		closed = true;
		wakeTurnWait?.();
		cancelFlush();
		const mode = shutdownDelivery({ runActive: !idle });
		while (buffer.pendingCount() > 0) {
			const taken = buffer.take();
			if (!taken) break;
			const details = {
				jobIds: taken.batch.jobIds,
				statuses: taken.batch.statuses,
				omitted: taken.batch.omitted,
			};
			const append = () => {
				pi.sendMessage(
					{
						customType: "background-job",
						content: taken.batch.content,
						display: true,
						details,
					},
					{ triggerTurn: false },
				);
			};
			try {
				if (mode === "followUp") sendBatch(taken.batch.content, details);
				else append();
			} catch {
				try {
					append();
				} catch {
					// The outgoing session is already going away.
				}
			}
		}
		buffer.clear();
		manager.shutdown();
		refreshPill();
	});
}
