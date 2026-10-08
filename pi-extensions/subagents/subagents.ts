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

export interface SubagentTerminalStyle {
	accent: (text: string) => string;
	success: (text: string) => string;
	warning: (text: string) => string;
	error: (text: string) => string;
	dim: (text: string) => string;
	title: (text: string) => string;
	rule: (text: string) => string;
	bold: (text: string) => string;
}

const plainTerminalStyle: SubagentTerminalStyle = {
	accent: (text) => text,
	success: (text) => text,
	warning: (text) => text,
	error: (text) => text,
	dim: (text) => text,
	title: (text) => text,
	rule: (text) => text,
	bold: (text) => text,
};

const TERMINAL_PREFIX_WIDTH = 4;
const SHORT_MODEL_META_WIDTH = 10;
const SHORT_STATUS_SPREAD = 3;

/**
 * Terminal band for the same children the phone draws as an activity list.
 * A narrow pane keeps the state and the name, then the model, then usage.
 * The session URL stays off the line; the phone row still carries the link.
 */
export function renderSubagentTerminal(
	subagents: Subagent[],
	options: { width?: number; style?: SubagentTerminalStyle } = {},
): string[] {
	if (subagents.length === 0) return [];
	const style = options.style ?? plainTerminalStyle;
	const width = options.width;
	const specs = subagents.map(terminalSpec);
	const nameCol = terminalNameColumn(specs, width);
	const statusCol = terminalStatusColumn(specs, width, nameCol);
	return [
		paintTerminalLine(headerPieces(subagents, width), style),
		...specs.map((spec) => paintTerminalLine(rowPieces(spec, width, nameCol, statusCol), style)),
	];
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

interface TerminalSpec {
	title: string;
	status: string;
	state: Subagent["state"];
	model?: string;
	usage?: string;
}

interface TerminalPiece {
	text: string;
	role: "rule" | "glyph" | "header" | "name" | "status" | "meta";
	state?: Subagent["state"];
}

function terminalSpec(item: Subagent): TerminalSpec {
	return {
		title: item.title,
		status: statusLabel(item.state),
		state: item.state,
		model: shortModelName(item.model),
		usage: contextLabel(item.contextTokens, item.contextWindow),
	};
}

function headerState(rows: Subagent[]): Subagent["state"] {
	if (rows.some((row) => row.state === "warning")) return "warning";
	if (rows.some((row) => row.state === "running")) return "running";
	if (rows.some((row) => row.state === "error")) return "error";
	return "success";
}

function stateGlyph(state: Subagent["state"]): string {
	switch (state) {
		case "running":
			return "\u25cf";
		case "success":
			return "\u2713";
		case "warning":
			return "!";
		case "error":
			return "\u2717";
	}
}

function terminalNameColumn(specs: TerminalSpec[], width: number | undefined): number | undefined {
	const maxName = Math.max(...specs.map((spec) => columns(spec.title)));
	const maxStatus = Math.max(...specs.map((spec) => columns(spec.status)));
	if (width === undefined) return maxName;
	const cap = width - TERMINAL_PREFIX_WIDTH - 1 - maxStatus;
	if (cap < 8) return undefined;
	return Math.min(maxName, cap);
}

function terminalStatusColumn(
	specs: TerminalSpec[],
	width: number | undefined,
	nameCol: number | undefined,
): number | undefined {
	if (nameCol === undefined) return undefined;
	const widths = specs.map((spec) => columns(spec.status));
	const maxStatus = Math.max(...widths);
	if (width === undefined) return maxStatus;
	const room = width - TERMINAL_PREFIX_WIDTH - nameCol - 1 - maxStatus - 1;
	const wantsModel = specs.some((spec) => spec.model);
	const spread = maxStatus - Math.min(...widths);
	// Padding "Needs attention" to every row hides the model. Done versus Working does not.
	if (wantsModel && room < SHORT_MODEL_META_WIDTH && spread > SHORT_STATUS_SPREAD) return undefined;
	return maxStatus;
}

function headerPieces(subagents: Subagent[], width: number | undefined): TerminalPiece[] {
	const chrome = widgetChrome(subagents);
	const state = headerState(subagents);
	const glyph = stateGlyph(state);
	let title = chrome.title;
	let subtitle = chrome.subtitle;
	if (width !== undefined) {
		const prefix = `\u2502 ${glyph} `;
		const extra = subtitle ? ` \u00b7 ${subtitle}` : "";
		if (columns(prefix + title + extra) > width) {
			subtitle = undefined;
			if (columns(prefix + title) > width) {
				title = truncateColumns(title, Math.max(1, width - columns(prefix)));
			}
		}
	}
	const pieces: TerminalPiece[] = [
		{ text: "\u2502", role: "rule" },
		{ text: glyph, role: "glyph", state },
		{ text: title, role: "header", state },
	];
	if (subtitle) pieces.push({ text: `\u00b7 ${subtitle}`, role: "meta" });
	return pieces;
}

function rowPieces(
	spec: TerminalSpec,
	width: number | undefined,
	nameCol: number | undefined,
	statusCol: number | undefined,
): TerminalPiece[] {
	const fitted = fitRow(spec, width, nameCol, statusCol);
	const pieces: TerminalPiece[] = [
		{ text: "\u2502", role: "rule" },
		{ text: stateGlyph(spec.state), role: "glyph", state: spec.state },
		{ text: fitted.name, role: "name" },
	];
	if (fitted.status) pieces.push({ text: fitted.status, role: "status", state: spec.state });
	if (fitted.meta) pieces.push({ text: fitted.meta, role: "meta" });
	return pieces;
}

function fitRow(
	spec: TerminalSpec,
	width: number | undefined,
	nameCol: number | undefined,
	statusCol: number | undefined,
): { name: string; status: string; meta: string } {
	if (width === undefined) {
		return {
			name: padColumns(spec.title, nameCol ?? columns(spec.title)),
			status: padColumns(spec.status, statusCol ?? columns(spec.status)),
			meta: fitMeta(spec.model, spec.usage, Number.POSITIVE_INFINITY),
		};
	}
	if (nameCol !== undefined) {
		const name = padColumns(truncateColumns(spec.title, nameCol), nameCol);
		const status = statusCol === undefined ? spec.status : padColumns(spec.status, statusCol);
		const used = TERMINAL_PREFIX_WIDTH + columns(name) + 1 + columns(status);
		const meta = fitMeta(spec.model, spec.usage, width - used - 1);
		return { name, status: meta ? status : status.trimEnd(), meta };
	}
	const statusW = columns(spec.status);
	const nameBudget = width - TERMINAL_PREFIX_WIDTH - 1 - statusW;
	if (nameBudget >= 1) {
		const name = truncateColumns(spec.title, nameBudget);
		const used = TERMINAL_PREFIX_WIDTH + columns(name) + 1 + statusW;
		return { name, status: spec.status, meta: fitMeta(spec.model, spec.usage, width - used - 1) };
	}
	return {
		name: truncateColumns(spec.title, Math.max(1, width - TERMINAL_PREFIX_WIDTH)),
		status: "",
		meta: "",
	};
}

function fitMeta(model: string | undefined, usage: string | undefined, remaining: number): string {
	if (!Number.isFinite(remaining) || remaining === Number.POSITIVE_INFINITY) {
		const full = [model, usage].filter(Boolean).join(" \u00b7 ");
		return full ? `\u00b7 ${full}` : "";
	}
	if (remaining < 4) return "";
	const both = [model, usage].filter(Boolean).join(" \u00b7 ");
	if (both && columns(`\u00b7 ${both}`) <= remaining) return `\u00b7 ${both}`;
	if (model && columns(`\u00b7 ${model}`) <= remaining) return `\u00b7 ${model}`;
	if (usage && columns(`\u00b7 ${usage}`) <= remaining) return `\u00b7 ${usage}`;
	if (model && remaining >= 10) return `\u00b7 ${truncateColumns(model, remaining - 2)}`;
	return "";
}

function paintTerminalLine(pieces: TerminalPiece[], style: SubagentTerminalStyle): string {
	return pieces
		.filter((piece) => piece.text.length > 0)
		.map((piece) => paintTerminalPiece(piece, style))
		.join(" ");
}

function paintTerminalPiece(piece: TerminalPiece, style: SubagentTerminalStyle): string {
	const paint = statePaint(style, piece.state ?? "running");
	switch (piece.role) {
		case "rule":
			return style.rule(piece.text);
		case "glyph":
			return paint(piece.text);
		case "header":
			return style.bold(paint(piece.text));
		case "name":
			return style.bold(style.title(piece.text));
		case "status":
			return paint(piece.text);
		case "meta":
			return style.dim(piece.text);
	}
}

function statePaint(style: SubagentTerminalStyle, state: Subagent["state"]): (text: string) => string {
	if (state === "success") return style.success;
	if (state === "warning") return style.warning;
	if (state === "error") return style.error;
	return style.accent;
}

function columns(text: string): number {
	let width = 0;
	for (const char of text) {
		const code = char.codePointAt(0) ?? 0;
		if (code === 0xfe0f || code === 0x200d) continue;
		width += charColumns(code);
	}
	return width;
}

function charColumns(code: number): number {
	if (code > 0xffff) return 2;
	if (code >= 0x1100 && code <= 0x115f) return 2;
	if (code >= 0x2e80 && code <= 0xa4cf) return 2;
	if (code >= 0xac00 && code <= 0xd7a3) return 2;
	if (code >= 0xf900 && code <= 0xfaff) return 2;
	if (code >= 0xfe10 && code <= 0xfe6f) return 2;
	if (code >= 0xff00 && code <= 0xff60) return 2;
	if (code >= 0xffe0 && code <= 0xffe6) return 2;
	return 1;
}

function truncateColumns(text: string, width: number): string {
	if (width <= 0) return "";
	if (columns(text) <= width) return text;
	if (width === 1) return "\u2026";
	let out = "";
	let used = 0;
	for (const char of text) {
		const code = char.codePointAt(0) ?? 0;
		if (code === 0xfe0f || code === 0x200d) continue;
		const size = charColumns(code);
		if (used + size > width - 1) break;
		out += char;
		used += size;
	}
	return `${out}\u2026`;
}

function padColumns(text: string, width: number): string {
	const gap = width - columns(text);
	return gap > 0 ? text + " ".repeat(gap) : text;
}
