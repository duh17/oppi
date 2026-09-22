/**
 * Background shell jobs.
 *
 * Bash waits 15 seconds. If the command is still running, it becomes a
 * background job, a composer pill shows it, and the output is injected as a
 * follow-up. A trailing `&` backgrounds immediately. Polling a running job is
 * blocked.
 */

import type { ExtensionAPI, ExtensionContext, ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import { createLocalBashOperations } from "@earendil-works/pi-coding-agent";
import { StringEnum } from "@earendil-works/pi-ai";
import { Type } from "@sinclair/typebox";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import {
	BACKGROUND_POLICY,
	backgroundPill,
	bashBackgroundAdvice,
	createJobManager,
	runBackgroundPolicy,
	type SessionExports,
} from "./jobs.ts";

const PILL_KEY = "background-jobs";

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
	let latestUi: ExtensionUIContext | undefined;
	const refreshPill = () => {
		const ui = latestUi;
		if (!ui) return;
		const pill = backgroundPill(manager.visibleRunning());
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
				blocks: [
					{ type: "activityList", id: "jobs", rows: pill.rows },
					...(pill.terminal.length > 0
						? [
								{
									type: "terminal",
									id: "output",
									lines: pill.terminal.map((line) => [{ text: line }]),
								},
							]
						: []),
				],
				fallback: { lines: pill.lines },
			}),
			invalidate() {},
		}));
	};
	const manager = createJobManager({
		exec: (request) => operations.exec(request.command, request.cwd, request),
		onChange: refreshPill,
		onDeliver: (delivery) => {
			if (closed) return;
			try {
				pi.sendMessage(
					{
						customType: "background-job",
						content: delivery.text,
						display: true,
						details: { jobId: delivery.jobId, status: delivery.status },
					},
					{ deliverAs: "followUp", triggerTurn: true },
				);
			} catch {
				// The session can shut down between exit and delivery.
			}
		},
	});

	const rememberUi = (ctx: ExtensionContext) => {
		latestUi = ctx.ui;
	};

	pi.registerTool({
		name: "bash",
		label: "bash",
		description: `Execute a bash command. ${BACKGROUND_POLICY.afterWait} ${BACKGROUND_POLICY.immediate} ${BACKGROUND_POLICY.stayForeground} A backgrounded command shows a job pill and injects its output as a follow-up. Do not poll for it.`,
		promptSnippet: "Execute bash commands. Commands still running after 15s become background jobs.",
		promptGuidelines: [
			BACKGROUND_POLICY.afterWait,
			BACKGROUND_POLICY.immediate,
			"A running background job shows a pill. Its output is injected as a follow-up. Never poll it with sleep, ps, pgrep, top, pidwait, or log tailing. Do other work, or end your reply and wait to be woken.",
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
			"Start or cancel a background shell job. Use start for builds, tests, servers, watchers, installs, and any command you would otherwise background or poll. Returns immediately. Output is injected as a follow-up when the job finishes. Do not poll with sleep, ps, pgrep, top, pidwait, or log tailing. Do other work, or end your reply and wait to be woken. cancel stops a job; it is not a status check.",
		promptSnippet: "Run a long shell command in the background and receive its output as a follow-up",
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
		rememberUi(ctx);
		refreshPill();
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

	pi.on("session_shutdown", () => {
		closed = true;
		manager.shutdown();
		refreshPill();
	});
}
