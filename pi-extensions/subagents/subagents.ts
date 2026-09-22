/**
 * Subagents launched by this parent.
 *
 * The set is the create results this session saw. Status comes from
 * `oppi session get <id>` for those ids only. There is no children list API,
 * and this module does not scan every session.
 */

export interface Subagent {
	id: string;
	parentId?: string;
	title: string;
	subtitle: string;
	link: string;
	state: "running" | "success" | "warning" | "error";
}

export interface SubagentRow {
	id: string;
	title: string;
	subtitle: string;
	state: Subagent["state"];
	link: string;
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
	return {
		...known,
		...refreshed,
		title: stringField(session, "name") ?? known.title,
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
	return {
		id,
		parentId,
		title: name,
		subtitle: shortId(id),
		link: sessionLink(id),
		state: "running",
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

export function subagentRows(subagents: Subagent[]): SubagentRow[] {
	return subagents.map((item) => ({
		id: item.id,
		title: item.title,
		subtitle: item.subtitle,
		state: item.state,
		link: item.link,
	}));
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
	return {
		id,
		parentId,
		title: name,
		subtitle: shortId(id),
		link: sessionLink(id, workspaceId),
		state: stateFromStatus(stringField(session, "status")),
	};
}

function stateFromStatus(status: string | undefined): Subagent["state"] {
	const token = (status ?? "").toLowerCase();
	if (token === "stopped" || token === "idle" || token === "ready") return "success";
	if (token === "error") return "error";
	if (token === "attention") return "warning";
	return "running";
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
