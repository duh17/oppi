/**
 * Reference extension: launch and list this session's Oppi subagents.
 *
 * The tool is the supervise path. A 4-minute check-in is a real parent model
 * message, so the prompt cache stays warm the way `oppi session wait` used to.
 * The widget only remembers launches from this parent and refreshes those ids.
 * Copy this package if you want the same tool and widget. A row tap uses the
 * existing session link. This package does not add a client screen.
 */

import { spawn } from "node:child_process";
import type { ExtensionAPI, ExtensionContext, ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import { StringEnum } from "@earendil-works/pi-ai";
import { Type } from "@sinclair/typebox";
import {
	applyWaitReading,
	refreshLaunched,
	rowFallback,
	sessionIdFromCreateOutput,
	sessionLink,
	subagentFromCreate,
	subagentRows,
	type Subagent,
} from "./subagents.ts";
import {
	attentionText,
	cacheTouchDelayMs,
	cacheTouchText,
	CALLER_ENV,
	isFailedWaitEnvelope,
	launchPlan,
	launchReceipt,
	parentDelivery,
	readWait,
	reduceWait,
	restoreSupervised,
	settlementText,
	shouldClearAttention,
	SUPERVISED_ENTRY,
	waitPlan,
	type StallState,
	type WatchChild,
} from "./supervise.ts";

const WIDGET_KEY = "subagents";
const CREATE_TIMEOUT_MS = 30_000;
const GET_TIMEOUT_MS = 8_000;
const MIN_WAIT_SEC = 30;

interface OppiResult {
	code: number | null;
	stdout: string;
	stderr: string;
}

function textFromContent(content: unknown): string {
	if (!Array.isArray(content)) return "";
	return content
		.map((block) => {
			if (!block || typeof block !== "object") return "";
			const text = (block as { text?: unknown }).text;
			return typeof text === "string" ? text : "";
		})
		.filter(Boolean)
		.join("\n");
}

function commandFromInput(input: Record<string, unknown> | undefined): string {
	const command = input?.command;
	return typeof command === "string" ? command : "";
}

function runOppi(
	args: string[],
	options: { stdin?: string; env?: Record<string, string>; timeoutMs?: number } = {},
): Promise<OppiResult> {
	return new Promise((resolve) => {
		const child = spawn("oppi", args, {
			env: { ...process.env, ...options.env },
			stdio: ["pipe", "pipe", "pipe"],
		});
		let stdout = "";
		let stderr = "";
		let settled = false;
		const finish = (result: OppiResult) => {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			resolve(result);
		};
		const timer = setTimeout(() => {
			child.kill();
			finish({ code: null, stdout, stderr });
		}, options.timeoutMs ?? GET_TIMEOUT_MS);
		child.stdout.on("data", (chunk: Buffer | string) => {
			stdout += chunk.toString();
		});
		child.stderr.on("data", (chunk: Buffer | string) => {
			stderr += chunk.toString();
		});
			child.on("error", () => finish({ code: null, stdout, stderr }));
		child.stdin.on("error", () => {
			child.kill();
		});
		child.on("close", (code) => finish({ code, stdout, stderr }));
		try {
			if (options.stdin !== undefined) child.stdin.write(options.stdin);
			child.stdin.end();
		} catch {
			child.kill();
		}
	});
}

export async function refreshLaunchedFromCli(launched: Subagent[]): Promise<Subagent[]> {
	const gets = await Promise.all(launched.map((item) => runOppi(["session", "get", item.id, "--json"])));
	return refreshLaunched(
		launched,
		gets.map((result) => parseJson(result.stdout)),
	);
}

function parseJson(text: string): unknown {
	try {
		return JSON.parse(text) as unknown;
	} catch {
		return null;
	}
}

export default function subagentsExtension(pi: ExtensionAPI) {
	let seen: Subagent[] = [];
	let shown: Subagent[] = [];
	let watched: WatchChild[] = [];
	let settledIds = new Set<string>();
	let latestUi: ExtensionUIContext | undefined;
	let parentId: string | undefined;
	let closed = false;
	let idle = true;
	let lastParentTouch = 0;
	let waitGeneration = 0;
	let eitherChild: ReturnType<typeof spawn> | undefined;
	let idleChild: ReturnType<typeof spawn> | undefined;
	let attentionChild: ReturnType<typeof spawn> | undefined;
	let retryTimer: ReturnType<typeof setTimeout> | undefined;
	let waitFailures = 0;
	let failureWarned = false;
	const stalls = new Map<string, StallState>();

	const refreshWidget = () => {
		const ui = latestUi;
		if (!ui) return;
		if (shown.length === 0) {
			ui.setStatus(WIDGET_KEY, undefined);
			ui.setWidget(WIDGET_KEY, undefined);
			return;
		}
		const rows = subagentRows(shown);
		const title = shown.length === 1 ? "1 subagent" : `${shown.length} subagents`;
		ui.setStatus(WIDGET_KEY, title);
		ui.setWidget(WIDGET_KEY, () => ({
			render: () => [title, ...rows.map(rowFallback)],
			renderNative: () => ({
				version: 1,
				id: `widget:${WIDGET_KEY}`,
				source: "widget",
				presentation: {
					style: "surfacePanel",
					title,
					subtitle: rows[0]?.subtitle ?? rows[0]?.title,
				},
				blocks: [{ type: "activityList", id: "subagents", rows }],
				fallback: { lines: rows.map(rowFallback) },
			}),
			invalidate() {},
		}));
	};

	const refreshFromCli = () => {
		if (seen.length === 0) {
			shown = [];
			refreshWidget();
			return;
		}
		const requested = seen;
		void refreshLaunchedFromCli(requested)
			.then((next) => {
				if (seen !== requested) return;
				shown = next;
				refreshWidget();
			})
			.catch(() => {
				shown = seen;
				refreshWidget();
			});
	};

	const rememberUi = (ctx: ExtensionContext) => {
		latestUi = ctx.ui;
		parentId = ctx.sessionManager.getSessionId();
	};

	const touchInput = () => ({
		now: Date.now(),
		lastParentTouch,
		idle,
		children: watched,
		settledIds,
	});

	const deliver = (
		customType: string,
		content: string,
		details: Record<string, unknown>,
		display = true,
	) => {
		if (closed) return false;
		try {
			pi.sendMessage(
				{ customType, content, display, details },
				{ deliverAs: "followUp", triggerTurn: true },
			);
			lastParentTouch = Date.now();
			return true;
		} catch {
			return false;
		}
	};

	const stopWait = () => {
		waitGeneration += 1;
		eitherChild?.kill();
		idleChild?.kill();
		attentionChild?.kill();
		eitherChild = undefined;
		idleChild = undefined;
		attentionChild = undefined;
		if (retryTimer) clearTimeout(retryTimer);
		retryTimer = undefined;
	};

	const forgetWatched = (id: string) => {
		try {
			pi.appendEntry(SUPERVISED_ENTRY, { id, supervise: true, released: true });
		} catch {
			// A failed persist only risks one extra wake after reload.
		}
	};

	const waitSeconds = () => {
		const delay = cacheTouchDelayMs(touchInput());
		const ms = delay === undefined ? 4 * 60 * 1000 : delay;
		return Math.max(MIN_WAIT_SEC, Math.ceil(ms / 1000));
	};

	const scheduleRetry = (generation: number) => {
		if (retryTimer || generation !== waitGeneration) return;
		waitFailures += 1;
		if (waitFailures >= 3) {
			if (!failureWarned) {
				failureWarned = true;
				deliverKind(
					"failure",
					"Subagent wait failed. Supervision is paused. The children are still running; open them from the widget. Do not poll.",
					{ failures: waitFailures },
				);
			}
			return;
		}
		retryTimer = setTimeout(() => {
			retryTimer = undefined;
			if (generation === waitGeneration && !closed) armWait();
		}, 5_000 * waitFailures);
	};

	const spawnWait = (
		ids: string[],
		condition: "either" | "idle" | "attention",
		timeoutSec: number,
		generation: number,
		onClose: (stdout: string, code: number | null) => void,
	) => {
		const child = spawn("oppi", [
			"session", "wait", ...ids,
			"--for", condition,
			"--json",
			"--summary-every", "0",
			"--timeout", String(timeoutSec),
		], {
			env: { ...process.env, ...(parentId ? { [CALLER_ENV]: parentId } : {}) },
			stdio: ["ignore", "pipe", "ignore"],
		});
		let stdout = "";
		child.stdout?.on("data", (chunk: Buffer | string) => {
			stdout += chunk.toString();
		});
		child.on("error", () => {
			if (generation !== waitGeneration || closed) return;
			onClose("", null);
		});
		child.on("close", (code) => {
			if (generation !== waitGeneration || closed) return;
			onClose(stdout, code);
		});
		return child;
	};

	const armWait = () => {
		stopWait();
		const plan = waitPlan(watched, settledIds);
		if (closed || (plan.eitherIds.length === 0 && plan.idleIds.length === 0)) return;
		const generation = waitGeneration;
		const timeoutSec = waitSeconds();
		if (plan.eitherIds.length > 0) {
			eitherChild = spawnWait(plan.eitherIds, "either", timeoutSec, generation, (stdout, code) => {
				eitherChild = undefined;
				finishWait(stdout, code, generation);
			});
		}
		if (plan.idleIds.length > 0) {
			idleChild = spawnWait(plan.idleIds, "idle", timeoutSec, generation, (stdout, code) => {
				idleChild = undefined;
				finishWait(stdout, code, generation);
			});
		}
	};

	const finishWait = (stdout: string, code: number | null, generation: number) => {
		if (generation !== waitGeneration || closed) return;
		const payload = parseJson(stdout);
		if (!stdout.trim() || isFailedWaitEnvelope(payload, code)) {
			scheduleRetry(generation);
			return;
		}
		waitFailures = 0;
		failureWarned = false;
		const reading = readWait(payload ?? stdout);
		handleWait(reading);
		armWait();
		if (reading.timedOut) startAttentionCheck(waitGeneration);
	};

	const rememberWatch = (child: WatchChild) => {
		watched = [child, ...watched.filter((item) => item.id !== child.id)];
		settledIds.delete(child.id);
		armWait();
	};

	const rememberRow = (id: string, name: string) => {
		const created = subagentFromCreate(
			`oppi session create --name ${name} --json`,
			JSON.stringify({ ok: true, data: { session_id: id } }),
			parentId,
		);
		if (!created) return;
		seen = refreshLaunched([created, ...seen.filter((item) => item.id !== created.id)], []);
		shown = seen;
		refreshWidget();
		refreshFromCli();
	};

	const deliverKind = (
		kind: "settled" | "attention" | "stalled" | "touch" | "failure",
		content: string,
		details: Record<string, unknown>,
	) => {
		const delivery = parentDelivery(kind);
		return deliver(delivery.customType, content, details, delivery.display);
	};

	const handleWait = (reading: ReturnType<typeof readWait>) => {
		const effect = reduceWait({
			children: watched,
			settledIds,
			reading,
			now: Date.now(),
			lastParentTouch,
			idle,
			stalls,
		});
		for (const [id, state] of effect.stalls) stalls.set(id, state);
		for (const id of effect.attention) {
			const child = watched.find((item) => item.id === id);
			if (child) child.attentionDelivered = true;
		}
		for (const id of effect.stall) {
			const child = watched.find((item) => item.id === id);
			if (child) child.attentionDelivered = true;
		}
		for (const id of effect.clearAttention) {
			const child = watched.find((item) => item.id === id);
			if (child && shouldClearAttention(reading.running.find((item) => item.id === id)?.pendingDialogs)) {
				child.attentionDelivered = false;
			}
		}
		for (const id of effect.widgetAttention) {
			const child = watched.find((item) => item.id === id);
			if (child) child.attentionDelivered = true;
		}
		for (const id of effect.widgetSettle) settledIds.add(id);
		shown = applyWaitReading(shown, reading);
		seen = shown;
		refreshWidget();
		if (effect.settle.length > 0) {
			const sent = deliverKind("settled", settlementText(effect.settle.map((item) => ({
				name: watched.find((child) => child.id === item.id)?.name ?? item.id.slice(0, 8),
				id: item.id,
				status: item.status,
				link: sessionLink(item.id),
				lastMessage: item.last,
			}))), { ids: effect.settle.map((item) => item.id) });
			if (sent) {
				for (const item of effect.settle) {
					settledIds.add(item.id);
					forgetWatched(item.id);
				}
			}
			return;
		}
		if (effect.attention.length > 0) {
			deliverKind(
				"attention",
				effect.attention.map((id) => attentionText({
					name: watched.find((child) => child.id === id)?.name ?? id.slice(0, 8),
					link: sessionLink(id),
				})).join("\n"),
				{ ids: effect.attention },
			);
			return;
		}
		if (effect.stall.length > 0) {
			deliverKind(
				"stalled",
				`Subagent stalled: ${effect.stall.map((id) => `${watched.find((child) => child.id === id)?.name ?? id} ${sessionLink(id)}`).join(", ")}. Check-ins pause until it changes. Do not relaunch.`,
				{ ids: effect.stall },
			);
			return;
		}
		if (effect.touch) {
			const running = watched.filter((child) => child.supervise && !settledIds.has(child.id) && !child.attentionDelivered);
			if (running.length > 0) deliverKind("touch", cacheTouchText(running), { ids: running.map((item) => item.id) });
		}
	};

	const startAttentionCheck = (generation: number) => {
		const ids = waitPlan(watched, settledIds).idleIds;
		if (ids.length === 0 || attentionChild || generation !== waitGeneration) return;
		attentionChild = spawnWait(ids, "attention", 5, generation, (stdout, code) => {
			attentionChild = undefined;
			if (generation !== waitGeneration || closed) return;
			const payload = parseJson(stdout);
			if (!stdout.trim() || isFailedWaitEnvelope(payload, code)) return;
			const reading = readWait(payload ?? stdout);
			const before = ids.length;
			handleWait(reading);
			const after = waitPlan(watched, settledIds).idleIds.length;
			if (after < before) armWait();
		});
	};

	pi.registerTool({
		name: "subagent",
		label: "subagent",
		description:
			"Launch an Oppi subagent and, by default, supervise it. Supervision returns immediately. The result arrives as a follow-up and starts a parent turn. While a supervised child is still running and this session is idle, one short check-in about every 4 minutes starts a parent model turn so the prompt cache stays warm. Do not poll with session wait, session get, session inspect, or session list. Inspect a settled child only when the follow-up reply is not enough. Pass supervise false for a detached hand-off; that path does not check in.",
		promptSnippet: "Launch and supervise an Oppi subagent without leaving this session's prompt cache cold.",
		promptGuidelines: [
			"Use subagent launch instead of bash oppi session create and oppi session wait for Oppi children.",
			"supervise defaults to true. The result arrives as a follow-up and starts a parent turn. A check-in about every 4 minutes keeps this session's prompt cache warm. Reply to a check-in with one short line and no tool calls. Do not poll. Inspect a settled child only when the follow-up reply is not enough.",
			"Pass supervise false for a detached hand-off. That path does not check in and must not be waited on.",
			"Pass model, thinking, and agent explicitly. auto_stop true for supervised crew. allow_nested only for a detached Donkey Master.",
			"release stops supervision only. It does not stop the child session.",
		],
		executionMode: "parallel",
		parameters: Type.Object({
			action: StringEnum(["launch", "release"] as const, {
				description: "launch creates a child. release stops supervision and does not stop the session.",
			}),
			workspace: Type.Optional(Type.String({ description: "Workspace id or unique name. Required for launch." })),
			prompt: Type.Optional(Type.String({ description: "Child prompt. Required for launch." })),
			name: Type.Optional(Type.String({ description: "Session name." })),
			model: Type.Optional(Type.String({ description: "Exact provider/model id." })),
			thinking: Type.Optional(Type.String({ description: "Thinking level." })),
			agent: Type.Optional(Type.String({ description: "Saved agent id, or workspace_default." })),
			worktree: Type.Optional(Type.String({ description: "Worktree id when the work may land." })),
			tools: Type.Optional(Type.String({ description: "Comma-separated tool allowlist." })),
			exclude_tools: Type.Optional(Type.String({ description: "Comma-separated tool denylist." })),
			auto_stop: Type.Optional(Type.Boolean({ description: "Stop the child when it settles. True for supervised crew." })),
			allow_nested: Type.Optional(Type.Boolean({ description: "Let this child spawn sessions. Detached Donkey Master only." })),
			idempotency_key: Type.Optional(Type.String({ description: "Stable key for one logical launch." })),
			supervise: Type.Optional(Type.Boolean({ description: "Keep the parent cache warm and deliver the result. Default true." })),
			session_id: Type.Optional(Type.String({ description: "Child id to release." })),
		}),
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			rememberUi(ctx);
			if (params.action === "release") {
				const id = params.session_id?.trim();
				if (!id) return { content: [{ type: "text", text: "session_id is required to release." }], isError: true };
				watched = watched.filter((item) => item.id !== id);
				settledIds.add(id);
				try {
					pi.appendEntry(SUPERVISED_ENTRY, { id, name: id, supervise: true, released: true });
				} catch {
					// Persistence is recovery, not the live watch set.
				}
				const remaining = waitPlan(watched, settledIds);
				if (remaining.eitherIds.length === 0 && remaining.idleIds.length === 0) stopWait();
				else armWait();
				return { content: [{ type: "text", text: `Stopped supervising ${id}. The session keeps running. No further check-ins.` }] };
			}
			if (!parentId) {
				return {
					content: [{ type: "text", text: "Parent session id is missing, so the child would not be attributed." }],
					isError: true,
				};
			}
			if (!params.workspace?.trim() || !params.prompt?.trim()) {
				return { content: [{ type: "text", text: "workspace and prompt are required to launch." }], isError: true };
			}
			const plan = launchPlan({
				workspace: params.workspace,
				prompt: params.prompt,
				name: params.name,
				model: params.model,
				thinking: params.thinking,
				agent: params.agent,
				worktree: params.worktree,
				tools: params.tools,
				excludeTools: params.exclude_tools,
				autoStop: params.auto_stop,
				allowNested: params.allow_nested,
				idempotencyKey: params.idempotency_key,
				supervise: params.supervise,
				parentId,
			});
			const result = await runOppi(plan.args, {
				stdin: plan.stdin,
				env: plan.env,
				timeoutMs: CREATE_TIMEOUT_MS,
			});
			const id = sessionIdFromCreateOutput(result.stdout);
			if (!id) {
				const detail = result.stderr.trim() || result.stdout.trim() || "no session id";
				return {
					content: [{
						type: "text",
						text: `Subagent launch failed: ${detail.slice(0, 800)}. A timeout is not proof the child was not created. Retry the same idempotency key only after checking session state.`,
					}],
					isError: true,
				};
			}
			const name = params.name?.trim() || id.slice(0, 8);
			rememberRow(id, name);
			rememberWatch({ id, name, supervise: plan.supervise, attentionDelivered: false });
			if (plan.supervise) {
				try {
					pi.appendEntry(SUPERVISED_ENTRY, { id, name, supervise: true });
				} catch {
					// The in-memory watch still covers this process.
				}
			}
			const link = sessionLink(id);
			return {
				content: [{ type: "text", text: launchReceipt({ name, id, supervise: plan.supervise, link }) }],
				details: { sessionId: id, supervise: plan.supervise, callerEnv: CALLER_ENV },
			};
		},
	});

	pi.on("session_start", (_event, ctx) => {
		closed = false;
		idle = true;
		lastParentTouch = Date.now();
		seen = [];
		shown = [];
		settledIds = new Set();
		rememberUi(ctx);
		watched = restoreSupervised(ctx.sessionManager.getEntries());
		for (const child of watched) rememberRow(child.id, child.name);
		refreshFromCli();
		armWait();
	});

	pi.on("session_shutdown", () => {
		closed = true;
		stopWait();
	});

	pi.on("agent_start", () => {
		idle = false;
		lastParentTouch = Date.now();
	});

	pi.on("agent_settled", () => {
		idle = true;
		lastParentTouch = Date.now();
	});

	pi.on("tool_result", (event, ctx) => {
		if (event.toolName !== "bash" && event.toolName !== "background_job") return;
		rememberUi(ctx);
		const command = commandFromInput(event.input);
		if (!/\boppi\s+session\s+(?:create|wait|inspect)\b/.test(command)) return;
		const created = subagentFromCreate(command, textFromContent(event.content), parentId);
		if (created) {
			seen = refreshLaunched([created, ...seen.filter((item) => item.id !== created.id)], []);
			if (!watched.some((item) => item.id === created.id && item.supervise)) {
				rememberWatch({ id: created.id, name: created.title, supervise: false, attentionDelivered: false });
			}
		}
		shown = seen;
		refreshWidget();
		refreshFromCli();
	});
}
