/**
 * Supervision policy for the subagent tool.
 *
 * Settlement, attention, stall, and wait failure wake the parent. Ordinary
 * waiting does not. Prompt-cache refresh belongs to Pi's warmer; this module
 * only asks it to continue when a supervised child is still going to report
 * back and the refresh is worth the cost.
 */

export const CACHE_WARM_SAVINGS_FLOOR = 0.05;
export const SUPERVISED_ENTRY = "subagent-supervised";
export const CALLER_ENV = "OPPI_CALLER_SESSION_ID";
const SETTLEMENT_CLIP = 1200;

export interface WatchChild {
	id: string;
	name: string;
	supervise: boolean;
	attentionDelivered: boolean;
}


export interface LaunchPlanInput {
	workspace: string;
	prompt: string;
	name?: string;
	model?: string;
	thinking?: string;
	agent?: string;
	worktree?: string;
	tools?: string;
	excludeTools?: string;
	autoStop?: boolean;
	allowNested?: boolean;
	idempotencyKey?: string;
	supervise?: boolean;
	parentId?: string;
}

export interface LaunchPlan {
	args: string[];
	stdin: string;
	env: Record<string, string>;
	supervise: boolean;
}

export interface SettlementItem {
	name: string;
	id: string;
	status: string;
	link: string;
	lastMessage?: string;
}

export interface StoredEntry {
	type?: string;
	customType?: string;
	data?: unknown;
}

export function hasPendingSupervision(children: WatchChild[], settledIds: ReadonlySet<string>): boolean {
	return children.some((child) => child.supervise && !settledIds.has(child.id));
}

/**
 * Ask Pi to refresh only when a supervised child will report back and a
 * certain continuation would clear Pi's own savings floor. Returning nothing
 * leaves Pi's decision, and another extension's decision, alone.
 */
export function cacheWarmingOverride(input: {
	pendingSupervised: boolean;
	action: "warm" | "stop";
	warmCost: number;
	missCost: number;
}): { action: "warm" } | undefined {
	if (!input.pendingSupervised || input.action === "warm") return undefined;
	if (!Number.isFinite(input.warmCost) || !Number.isFinite(input.missCost)) return undefined;
	if (input.missCost - input.warmCost < CACHE_WARM_SAVINGS_FLOOR) return undefined;
	return { action: "warm" };
}

export function launchReceipt(input: { name: string; id: string; supervise: boolean; link: string }): string {
	if (!input.supervise) {
		return `Launched ${input.name} ${input.id}. Not supervising, so this session will not be woken when it finishes. Collect it later. Do not wait. ${input.link}`;
	}
	return `Launched ${input.name} ${input.id}. Supervising. The result arrives as a follow-up. Waiting does not send acknowledgment turns. Do not poll with session wait, session get, session inspect, or session list. Inspect a settled child only when that follow-up reply is not enough. ${input.link}`;

}

export function attentionText(input: { name: string; link: string }): string {
	return `Subagent needs attention: ${input.name} ${input.link}. Answer it in that session. Supervision pauses for this child until it is busy again. Do not relaunch.`;
}

export function isSettledStatus(status: string | undefined): boolean {
	// Server wait treats ready, stopped, and error as idle. idle is accepted if a payload uses it.
	const token = (status ?? "").toLowerCase();
	return token === "ready" || token === "stopped" || token === "error" || token === "idle";
}

export function needsAttention(pendingDialogs: number | undefined): boolean {
	return (pendingDialogs ?? 0) > 0;
}

export function shouldClearAttention(pendingDialogs: number | undefined): boolean {
	return pendingDialogs === 0;
}

export interface WaitPlan {
	eitherIds: string[];
	idleIds: string[];
}

export function waitPlan(children: WatchChild[], settledIds: ReadonlySet<string>): WaitPlan {
	const open = children.filter((child) => !settledIds.has(child.id));
	return {
		eitherIds: open.filter((child) => !child.attentionDelivered).map((child) => child.id),
		idleIds: open.filter((child) => child.attentionDelivered).map((child) => child.id),
	};
}

export function isFailedWaitEnvelope(payload: unknown, exitCode: number | null): boolean {
	if (exitCode !== 0 && exitCode !== null) return true;
	const record = asRecord(payload);
	if (!record) return true;
	if (record.ok === false) return true;
	const data = record.ok === true ? asRecord(record.data) : record;
	if (!data) return true;
	if (data.timed_out === true) return false;
	if (typeof data.session_id === "string" || typeof data.sessionId === "string") return false;
	if (Array.isArray(data.sessions)) return false;
	return true;
}

export type DeliveryKind = "settled" | "attention" | "stalled" | "failure";

export function parentDelivery(kind: DeliveryKind): {
	customType: string;
	display: boolean;
	deliverAs: "followUp";
	triggerTurn: true;
} {
	const customType = {
		settled: "subagent-settled",
		attention: "subagent-attention",
		stalled: "subagent-stalled",
		failure: "subagent-wait-failed",
	}[kind];
	return {
		customType,
		display: true,
		deliverAs: "followUp",
		triggerTurn: true,
	};
}

export interface WaitEffect {
	settle: Array<{ id: string; status: string; last?: string }>;
	attention: string[];
	clearAttention: string[];
	stall: string[];
	widgetSettle: string[];
	widgetAttention: string[];
	stalls: Map<string, StallState>;
}

export function reduceWait(input: {
	children: WatchChild[];
	settledIds: ReadonlySet<string>;
	reading: WaitReading;
	now: number;
	stalls: Map<string, StallState>;
}): WaitEffect {
	const stalls = new Map(input.stalls);
	const settle: WaitEffect["settle"] = [];
	const attention: string[] = [];
	const clearAttention: string[] = [];
	const stallIds: string[] = [];
	const widgetSettle: string[] = [];
	const widgetAttention: string[] = [];
	const seen = new Set<string>();
	for (const record of [...input.reading.settled, ...input.reading.attention, ...input.reading.running]) {
		if (seen.has(record.id) || input.settledIds.has(record.id)) continue;
		seen.add(record.id);
		const child = input.children.find((item) => item.id === record.id);
		if (!child) continue;
		if (!child.supervise) {
			if (isSettledStatus(record.status) && !needsAttention(record.pendingDialogs)) {
				widgetSettle.push(record.id);
				stalls.delete(record.id);
			} else if (needsAttention(record.pendingDialogs)) {
				if (!child.attentionDelivered) widgetAttention.push(record.id);
			} else if (shouldClearAttention(record.pendingDialogs) && child.attentionDelivered) {
				clearAttention.push(record.id);
			}
			continue;
		}
		if (isSettledStatus(record.status) && !needsAttention(record.pendingDialogs)) {
			settle.push({ id: record.id, status: record.status ?? "stopped", last: record.last });
			stalls.delete(record.id);
			continue;
		}
		if (needsAttention(record.pendingDialogs)) {
			if (!child.attentionDelivered) attention.push(record.id);
			continue;
		}
		if (shouldClearAttention(record.pendingDialogs) && child.attentionDelivered) {
			clearAttention.push(record.id);
		}
		const signature = `${record.status ?? ""}:${record.last ?? ""}`;
		const stall = nextStall(stalls.get(record.id), signature, input.now);
		stalls.set(record.id, stall.state);
		if (stall.stalled) stallIds.push(record.id);
	}
	return { settle, attention, clearAttention, stall: stallIds, widgetSettle, widgetAttention, stalls };
}

export interface WaitRecord {
	id: string;
	status?: string;
	pendingDialogs?: number;
	last?: string;
}

export interface WaitReading {
	timedOut: boolean;
	settled: WaitRecord[];
	attention: WaitRecord[];
	running: WaitRecord[];
}

export function readWait(payload: unknown): WaitReading {
	const data = envelopeData(payload);
	const records = waitRecords(data);
	const settled: WaitRecord[] = [];
	const attention: WaitRecord[] = [];
	const running: WaitRecord[] = [];
	for (const record of records) {
		if (needsAttention(record.pendingDialogs)) attention.push(record);
		else if (isSettledStatus(record.status)) settled.push(record);
		else running.push(record);
	}
	return { timedOut: data?.timed_out === true, settled, attention, running };
}

export const STALL_MS = 30 * 60 * 1000;

export interface StallState {
	signature: string;
	since: number;
	delivered: boolean;
}

export function nextStall(
	previous: StallState | undefined,
	signature: string,
	now: number,
): { state: StallState; stalled: boolean } {
	if (!previous || previous.signature !== signature) {
		return { state: { signature, since: now, delivered: false }, stalled: false };
	}
	if (!previous.delivered && now - previous.since >= STALL_MS) {
		return { state: { ...previous, delivered: true }, stalled: true };
	}
	return { state: previous, stalled: false };
}

export function settlementText(items: SettlementItem[]): string {
	const blocks = items.map((item) => {
		const reply = clip(item.lastMessage);
		const tail = reply ? `\nReply: ${reply}` : "";
		return `${item.name} ${item.status} ${item.link}${tail}`;
	});
	return `Subagent settled. Read this follow-up; do not relaunch and do not call oppi session wait.\n${blocks.join("\n")}`;
}

/**
 * A launch with no model and no saved agent inherits the parent's model, silently skipping
 * routing (a coordinator's reviewers all became Opus with full tools). Saved agents carry
 * their own default model; `workspace_default` does not.
 */
export function missingModelError(input: Pick<LaunchPlanInput, "model" | "agent">): string | null {
	if (input.model?.trim()) return null;
	const agent = input.agent?.trim();
	if (agent && agent !== "workspace_default") return null;
	return "Pass model: a launch without model or a saved agent inherits this session's model and skips routing. Pick the route with the agent-workflow skill's scripts/route.ts <role>, or pass a saved agent whose profile sets a default model.";
}

export function launchPlan(input: LaunchPlanInput): LaunchPlan {
	const supervise = input.supervise !== false;
	const args = ["session", "create", "--workspace", input.workspace, "--json", "--prompt", "@-"];
	pushFlag(args, "--name", input.name);
	pushFlag(args, "--model", input.model);
	pushFlag(args, "--thinking", input.thinking);
	pushFlag(args, "--agent", input.agent);
	pushFlag(args, "--worktree", input.worktree);
	pushFlag(args, "--tools", input.tools);
	pushFlag(args, "--exclude-tools", input.excludeTools);
	pushFlag(args, "--idempotency-key", input.idempotencyKey);
	if (input.autoStop) args.push("--auto-stop");
	if (input.allowNested) args.push("--allow-nested-delegation");
	const env: Record<string, string> = {};
	if (input.parentId) env[CALLER_ENV] = input.parentId;
	return { args, stdin: input.prompt, env, supervise };
}

export function restoreSupervised(entries: StoredEntry[]): WatchChild[] {
	const byId = new Map<string, WatchChild | null>();
	for (const entry of entries) {
		if (entry.type !== "custom" || entry.customType !== SUPERVISED_ENTRY) continue;
		const data = asRecord(entry.data);
		const id = stringField(data, "id");
		if (!id) continue;
		if (data?.released === true || data?.supervise === false) {
			byId.set(id, null);
			continue;
		}
		byId.set(id, {
			id,
			name: stringField(data, "name") ?? id.slice(0, 8),
			supervise: true,
			attentionDelivered: false,
		});
	}
	return [...byId.values()].filter((item): item is WatchChild => item !== null);
}

export function watchedIds(children: WatchChild[], settledIds: ReadonlySet<string>): string[] {
	return children.filter((child) => child.supervise && !settledIds.has(child.id)).map((child) => child.id);
}

function envelopeData(payload: unknown): Record<string, unknown> | null {
	if (typeof payload === "string") {
		try {
			return envelopeData(JSON.parse(payload) as unknown);
		} catch {
			return null;
		}
	}
	const record = asRecord(payload);
	if (!record) return null;
	if (record.ok === true) return asRecord(record.data);
	return record;
}

function waitRecords(data: Record<string, unknown> | null): WaitRecord[] {
	if (!data) return [];
	const sessions = data.sessions;
	if (Array.isArray(sessions)) {
		return sessions.map(waitRecord).filter((item): item is WaitRecord => item !== null);
	}
	const one = waitRecord(data);
	return one ? [one] : [];
}

function waitRecord(value: unknown): WaitRecord | null {
	const record = asRecord(value);
	if (!record) return null;
	const id = stringField(record, "session_id") ?? stringField(record, "sessionId") ?? stringField(record, "id");
	if (!id) return null;
	const dialogs = record.pending_dialogs ?? record.pendingDialogs;
	return {
		id,
		status: stringField(record, "status"),
		pendingDialogs: typeof dialogs === "number" ? dialogs : undefined,
		last: stringField(record, "last") ?? stringField(record, "output_delta") ?? stringField(record, "lastMessage"),
	};
}

function clip(text: string | undefined): string {
	const trimmed = text?.trim() ?? "";
	if (!trimmed) return "";
	if (trimmed.length <= SETTLEMENT_CLIP) return trimmed;
	return `${trimmed.slice(0, SETTLEMENT_CLIP)}…`;
}

function pushFlag(args: string[], flag: string, value: string | undefined): void {
	if (!value?.trim()) return;
	args.push(flag, value.trim());
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
