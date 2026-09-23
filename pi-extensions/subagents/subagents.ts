/**
 * Subagents launched by this parent.
 *
 * The set is the create results this session saw. Status updates come from
 * `oppi session wait`; a one-time `oppi session get <id>` snapshot fills in
 * model and context metadata. There is no children list API.
 */

export interface Subagent {
	id: string;
	parentId?: string;
	title: string;
	subtitle: string;
	link: string;
	state: "running" | "success" | "warning" | "error";
	model?: string;
	contextTokens?: number;
	contextWindow?: number;
}

export interface SubagentRow {
	id: string;
	title: string;
	subtitle: string;
	detail?: string;
	state: Subagent["state"];
	link: string;
	progress?: number;
}

export interface WidgetChrome {
	title: string;
	subtitle?: string;
}

const MAX_SUBAGENTS = 8;

export function sessionLink(sessionId: string, workspaceId?: string): string {
	const url = `oppi://session/${sessionId}`;
	return workspaceId ? `${url}?workspaceId=${encodeURIComponent(workspaceId)}` : url;
}

export function applyGet(known: Subagent, payload: unknown): Subagent | null {
	const data = envelopeData(payload);
	const session = asRecord(data?.session) ?? data;
	if (!session) return known;
	const id = stringField(session, "id");
	if (id && id !== known.id) return known;
	const launch = asRecord(session.launch);
	const parent = stringField(launch, "parentSessionId");
	if (parent && parent !== known.parentId) return null;
	const refreshed = subagentFromSession(session, known.id, known.parentId);
	const name = stringField(session, "name") ?? known.title;
	return {
		...known,
		...refreshed,
		title: titledWithAgent(name, asRecord(launch)?.agentIcon),
		state: mergePolledState(known.state, refreshed.state),
		model: refreshed.model ?? known.model,
		contextTokens: refreshed.contextTokens ?? known.contextTokens,
		contextWindow: refreshed.contextWindow ?? known.contextWindow,
	};
}

export function sessionIdFromCreateOutput(text: string): string | undefined {
	return subagentFromCreate("oppi session create --json", text)?.id;
}

export function childStatusFromGet(payload: unknown): {
	id?: string;
	status?: string;
	name?: string;
	lastMessage?: string;
	parentId?: string;
	workspaceId?: string;
} | null {
	const session = sessionRecord(payload);
	if (!session) return null;
	const launch = asRecord(session.launch);
	return {
		id: stringField(session, "id"),
		status: stringField(session, "status"),
		name: stringField(session, "name"),
		lastMessage: stringField(session, "lastMessage"),
		parentId: stringField(launch, "parentSessionId"),
		workspaceId: stringField(session, "workspaceId"),
	};
}

export function subagentFromCreate(command: string, text: string, parentId?: string): Subagent | null {
	if (!/\boppi\s+session\s+create\b/.test(command)) return null;
	const data = createEnvelope(text);
	const id = stringField(data, "session_id") ?? stringField(data, "sessionId");
	if (!id || id === parentId) return null;
	const name = flag(command, "name") ?? shortId(id);
	const model = flag(command, "model");
	return {
		id,
		parentId,
		title: name,
		subtitle: shortId(id),
		link: sessionLink(id),
		state: "running",
		...(model ? { model } : {}),
	};
}

export function refreshLaunched(launched: Subagent[], gets: unknown[]): Subagent[] {
	const byId = new Map(launched.map((item) => [item.id, item]));
	for (const payload of gets) {
		for (const [id, known] of byId) {
			const session = sessionRecord(payload);
			if (stringField(session, "id") !== id) continue;
			const next = applyGet(known, payload);
			if (next) byId.set(id, next);
			else byId.delete(id);
		}
	}
	return [...byId.values()].slice(0, MAX_SUBAGENTS);
}

export function withStatuses(rows: Subagent[], updates: Array<{ id: string; status?: string }>): Subagent[] {
	const byId = new Map(updates.map((item) => [item.id, item.status]));
	return rows.map((row) => {
		const status = byId.get(row.id);
		if (!status) return row;
		return { ...row, state: stateFromStatus(status) };
	});
}

export function applyWaitReading(
	rows: Subagent[],
	reading: {
		settled: Array<{ id: string; status?: string }>;
		attention: Array<{ id: string }>;
		running: Array<{ id: string }>;
	},
): Subagent[] {
	const byId = new Map<string, Subagent["state"]>();
	for (const record of reading.running) byId.set(record.id, stateFromStatus(record.status));
	for (const record of reading.settled) byId.set(record.id, stateFromStatus(record.status));
	for (const record of reading.attention) byId.set(record.id, "warning");
	return rows.map((row) => {
		const state = byId.get(row.id);
		return state ? { ...row, state } : row;
	});
}

export function statusLabel(state: Subagent["state"]): string {
	switch (state) {
		case "running":
			return "Working";
		case "success":
			return "Done";
		case "warning":
			return "Needs attention";
		case "error":
			return "Error";
	}
}

export function rowFallback(row: SubagentRow): string {
	return [row.title, row.subtitle, row.detail, row.link].filter(Boolean).join(" ");
}

export function widgetChrome(subagents: Subagent[]): WidgetChrome {
	const title = subagents.length === 1 ? "1 subagent" : `${subagents.length} subagents`;
	const subtitle = panelSummary(subagents);
	return {
		title,
		...(subtitle && subtitle !== title ? { subtitle } : {}),
	};
}

export function subagentRows(subagents: Subagent[]): SubagentRow[] {
	return subagents.map((item) => {
		const model = shortModelName(item.model);
		const usage = contextLabel(item.contextTokens, item.contextWindow);
		const progress = contextProgress(item.contextTokens, item.contextWindow);
		return {
			id: item.id,
			title: item.title,
			subtitle: [statusLabel(item.state), model].filter(Boolean).join(" · "),
			detail: usage ?? item.subtitle,
			state: item.state,
			link: item.link,
			...(progress !== undefined ? { progress } : {}),
		};
	});
}

function sessionRecord(payload: unknown): Record<string, unknown> | null {
	const data = envelopeData(payload);
	return asRecord(data?.session) ?? data;
}

function subagentFromSession(
	session: Record<string, unknown>,
	id: string,
	parentId?: string,
): Subagent {
	const workspaceId = stringField(session, "workspaceId");
	const name = stringField(session, "name") ?? shortId(id);
	const model = stringField(session, "model");
	const contextTokens = numberField(session, "contextTokens");
	const contextWindow = numberField(session, "contextWindow");
	return {
		id,
		parentId,
		title: name,
		subtitle: shortId(id),
		link: sessionLink(id, workspaceId),
		state: stateFromStatus(stringField(session, "status")),
		...(model ? { model } : {}),
		...(contextTokens !== undefined ? { contextTokens } : {}),
		...(contextWindow !== undefined ? { contextWindow } : {}),
	};
}

function panelSummary(rows: Subagent[]): string | undefined {
	if (rows.length === 0) return undefined;
	const working = rows.filter((row) => row.state === "running").length;
	const attention = rows.filter((row) => row.state === "warning").length;
	const errors = rows.filter((row) => row.state === "error").length;
	if (attention > 0) return attention === 1 ? "Needs attention" : `${attention} need attention`;
	if (working > 0) {
		if (working === rows.length && working === 1) return "Working";
		return `${working} working`;
	}
	if (errors > 0) return errors === 1 ? "Error" : `${errors} errors`;
	return rows.length === 1 ? "Done" : "All done";
}

function shortModelName(model: string | undefined): string | undefined {
	if (!model) return undefined;
	const name = model.split("/").pop() ?? model;
	return name.replace(/^claude-/, "").replace(/^gemini-/, "");
}

function contextLabel(tokens: number | undefined, window: number | undefined): string | undefined {
	if (window !== undefined && window > 0 && tokens !== undefined && tokens >= 0) {
		return `${Math.round((tokens / window) * 100)}%`;
	}
	if (tokens !== undefined && tokens > 0) return compactCount(tokens);
	return undefined;
}

function contextProgress(tokens: number | undefined, window: number | undefined): number | undefined {
	if (window === undefined || window <= 0 || tokens === undefined || tokens < 0) return undefined;
	return Math.min(1, tokens / window);
}

function compactCount(count: number): string {
	if (count >= 1_000_000) {
		const millions = count / 1_000_000;
		return `${trimDecimal(millions)}M`;
	}
	if (count >= 1_000) {
		const thousands = count / 1_000;
		return `${trimDecimal(thousands)}k`;
	}
	return String(Math.round(count));
}

function trimDecimal(value: number): string {
	const text = value < 10 && !Number.isInteger(value) ? value.toFixed(1) : value.toFixed(0);
	return text.replace(/\.0$/, "");
}

export function titledWithAgent(name: string, icon: unknown): string {
	const mark = agentEmoji(icon);
	if (!mark || name.startsWith(`${mark} `) || name === mark) return name;
	return `${mark} ${name}`;
}

function agentEmoji(icon: unknown): string | undefined {
	const record = asRecord(icon);
	if (stringField(record, "kind") !== "emoji") return undefined;
	const value = stringField(record, "value");
	if (!value || [...value].length > 4) return undefined;
	return value;
}

function stateFromStatus(status: string | undefined): Subagent["state"] {
	const token = (status ?? "").toLowerCase();
	if (token === "stopped" || token === "idle" || token === "ready" || token === "stopping") return "success";
	if (token === "error") return "error";
	if (token === "attention") return "warning";
	return "running";
}

function mergePolledState(known: Subagent["state"], polled: Subagent["state"]): Subagent["state"] {
	// Wait owns attention. Session get has no pending-dialog field, so a busy
	// poll must not paint Needs attention back to Working.
	if (known === "warning" && polled === "running") return "warning";
	return polled;
}

function envelopeData(payload: unknown): Record<string, unknown> | null {
	if (typeof payload === "string") return jsonData(payload);
	const record = asRecord(payload);
	if (!record) return null;
	if (record.ok === true) return asRecord(record.data);
	return record;
}

function createEnvelope(text: string): Record<string, unknown> | null {
	const trimmed = text.trim();
	const candidates = [trimmed];
	const line = trimmed.split("\n").find((item) => item.trim().startsWith("{"));
	if (line && line.trim() !== trimmed) candidates.push(line.trim());
	for (const candidate of candidates) {
		try {
			const data = envelopeData(JSON.parse(candidate) as unknown);
			if (stringField(data, "session_id") || stringField(data, "sessionId")) return data;
		} catch {
			// A create result is one JSON envelope, not a slice across several objects.
		}
	}
	return null;
}

function jsonData(text: string): Record<string, unknown> | null {
	try {
		return envelopeData(JSON.parse(text) as unknown);
	} catch {
		return null;
	}
}

function flag(command: string, name: string): string | undefined {
	const equals = command.match(new RegExp(`--${name}=(\\S+)`));
	if (equals?.[1]) return equals[1];
	const spaced = command.match(new RegExp(`--${name}\\s+(\\S+)`));
	return spaced?.[1];
}

function shortId(sessionId: string): string {
	return sessionId.replace(/-/g, "").slice(0, 8);
}

function asRecord(value: unknown): Record<string, unknown> | null {
	return value !== null && typeof value === "object" && !Array.isArray(value)
		? (value as Record<string, unknown>)
		: null;
}

function stringField(record: Record<string, unknown> | null, key: string): string | undefined {
	const value = record?.[key];
	return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function numberField(record: Record<string, unknown> | null, key: string): number | undefined {
	const value = record?.[key];
	return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}
