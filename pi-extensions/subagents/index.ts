/**
 * Reference extension: subagents of this Oppi session.
 *
 * Copy this package if you want the same widget. It shells out to `oppi`
 * and does not add a client screen. A row tap uses the existing session link.
 */

import { spawn } from "node:child_process";
import type { ExtensionAPI, ExtensionContext, ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import { refreshLaunched, subagentFromCreate, subagentRows, type Subagent } from "./subagents.ts";

const WIDGET_KEY = "subagents";

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

function runOppi(args: string[]): Promise<unknown | null> {
	return new Promise((resolve) => {
		const child = spawn("oppi", args, { env: process.env });
		let stdout = "";
		const timer = setTimeout(() => {
			child.kill();
			resolve(null);
		}, 8000);
		child.stdout.on("data", (chunk: Buffer | string) => {
			stdout += chunk.toString();
		});
		child.on("error", () => {
			clearTimeout(timer);
			resolve(null);
		});
		child.on("close", (code) => {
			clearTimeout(timer);
			if (code !== 0 || !stdout.trim()) {
				resolve(null);
				return;
			}
			try {
				resolve(JSON.parse(stdout) as unknown);
			} catch {
				resolve(null);
			}
		});
	});
}

export async function refreshLaunchedFromCli(launched: Subagent[]): Promise<Subagent[]> {
	const gets = await Promise.all(launched.map((item) => runOppi(["session", "get", item.id, "--json"])));
	return refreshLaunched(launched, gets);
}

export default function subagentsExtension(pi: ExtensionAPI) {
	let seen: Subagent[] = [];
	let shown: Subagent[] = [];
	let latestUi: ExtensionUIContext | undefined;
	let parentId: string | undefined;

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
			render: () => [title, ...rows.map((row) => `${row.title} ${row.link}`)],
			renderNative: () => ({
				version: 1,
				id: `widget:${WIDGET_KEY}`,
				source: "widget",
				presentation: {
					style: "surfacePanel",
					title,
					subtitle: rows[0]?.title,
				},
				blocks: [{ type: "activityList", id: "subagents", rows }],
				fallback: { lines: rows.map((row) => `${row.title} ${row.link}`) },
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

	pi.on("session_start", (_event, ctx) => {
		seen = [];
		shown = [];
		rememberUi(ctx);
		refreshFromCli();
	});

	pi.on("tool_result", (event, ctx) => {
		if (event.toolName !== "bash" && event.toolName !== "background_job") return;
		rememberUi(ctx);
		const command = commandFromInput(event.input);
		if (!/\boppi\s+session\s+(?:create|wait|inspect)\b/.test(command)) return;
		const created = subagentFromCreate(command, textFromContent(event.content), parentId);
		if (created) seen = refreshLaunched([created, ...seen.filter((item) => item.id !== created.id)], []);
		shown = seen;
		refreshWidget();
		refreshFromCli();
	});
}
