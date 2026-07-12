/* eslint-disable no-console */
import { readFileSync } from "node:fs";
import * as c from "../../ansi.js";
import type { Session } from "../../types.js";
import {
  localApiRequest,
  type LocalApiConnection,
  type LocalApiHostResolvers,
  type LocalApiRequestOptions,
} from "../local-api-client.js";
import {
  codeValue,
  nonEmptyDetails,
  printDetails,
  printList,
  writeJsonEnvelope,
} from "../output.js";
import {
  apiStatus,
  inferWorkspaceIdFromCwdForCli,
  resolveWorkspaceIdForCli,
} from "../resources.js";
import {
  isCliModelResolutionError,
  modelResolutionErrorEnvelope,
  printModelResolutionError,
  resolveModelFlagForCli,
} from "../model-resolution.js";
import { parseDurationMs } from "./wait.js";

type SessionTraceEvent = {
  id?: string;
  type?: string;
  text?: string;
  message?: unknown;
  thinking?: string;
  tool?: string;
  args?: Record<string, unknown>;
  output?: string;
  toolName?: string;
  isError?: boolean;
  [key: string]: unknown;
};

type SessionTraceOutlineEntry = {
  id: string;
  kind: string;
  summary: string;
  timestamp?: string;
  tool?: string;
  isError?: boolean;
};

type SessionInspectView = "overview" | "outline" | "response" | "messages" | "summary" | "tools";

type SessionInspectTurn = {
  turn: number;
  userTexts: string[];
  assistantTexts: string[];
  thinkingTexts: string[];
  systemTexts: string[];
  summaryTexts: string[];
  toolCalls: Array<{ id?: string; tool?: string; args?: Record<string, unknown> }>;
  toolResults: Array<{ toolName?: string; output?: string; isError?: boolean }>;
};

type SessionListRow = Partial<Session> & {
  source?: "tui" | string;
  pendingAskCount?: number;
  lastModified?: number;
  path?: string;
  piSessionId?: string;
};

type WorkspaceSessionCollectionResponse = {
  workspaceId: string;
  sinceMs?: number;
  untilMs?: number;
  serverNow?: number;
  active?: SessionListRow[];
  stopped?: SessionListRow[];
};

type SessionListResponse = {
  sessions?: SessionListRow[];
  serverNow?: number;
};

const DEFAULT_SESSION_LIST_RECENT_DAYS = 3;
const DAY_MS = 86_400_000;
const INLINE_DATA_URL_RE = /data:([a-z0-9.+-]+\/[a-z0-9.+-]+);base64,[a-z0-9+/_=-]+/gi;

export async function cmdSession(
  storage: LocalApiConnection,
  action: string | undefined,
  positional: string[],
  flags: Record<string, string>,
  hostResolvers: LocalApiHostResolvers = {},
  cwd = process.cwd(),
): Promise<void> {
  const requestedMode = action || "list";
  const mode = requestedMode === "start" ? "create" : requestedMode;
  const jsonOutput = flags.json === "true";

  async function call<T>(path: string, options?: LocalApiRequestOptions): Promise<T> {
    return localApiRequest<T>(storage, path, options, hostResolvers);
  }

  function output(data: Record<string, unknown>, human: () => void): void {
    if (jsonOutput) writeJsonEnvelope({ ok: true, data });
    else human();
  }

  try {
    flags = normalizeSessionFlagAliases(mode, flags);
    assertSessionFlags(mode, flags);

    if (mode === "list") {
      const result = await listSessions(storage, flags, call, hostResolvers);
      const sessions = Array.isArray(result.sessions) ? result.sessions : [];
      output({ sessions: sessions.map(compactSessionListRow) }, () => {
        printList(
          `Sessions (${sessions.length})`,
          sessions.map((session) => {
            const path = clipListCell(session.path ?? session.piSessionFile ?? "", 56);
            return {
              id: session.id ?? "?",
              status: session.status ?? "?",
              title: clipListCell(session.name ?? session.firstMessage ?? "(unnamed)", 88),
              meta: [sessionWorkspaceMeta(session), `worktree ${session.worktreeId ?? "main"}`],
              details: path ? [`path ${path}`] : [],
            };
          }),
          { empty: "No sessions found." },
        );
      });
      return;
    }

    if (mode === "get") {
      const id = requirePositional(positional, "session id is required");
      const result = await call<Record<string, unknown>>(`/sessions/${encodeURIComponent(id)}`);
      output(result, () => {
        const session = result.session as Partial<Session> | undefined;
        printDetails(
          "Session",
          nonEmptyDetails([
            ["ID", codeValue(session?.id ?? id)],
            ["Status", session?.status ?? "unknown"],
            ["Name", session?.name ?? ""],
            ["Workspace", session?.workspaceName ?? session?.workspaceId ?? ""],
            ["Worktree", session?.worktreeId ?? ""],
            ["Model", session?.model ?? ""],
          ]),
        );
      });
      return;
    }

    if (mode === "create") {
      await createSession(storage, flags, jsonOutput, hostResolvers);
      return;
    }

    if (mode === "send") {
      const id = requirePositional(positional, "session id is required");
      const text = resolvePromptInput(flags.text, "--text");
      const commandType = resolveSendStreamingKind(flags) ?? "prompt";
      const result = await sendSessionInput(id, commandType, text, call);
      assertNoCommandError(result, commandType === "prompt");
      output({ session_id: id, command: commandType }, () =>
        printSessionNotice(`${commandType} sent → ${id}`),
      );
      return;
    }

    if (mode === "abort") {
      const id = requirePositional(positional, "session id is required");
      const result = await call<Record<string, unknown>>(
        `/sessions/${encodeURIComponent(id)}/command`,
        { method: "POST", body: { type: "abort" } },
      );
      assertNoCommandError(result);
      output({ session_id: id, command: "abort" }, () =>
        printSessionNotice(`aborted turn → ${id}`),
      );
      return;
    }

    if (mode === "dialogs") {
      const id = requirePositional(positional, "session id is required");
      const result = await call<Record<string, unknown>>(
        `/sessions/${encodeURIComponent(id)}/dialogs`,
      );
      const dialogs = Array.isArray(result.dialogs) ? (result.dialogs as DialogSnapshot[]) : [];
      output(
        {
          session_id: id,
          dialogs,
          ...(typeof result.serverNow === "number" ? { server_now: result.serverNow } : {}),
        },
        () => {
          printList(
            `Pending dialogs for ${id} (${dialogs.length})`,
            dialogs.map((dialog) => ({
              id: dialog.id ?? "?",
              status: dialog.method ?? "dialog",
              title: dialogPromptText(dialog),
              meta: dialogMetaLabels(dialog),
              details: dialogOptionDetails(dialog),
            })),
            { empty: "No pending dialogs." },
          );
        },
      );
      return;
    }

    if (mode === "respond") {
      const id = requirePositional(positional, "session id is required");
      const list = await call<{ dialogs?: DialogSnapshot[] }>(
        `/sessions/${encodeURIComponent(id)}/dialogs`,
      );
      const target = resolveDialogTarget(list.dialogs ?? [], flags.dialog?.trim());
      const payload = buildDialogResponse(target, flags);
      const result = await call<Record<string, unknown>>(
        `/sessions/${encodeURIComponent(id)}/command`,
        { method: "POST", body: payload },
      );
      assertNoCommandError(result);
      output({ session_id: id, dialog_id: target.id, method: target.method }, () =>
        printSessionNotice(
          `answered ${target.id ?? "dialog"} (${target.method ?? "dialog"}) → ${id}`,
        ),
      );
      return;
    }

    if (mode === "watch") {
      await watchSessions(positional, flags, jsonOutput, call);
      return;
    }

    if (mode === "wait") {
      const id = requirePositional(positional, "session id is required");
      const condition = parseWatchCondition(flags.for, "either");
      if (condition === "any-change") {
        throw new Error("--for must be idle, attention, or either");
      }
      const outcome = await runSessionWatch(
        [id],
        {
          condition,
          requireAll: false,
          intervalMs: parseDurationMs(flags.poll ?? "1s"),
          timeoutMs: parseDurationMs(flags.timeout ?? "10m"),
        },
        call,
        () => {},
      );
      const status = outcome.kind === "session" ? (outcome.status ?? null) : null;
      const reason = outcome.kind === "session" ? outcome.reason : condition;
      const pendingDialogs = outcome.kind === "session" ? outcome.pendingDialogs : undefined;
      output(
        {
          session_id: id,
          reason,
          status,
          ...(pendingDialogs !== undefined ? { pending_dialogs: pendingDialogs } : {}),
        },
        () =>
          printSessionNotice(
            `${id} ${reason} · status=${status ?? "unknown"}${pendingDialogs !== undefined ? ` · dialogs=${pendingDialogs}` : ""}`,
          ),
      );
      return;
    }

    if (mode === "read" || mode === "trace") {
      const id = requirePositional(positional, "session id is required");
      const params = new URLSearchParams();
      if (mode === "read" && flags.tail) params.set("tail", flags.tail);
      if (mode === "trace" && flags.include) params.set("include", flags.include);
      const result = await call<Record<string, unknown>>(
        `/sessions/${encodeURIComponent(id)}/${mode}${querySuffix(params)}`,
      );
      output(withoutSessionMetadata(id, result), () => {
        const trace = Array.isArray(result.trace) ? (result.trace as SessionTraceEvent[]) : [];
        printList(
          `${mode === "read" ? "Messages" : "Trace"} for ${id} (${trace.length})`,
          trace.map((event) => ({
            status: event.type ?? "event",
            title: eventText(event) || "(empty)",
          })),
          { empty: "No trace events returned." },
        );
      });
      return;
    }

    if (mode === "events") {
      const id = requirePositional(positional, "session id is required");
      const params = new URLSearchParams();
      if (flags.since) params.set("since", flags.since);
      const result = await call<Record<string, unknown>>(
        `/sessions/${encodeURIComponent(id)}/events${querySuffix(params)}`,
      );
      output(result, () => {
        const events = Array.isArray(result.events)
          ? (result.events as Array<{ seq?: number; type?: string }>)
          : [];
        printList(
          `Events for ${id} (${events.length})`,
          events.map((event) => ({
            id: event.seq ?? "?",
            title: event.type ?? "event",
          })),
          { empty: "No events returned." },
        );
      });
      return;
    }

    if (mode === "stop") {
      const id = requirePositional(positional, "session id is required");
      const result = await call<Record<string, unknown>>(
        `/sessions/${encodeURIComponent(id)}/stop`,
        {
          method: "POST",
        },
      );
      const session = result.session as Partial<Session> | undefined;
      output({ session_id: id, status: session?.status ?? "stopped" }, () =>
        printSessionNotice(`stopped ${id}`),
      );
      return;
    }

    if (mode === "search") {
      const query = flags.query?.trim() || positional.join(" ").trim();
      const hasTimeFilter = !!flags.since || !!flags.until;
      if (!query && !hasTimeFilter)
        throw new Error("--query, search text, or a date filter is required");
      const params = new URLSearchParams();
      if (query) params.set("q", query);
      if (flags.limit) params.set("limit", flags.limit);
      if (flags.since) params.set("since", flags.since);
      if (flags.until) params.set("until", flags.until);
      if (flags.workspace && flags.all === "true") {
        throw new Error("--workspace and --all cannot be used together");
      }
      if (flags.workspace) {
        const workspaceId = await resolveWorkspaceIdForCli(storage, flags.workspace, hostResolvers);
        params.set("workspaceId", workspaceId);
      } else if (flags.all !== "true") {
        const workspaceId = await inferWorkspaceIdFromCwdForCli(storage, cwd, hostResolvers);
        if (!workspaceId)
          throw new Error("Could not infer workspace from cwd; pass --workspace or --all");
        params.set("workspaceId", workspaceId);
      }
      const result = await call<Record<string, unknown>>(`/sessions/search${querySuffix(params)}`);
      const results = Array.isArray(result.results)
        ? (result.results as Array<{
            sessionId?: string;
            snippet?: string;
            text?: string;
            title?: string;
            rank?: number;
            score?: number;
            session?: Partial<Session>;
          }>)
        : [];
      output(compactSearchResult(result), () => {
        printList(
          `Search results (${results.length})`,
          results.map((searchResult) => ({
            id: searchResult.sessionId ?? "?",
            status: searchResult.score !== undefined ? String(searchResult.score) : "",
            title: clipListCell(
              searchResult.snippet ?? searchResult.text ?? searchResult.title ?? "(match)",
              88,
            ),
            meta: [searchResult.session?.name ?? ""],
          })),
          { empty: "No matching sessions." },
        );
      });
      return;
    }

    if (mode === "inspect") {
      const id = requirePositional(positional, "session id is required");
      const result = await inspectSession(id, positional.slice(1), flags, call);
      output(inspectJsonResult(result), () => {
        console.log(result.text || "(empty)");
      });
      return;
    }

    if (mode === "delete") {
      const id = requirePositional(positional, "session id is required");
      const workspaceId = await resolveSessionWorkspaceId(id, call);
      const result = await call<Record<string, unknown>>(
        `/workspaces/${encodeURIComponent(workspaceId)}/sessions/${encodeURIComponent(id)}`,
        { method: "DELETE" },
      );
      output({ session_id: id, deleted: result.deleted === true }, () =>
        printSessionNotice(`deleted ${id}`),
      );
      return;
    }

    if (mode === "resume") {
      const id = requirePositional(positional, "session id is required");
      const workspaceId = await resolveSessionWorkspaceId(id, call);
      const result = await call<Record<string, unknown>>(
        `/workspaces/${encodeURIComponent(workspaceId)}/sessions/${encodeURIComponent(id)}/resume`,
        { method: "POST" },
      );
      const session = result.session as Partial<Session> | undefined;
      output({ session_id: id, status: session?.status ?? "ready" }, () =>
        printSessionNotice(`resumed ${id}`),
      );
      return;
    }

    if (mode === "fork") {
      const id = requirePositional(positional, "session id is required");
      const entryId = flags.entry?.trim();
      if (!entryId) throw new Error("--entry is required");
      const workspaceId = await resolveSessionWorkspaceId(id, call);
      const result = await call<Record<string, unknown>>(
        `/workspaces/${encodeURIComponent(workspaceId)}/sessions/${encodeURIComponent(id)}/fork`,
        {
          method: "POST",
          body: { entryId, ...(flags.name ? { name: flags.name } : {}) },
        },
      );
      const session = result.session as Partial<Session> | undefined;
      output(
        {
          source_session_id: id,
          session_id: session?.id ?? null,
          status: session?.status ?? null,
          ...(session?.name ? { name: session.name } : {}),
        },
        () => printSessionNotice(`forked ${id} → ${session?.id ?? "?"}`),
      );
      return;
    }

    if (mode === "changes") {
      const id = requirePositional(positional, "session id is required");
      const workspaceId = await resolveSessionWorkspaceId(id, call);
      const result = await call<Record<string, unknown>>(
        `/workspaces/${encodeURIComponent(workspaceId)}/sessions/${encodeURIComponent(id)}/changes`,
      );
      output(result, () => {
        const files = Array.isArray(result.files)
          ? (result.files as Array<{ path?: string; status?: string }>)
          : [];
        printList(
          `Changed files for ${id} (${files.length})`,
          files.map((file) => ({ status: file.status ?? "", title: file.path ?? "(unknown)" })),
          { empty: "No changed files returned." },
        );
      });
      return;
    }

    if (mode === "diff") {
      const id = requirePositional(positional, "session id is required");
      const positionalPath = positional[1]?.trim();
      if (flags.path && positionalPath) {
        throw new Error("Conflicting path inputs: use --path or -- <path>, not both");
      }
      const path = flags.path?.trim() || positionalPath;
      if (!path) throw new Error("--path or -- <path> is required");
      const workspaceId = await resolveSessionWorkspaceId(id, call);
      const params = new URLSearchParams();
      params.set("path", path);
      const result = await call<Record<string, unknown>>(
        `/workspaces/${encodeURIComponent(workspaceId)}/sessions/${encodeURIComponent(id)}/diff${querySuffix(params)}`,
      );
      output(result, () => {
        printDetails("Session diff", [
          ["Session", codeValue(id)],
          ["Path", codeValue(path)],
        ]);
      });
      return;
    }

    if (mode === "tool-output") {
      const id = requirePositional(positional, "session id is required");
      const toolCallId = positional[1]?.trim();
      if (!toolCallId) throw new Error("tool call id is required");
      const workspaceId = await resolveSessionWorkspaceId(id, call);
      const result = await call<Record<string, unknown>>(
        `/workspaces/${encodeURIComponent(workspaceId)}/sessions/${encodeURIComponent(id)}/tool-output/${encodeURIComponent(toolCallId)}`,
      );
      output(result, () => {
        printDetails("Tool output", [
          ["Session", codeValue(id)],
          ["Tool", codeValue(toolCallId)],
        ]);
      });
      return;
    }

    if (mode === "trace-page" || mode === "trace-outline") {
      const id = requirePositional(positional, "session id is required");
      const workspaceId = await resolveSessionWorkspaceId(id, call);
      const params = new URLSearchParams();
      if (mode === "trace-page") {
        if (flags.cursor) params.set("cursor", flags.cursor);
        if (flags["around-entry"]) params.set("aroundEntryId", flags["around-entry"]);
        if (flags["target-events"]) params.set("targetEvents", flags["target-events"]);
        if (flags["preview-bytes"]) params.set("previewBytes", flags["preview-bytes"]);
      }
      const result = await call<Record<string, unknown>>(
        `/workspaces/${encodeURIComponent(workspaceId)}/sessions/${encodeURIComponent(id)}/${mode}${querySuffix(params)}`,
      );
      output(withoutSessionMetadata(id, result), () => {
        if (mode === "trace-outline") {
          printTraceOutline(id, result);
          return;
        }
        printDetails("Trace page", [["Session", codeValue(id)]]);
      });
      return;
    }

    throw new Error(
      "Usage: oppi session list|get|create|send|abort|dialogs|respond|watch|wait|read|events|trace|search|inspect|stop|resume|fork|delete|changes|diff|tool-output|trace-page|trace-outline",
    );
  } catch (err: unknown) {
    const status = apiStatus(err);
    const message = err instanceof Error ? err.message : String(err);
    if (jsonOutput) {
      writeJsonEnvelope({
        ok: false,
        error: isCliModelResolutionError(err)
          ? modelResolutionErrorEnvelope(err)
          : { message, ...(status ? { status } : {}) },
      });
      process.exitCode = 1;
      return;
    }
    if (isCliModelResolutionError(err)) {
      printModelResolutionError(err);
    } else {
      console.log(c.red(`  Error: ${message}`));
    }
    process.exit(1);
  }
}

async function createSession(
  storage: LocalApiConnection,
  flags: Record<string, string>,
  jsonOutput: boolean,
  hostResolvers: LocalApiHostResolvers,
): Promise<void> {
  const workspaceRef = flags.workspace?.trim();
  const promptText =
    flags.prompt === undefined ? undefined : resolvePromptInput(flags.prompt, "--prompt");
  if (!workspaceRef || promptText === undefined) {
    const message = "--workspace and --prompt are required";
    if (jsonOutput) writeJsonEnvelope({ ok: false, error: { message } });
    else {
      console.log(c.red(`  Error: ${message}`));
      console.log(c.dim("  Usage: oppi session create --workspace <id> --prompt <text> [--json]"));
    }
    process.exitCode = 1;
    return;
  }
  const workspaceId = await resolveWorkspaceIdForCli(storage, workspaceRef, hostResolvers);
  const resolvedModel = await resolveModelFlagForCli(storage, flags.model, hostResolvers);
  const savedAgent = savedAgentReference(flags.agent);
  const result = savedAgent
    ? await localApiRequest<{ session: Session; receipt?: Record<string, unknown> }>(
        storage,
        `/agents/${encodeURIComponent(savedAgent)}/sessions`,
        {
          method: "POST",
          body: {
            prompt: { text: promptText },
            target: {
              workspaceId,
              ...(flags.worktree ? { worktreeId: flags.worktree } : {}),
            },
            ...(flags.name ? { sessionName: flags.name } : {}),
            ...(resolvedModel || flags.thinking
              ? {
                  overrides: {
                    ...(resolvedModel ? { model: resolvedModel } : {}),
                    ...(flags.thinking ? { thinkingLevel: flags.thinking } : {}),
                  },
                }
              : {}),
            ...(flags["idempotency-key"] ? { idempotencyKey: flags["idempotency-key"] } : {}),
          },
        },
        hostResolvers,
      )
    : await localApiRequest<{ session: Session; prompted?: boolean }>(
        storage,
        `/workspaces/${encodeURIComponent(workspaceId)}/sessions`,
        {
          method: "POST",
          body: {
            prompt: promptText,
            ...(flags.name ? { name: flags.name } : {}),
            ...(resolvedModel ? { model: resolvedModel } : {}),
            ...(flags.thinking ? { thinking: flags.thinking } : {}),
            ...(flags.worktree ? { worktreeId: flags.worktree } : {}),
            ...(flags["idempotency-key"] ? { launchIdempotencyKey: flags["idempotency-key"] } : {}),
          },
        },
        hostResolvers,
      );
  if (jsonOutput) {
    writeJsonEnvelope({ ok: true, data: { session_id: result.session.id } });
    return;
  }

  printSessionNotice(`session ${result.session.id} created in ${workspaceId}`);
}

function resolvePromptInput(value: string | undefined, flag: "--prompt" | "--text"): string {
  if (value === undefined) throw new Error(`${flag} is required`);
  const text = value === "@-" ? readFileSync(0, "utf-8") : value;
  if (!text.trim()) throw new Error(`${flag} must not be empty`);
  return text;
}

const SESSION_FLAGS: Record<string, readonly string[]> = {
  list: ["agent", "json", "limit", "status", "workspace", "worktree"],
  get: ["json"],
  create: [
    "agent",
    "idempotency-key",
    "json",
    "model",
    "name",
    "prompt",
    "thinking",
    "workspace",
    "worktree",
  ],
  send: ["follow-up", "json", "steer", "text"],
  abort: ["json"],
  dialogs: ["json"],
  respond: ["answers", "cancel", "confirm", "decline", "dialog", "json", "option", "text"],
  watch: ["all", "interval", "json", "timeout", "until"],
  wait: ["for", "json", "poll", "timeout"],
  read: ["json", "tail"],
  events: ["json", "since"],
  trace: ["include", "json"],
  search: ["all", "json", "limit", "query", "since", "until", "workspace"],
  inspect: ["json", "turns", "view"],
  stop: ["json"],
  delete: ["json"],
  resume: ["json"],
  fork: ["entry", "json", "name"],
  changes: ["json"],
  diff: ["json", "path"],
  "tool-output": ["json"],
  "trace-page": ["around-entry", "cursor", "json", "preview-bytes", "target-events"],
  "trace-outline": ["json"],
};

function normalizeSessionFlagAliases(
  mode: string,
  flags: Record<string, string>,
): Record<string, string> {
  const aliases =
    mode === "inspect"
      ? ([["turn", "turns"]] as const)
      : mode === "wait"
        ? ([["until", "for"]] as const)
        : [];
  if (aliases.length === 0) return flags;

  const normalized = { ...flags };
  for (const [alias, canonical] of aliases) {
    if (!Object.hasOwn(normalized, alias)) continue;
    if (Object.hasOwn(normalized, canonical)) {
      throw new Error(`Conflicting flags: --${alias} and --${canonical}`);
    }
    normalized[canonical] = normalized[alias] ?? "true";
    delete normalized[alias];
  }
  return normalized;
}

function assertSessionFlags(mode: string, flags: Record<string, string>): void {
  const allowed = SESSION_FLAGS[mode];
  if (!allowed) return;
  const allowedSet = new Set(allowed);
  const unsupported = Object.keys(flags).filter((flag) => !allowedSet.has(flag));
  if (unsupported.length > 0) {
    throw new Error(`Unsupported flag for 'session ${mode}': --${unsupported.sort().join(", --")}`);
  }
}

function requirePositional(positional: string[], message: string): string {
  const value = positional[0]?.trim();
  if (!value) throw new Error(message);
  return value;
}

function querySuffix(params: URLSearchParams): string {
  const query = params.toString();
  return query ? `?${query}` : "";
}

function compactSessionListRow(session: SessionListRow): Record<string, unknown> {
  return {
    id: session.id ?? null,
    status: session.status ?? null,
    name: session.name ?? null,
    workspace_id: session.workspaceId ?? null,
    workspace_name: session.workspaceName ?? null,
    worktree_id: session.worktreeId ?? null,
    model: session.model ?? null,
    runtime: session.runtime ?? null,
    last_activity: session.lastActivity ?? session.lastModified ?? null,
    message_count: session.messageCount ?? null,
    pending_asks: session.pendingAskCount ?? 0,
  };
}

function compactSearchResult(result: Record<string, unknown>): Record<string, unknown> {
  const rows = Array.isArray(result.results) ? result.results : [];
  return {
    ...(typeof result.query === "string" ? { query: result.query } : {}),
    ...(typeof result.totalResults === "number" ? { total_results: result.totalResults } : {}),
    ...(typeof result.sort === "string" ? { sort: result.sort } : {}),
    results: rows.map((value) => {
      const row = isRecord(value) ? value : {};
      return {
        session_id: typeof row.sessionId === "string" ? row.sessionId : null,
        workspace_id: typeof row.workspaceId === "string" ? row.workspaceId : null,
        title: typeof row.title === "string" ? row.title : null,
        snippet:
          typeof row.snippet === "string"
            ? row.snippet
            : typeof row.text === "string"
              ? row.text
              : null,
        rank:
          typeof row.rank === "number"
            ? row.rank
            : typeof row.score === "number"
              ? row.score
              : null,
        updated_at_ms: typeof row.updatedAtMs === "number" ? row.updatedAtMs : null,
      };
    }),
  };
}

function withoutSessionMetadata(
  sessionId: string,
  result: Record<string, unknown>,
): Record<string, unknown> {
  const compact: Record<string, unknown> = { ...result, session_id: sessionId };
  delete compact.session;
  return compact;
}

function sessionWorkspaceMeta(session: SessionListRow): string {
  const workspace = session.workspaceName ?? session.workspaceId;
  return workspace ? `workspace ${workspace}` : "";
}

function clipListCell(value: unknown, maxLength: number): string {
  const text = typeof value === "string" ? value.trim() : String(value ?? "");
  if (text.length <= maxLength) return text;
  return `${text.slice(0, Math.max(0, maxLength - 1))}…`;
}

type SessionListApiCall = <T>(path: string, options?: LocalApiRequestOptions) => Promise<T>;

async function resolveSessionWorkspaceId(id: string, call: SessionListApiCall): Promise<string> {
  const result = await call<{ session?: Partial<Session> }>(`/sessions/${encodeURIComponent(id)}`);
  const workspaceId = result.session?.workspaceId?.trim();
  if (!workspaceId) throw new Error("Session has no workspaceId");
  return workspaceId;
}

function normalizeStatusFilter(raw: string | undefined): string[] {
  return (raw ?? "")
    .split(",")
    .map((status) => status.trim())
    .filter(Boolean);
}

function isWorkspaceListStatusFilter(statuses: string[]): boolean {
  return statuses.every((status) => status === "active" || status === "stopped");
}

function sessionMatchesStatus(session: SessionListRow, statuses: string[]): boolean {
  if (statuses.length === 0) return true;
  return statuses.some((status) => {
    if (status === "active") return session.status !== "stopped";
    if (status === "stopped") return session.status === "stopped";
    return session.status === status;
  });
}

function parsePositiveLimit(raw: string | undefined): number | undefined {
  if (!raw) return undefined;
  const limit = Number.parseInt(raw, 10);
  if (!Number.isFinite(limit) || limit < 1) {
    throw new Error("--limit must be a positive integer");
  }
  return limit;
}

function activeWorkspaceRows(rows: SessionListRow[]): SessionListRow[] {
  return rows.filter((session) => session.status !== "stopped");
}

function stoppedWorkspaceRows(rows: SessionListRow[]): SessionListRow[] {
  return rows.filter((session) => session.status === "stopped");
}

function applySessionListClientFilters(
  sessions: SessionListRow[],
  flags: Record<string, string>,
): SessionListRow[] {
  const statuses = normalizeStatusFilter(flags.status);
  const limit = parsePositiveLimit(flags.limit);
  let filtered = sessions.filter((session) => sessionMatchesStatus(session, statuses));
  if (flags.worktree) {
    filtered = filtered.filter((session) => (session.worktreeId ?? "main") === flags.worktree);
  }
  if (limit !== undefined) {
    filtered = filtered.slice(0, limit);
  }
  return filtered;
}

async function listWorkspaceSessionsLikeApp(
  workspaceId: string,
  flags: Record<string, string>,
  call: SessionListApiCall,
): Promise<SessionListResponse & WorkspaceSessionCollectionResponse> {
  const statuses = normalizeStatusFilter(flags.status);
  const workspaceStatuses = statuses.length > 0 ? statuses : ["active", "stopped"];
  const nowMs = Date.now();
  const params = new URLSearchParams();
  params.set("status", workspaceStatuses.join(","));
  if (workspaceStatuses.includes("stopped")) {
    params.set("sinceMs", String(nowMs - DEFAULT_SESSION_LIST_RECENT_DAYS * DAY_MS));
    params.set("untilMs", String(nowMs + 1));
  }
  if (flags.worktree) params.set("worktreeId", flags.worktree);

  const response = await call<WorkspaceSessionCollectionResponse>(
    `/workspaces/${encodeURIComponent(workspaceId)}/sessions${querySuffix(params)}`,
  );
  const sessions = applySessionListClientFilters(
    [...(response.active ?? []), ...(response.stopped ?? [])],
    flags,
  );

  return {
    ...response,
    sessions,
    active: activeWorkspaceRows(sessions),
    stopped: stoppedWorkspaceRows(sessions),
  };
}

async function listRecentSessionsLikeApp(
  flags: Record<string, string>,
  call: SessionListApiCall,
): Promise<SessionListResponse> {
  const params = new URLSearchParams();
  params.set("recentDays", String(DEFAULT_SESSION_LIST_RECENT_DAYS));
  const response = await call<SessionListResponse>(`/sessions/recent${querySuffix(params)}`);
  return {
    ...response,
    sessions: applySessionListClientFilters(response.sessions ?? [], flags),
  };
}

async function listGenericSessions(
  flags: Record<string, string>,
  call: SessionListApiCall,
  workspaceId?: string,
): Promise<SessionListResponse> {
  const params = new URLSearchParams();
  if (workspaceId) params.set("workspaceId", workspaceId);
  if (flags.worktree) params.set("worktreeId", flags.worktree);
  if (flags.status) params.set("status", flags.status);
  if (flags.limit) params.set("limit", flags.limit);
  if (flags.agent) params.set("agentId", flags.agent);
  return call<SessionListResponse>(`/sessions${querySuffix(params)}`);
}

async function listSessions(
  storage: LocalApiConnection,
  flags: Record<string, string>,
  call: SessionListApiCall,
  hostResolvers: LocalApiHostResolvers,
): Promise<SessionListResponse> {
  const statuses = normalizeStatusFilter(flags.status);

  if (flags.workspace) {
    const workspaceId = await resolveWorkspaceIdForCli(storage, flags.workspace, hostResolvers);
    if (!flags.agent && isWorkspaceListStatusFilter(statuses)) {
      return listWorkspaceSessionsLikeApp(workspaceId, flags, call);
    }
    return listGenericSessions(flags, call, workspaceId);
  }

  if (!flags.agent) {
    return listRecentSessionsLikeApp(flags, call);
  }

  return listGenericSessions(flags, call);
}

type SessionInspectResult = {
  selected_turns: number[];
  view: SessionInspectView;
  summary: Record<string, unknown>;
  text: string;
};

async function inspectSession(
  id: string,
  positional: string[],
  flags: Record<string, string>,
  call: SessionListApiCall,
): Promise<SessionInspectResult> {
  const turnsSpec = flags.turns?.trim() || positional[0]?.trim() || "all";
  const view = inspectView(flags.view);

  if (view === "outline" || view === "overview" || view === "summary") {
    const sessionResult = await call<{ session?: Partial<Session> }>(
      `/sessions/${encodeURIComponent(id)}`,
    );
    const workspaceId = sessionResult.session?.workspaceId?.trim();
    if (!workspaceId) throw new Error("Session has no workspaceId");
    const outlineResult = await call<Record<string, unknown>>(
      `/workspaces/${encodeURIComponent(workspaceId)}/sessions/${encodeURIComponent(id)}/trace-outline`,
    );
    return buildInspectResult(
      sessionResult.session,
      traceEventsFromOutline(parseTraceOutlineEntries(outlineResult)),
      turnsSpec,
      view,
    );
  }

  // Response only needs conversational messages. Keep the full trace for views that explicitly
  // request message context or tools so their summary counts remain complete.
  const tracePath =
    view === "response"
      ? `/sessions/${encodeURIComponent(id)}/trace?include=messages`
      : `/sessions/${encodeURIComponent(id)}/trace`;
  const result = await call<{ session?: Partial<Session>; trace?: SessionTraceEvent[] }>(tracePath);
  if (!Array.isArray(result.trace)) throw new Error("Local API did not return a trace array");
  return buildInspectResult(result.session, result.trace, turnsSpec, view);
}

function buildInspectResult(
  session: Partial<Session> | undefined,
  trace: SessionTraceEvent[],
  turnsSpec: string,
  view: SessionInspectView,
): SessionInspectResult {
  const turns = buildInspectTurns(trace);
  const selectedTurns = parseInspectTurnSelector(turnsSpec, turns.length);
  const selectedSet = new Set(selectedTurns);
  const summary = inspectSummary(session, trace, turns);
  const text = renderInspectView(view, turns, selectedSet, summary);

  return {
    selected_turns: selectedTurns,
    view,
    summary,
    text,
  };
}

function inspectJsonResult(result: SessionInspectResult): Record<string, unknown> {
  if (result.view === "summary" || result.view === "overview") {
    return { view: result.view, summary: result.summary };
  }
  return {
    view: result.view,
    selected_turns: result.selected_turns,
    summary: result.summary,
    text: result.text,
  };
}

function inspectView(raw: string | undefined): SessionInspectView {
  const view = raw?.trim() || "outline";
  if (
    view === "overview" ||
    view === "outline" ||
    view === "response" ||
    view === "messages" ||
    view === "summary" ||
    view === "tools"
  ) {
    return view;
  }
  throw new Error("--view must be one of overview, outline, response, messages, summary, or tools");
}

function buildInspectTurns(trace: SessionTraceEvent[]): SessionInspectTurn[] {
  const turns: SessionInspectTurn[] = [];
  let current: SessionInspectTurn | undefined;
  // Pi TUI treats leading model/thinking/compaction entries as context metadata,
  // not as standalone user/assistant turns.
  const pendingLeadingSummaryTexts: string[] = [];
  const pendingLeadingSystemTexts: string[] = [];

  const attachPendingLeadingText = (turn: SessionInspectTurn): void => {
    if (pendingLeadingSummaryTexts.length > 0) {
      turn.summaryTexts.push(...pendingLeadingSummaryTexts);
      pendingLeadingSummaryTexts.length = 0;
    }
    if (pendingLeadingSystemTexts.length > 0) {
      turn.systemTexts.push(...pendingLeadingSystemTexts);
      pendingLeadingSystemTexts.length = 0;
    }
  };

  const ensureTurn = (): SessionInspectTurn => {
    if (!current) {
      current = emptyInspectTurn(turns.length + 1);
      attachPendingLeadingText(current);
      turns.push(current);
    }
    return current;
  };

  for (const event of trace) {
    const type = event.type ?? "";
    if (type === "user") {
      current = emptyInspectTurn(turns.length + 1);
      attachPendingLeadingText(current);
      const text = eventText(event).trim();
      if (text) current.userTexts.push(text);
      turns.push(current);
      continue;
    }

    if (!current && (type === "system" || type === "compaction")) {
      const text = eventText(event).trim();
      if (text && type === "system") pendingLeadingSystemTexts.push(text);
      if (text && type === "compaction") pendingLeadingSummaryTexts.push(text);
      continue;
    }

    const turn = ensureTurn();
    if (type === "assistant") {
      const text = eventText(event).trim();
      if (text) turn.assistantTexts.push(text);
    } else if (type === "thinking") {
      const text = typeof event.thinking === "string" ? event.thinking.trim() : "";
      if (text) turn.thinkingTexts.push(text);
    } else if (type === "system") {
      const text = eventText(event).trim();
      if (text) turn.systemTexts.push(text);
    } else if (type === "compaction") {
      const text = eventText(event).trim();
      if (text) turn.summaryTexts.push(text);
    } else if (type === "toolCall") {
      turn.toolCalls.push({
        ...(typeof event.id === "string" ? { id: event.id } : {}),
        ...(typeof event.tool === "string" ? { tool: event.tool } : {}),
        ...(event.args ? { args: event.args } : {}),
      });
    } else if (type === "toolResult") {
      turn.toolResults.push({
        ...(typeof event.toolName === "string" ? { toolName: event.toolName } : {}),
        ...(typeof event.output === "string" ? { output: event.output } : {}),
        ...(typeof event.isError === "boolean" ? { isError: event.isError } : {}),
      });
    }
  }

  if (!current && (pendingLeadingSummaryTexts.length > 0 || pendingLeadingSystemTexts.length > 0)) {
    current = emptyInspectTurn(turns.length + 1);
    attachPendingLeadingText(current);
    turns.push(current);
  }

  return turns;
}

function emptyInspectTurn(turn: number): SessionInspectTurn {
  return {
    turn,
    userTexts: [],
    assistantTexts: [],
    thinkingTexts: [],
    systemTexts: [],
    summaryTexts: [],
    toolCalls: [],
    toolResults: [],
  };
}

function parseInspectTurnSelector(spec: string, maxTurn: number): number[] {
  const trimmed = spec.trim().toLowerCase();
  if (!trimmed || trimmed === "all") {
    return Array.from({ length: maxTurn }, (_, index) => index + 1);
  }

  const selected = new Set<number>();
  const invalid = (): never => {
    throw new Error("--turns must be all, a number, a range, or a comma-separated list");
  };
  const requireInRange = (turn: number): void => {
    if (!Number.isSafeInteger(turn) || turn < 1 || turn > maxTurn) invalid();
  };

  for (const part of trimmed.split(",")) {
    const token = part.trim();
    if (!token) invalid();

    const range = token.match(/^(\d+)-(\d+)$/);
    if (range) {
      const start = Number.parseInt(range[1] ?? "", 10);
      const end = Number.parseInt(range[2] ?? "", 10);
      requireInRange(start);
      requireInRange(end);
      if (start > end) invalid();
      for (let turn = start; turn <= end; turn++) selected.add(turn);
      continue;
    }

    if (token.includes("-") || !/^\d+$/.test(token)) invalid();
    const turn = Number.parseInt(token, 10);
    requireInRange(turn);
    selected.add(turn);
  }

  if (selected.size === 0) invalid();
  return [...selected].sort((a, b) => a - b);
}

function inspectSummary(
  session: Partial<Session> | undefined,
  trace: SessionTraceEvent[],
  turns: SessionInspectTurn[],
): Record<string, unknown> {
  const assistantMessages = turns.reduce((sum, turn) => sum + turn.assistantTexts.length, 0);
  const userMessages = turns.reduce((sum, turn) => sum + turn.userTexts.length, 0);
  const thinkingMessages = turns.reduce((sum, turn) => sum + turn.thinkingTexts.length, 0);
  const toolCalls = turns.reduce((sum, turn) => sum + turn.toolCalls.length, 0);
  const toolResults = turns.reduce((sum, turn) => sum + turn.toolResults.length, 0);
  const toolErrors = turns.reduce(
    (sum, turn) => sum + turn.toolResults.filter((result) => result.isError === true).length,
    0,
  );

  return {
    source: "oppi",
    sessionId: session?.id,
    sessionName: session?.name,
    workspaceId: session?.workspaceId,
    worktreeId: session?.worktreeId,
    status: session?.status,
    model: session?.model,
    counts: {
      traceEvents: trace.length,
      turns: turns.length,
      userMessages,
      assistantMessages,
      thinkingMessages,
      toolCalls,
      toolResults,
      toolErrors,
    },
  };
}

function renderInspectView(
  view: SessionInspectView,
  turns: SessionInspectTurn[],
  selectedSet: Set<number>,
  summary: Record<string, unknown>,
): string {
  if (view === "overview") return renderInspectOverview(summary);
  if (view === "outline") return renderInspectOutline(turns, selectedSet);
  if (view === "response") return renderInspectResponse(turns, selectedSet);
  if (view === "summary") return JSON.stringify(summary, null, 2);
  if (view === "tools") return renderInspectTools(turns, selectedSet);
  return renderInspectMessages(turns, selectedSet);
}

function renderInspectOverview(summary: Record<string, unknown>): string {
  const counts = isRecord(summary.counts) ? summary.counts : {};
  return [
    `source: ${summary.source ?? "unknown"}`,
    `session: ${summary.sessionId ?? "unknown"}`,
    `name: ${summary.sessionName ?? "(none)"}`,
    `workspace: ${summary.workspaceId ?? "(unknown)"}`,
    `worktree: ${summary.worktreeId ?? "(unknown)"}`,
    `status: ${summary.status ?? "unknown"}`,
    `model: ${summary.model ?? "(unknown)"}`,
    `turns: ${counts.turns ?? 0}`,
    `trace_events: ${counts.traceEvents ?? 0}`,
    `assistant_messages: ${counts.assistantMessages ?? 0}`,
    `tool_calls: ${counts.toolCalls ?? 0}`,
    `tool_errors: ${counts.toolErrors ?? 0}`,
  ].join("\n");
}

function renderInspectOutline(turns: SessionInspectTurn[], selectedSet: Set<number>): string {
  const lines: string[] = [];
  for (const turn of turns) {
    if (!selectedSet.has(turn.turn)) continue;

    const userText = inspectDisplayText(
      turn.userTexts.find((text) => text.trim()) ?? "(no user message)",
    );
    const assistantText = inspectDisplayText(
      turn.assistantTexts.filter((text) => text.trim()).at(-1) ?? "(no response)",
    );
    const toolErrors = turn.toolResults.filter((result) => result.isError === true).length;
    const activity = [
      countLabel(turn.toolCalls.length, "tool call"),
      countLabel(toolErrors, "error"),
      countLabel(turn.thinkingTexts.length, "thinking block"),
      countLabel(turn.summaryTexts.length, "compaction"),
    ].filter(Boolean);

    lines.push(`Turn ${turn.turn}`);
    lines.push(`  user: ${clipListCell(userText, 180)}`);
    lines.push(`  assistant: ${clipListCell(assistantText, 180)}`);
    if (activity.length > 0) lines.push(`  activity: ${activity.join(" · ")}`);
    lines.push("");
  }

  return lines.length > 0 ? lines.join("\n").trimEnd() : "No turns found.";
}

function countLabel(count: number, singular: string): string {
  if (count === 0) return "";
  return `${count} ${singular}${count === 1 ? "" : "s"}`;
}

function renderInspectResponse(turns: SessionInspectTurn[], selectedSet: Set<number>): string {
  const response = turns
    .filter((turn) => selectedSet.has(turn.turn))
    .flatMap((turn) => turn.assistantTexts)
    .filter((text) => text.trim())
    .at(-1);
  return response ? inspectDisplayText(response) : "(no assistant response)";
}

function renderInspectMessages(turns: SessionInspectTurn[], selectedSet: Set<number>): string {
  const lines: string[] = [];
  for (const turn of turns) {
    if (!selectedSet.has(turn.turn)) continue;
    lines.push(`Turn ${turn.turn}`);
    for (const text of turn.summaryTexts) lines.push(`  summary: ${inspectDisplayText(text)}`);
    for (const text of turn.systemTexts) lines.push(`  system: ${inspectDisplayText(text)}`);
    for (const text of turn.userTexts) lines.push(`  user: ${inspectDisplayText(text)}`);
    for (const text of turn.assistantTexts) lines.push(`  assistant: ${inspectDisplayText(text)}`);
    for (const text of turn.thinkingTexts) lines.push(`  thinking: ${inspectDisplayText(text)}`);
    if (
      turn.summaryTexts.length === 0 &&
      turn.systemTexts.length === 0 &&
      turn.userTexts.length === 0 &&
      turn.assistantTexts.length === 0 &&
      turn.thinkingTexts.length === 0
    ) {
      lines.push("  (no text)");
    }
    lines.push("");
  }
  return lines.join("\n").trimEnd();
}

function inspectDisplayText(text: string): string {
  return text.replace(INLINE_DATA_URL_RE, (_match, contentType: string) => {
    return `[inline ${contentType} data omitted]`;
  });
}

function renderInspectTools(turns: SessionInspectTurn[], selectedSet: Set<number>): string {
  const lines: string[] = [];
  for (const turn of turns) {
    if (!selectedSet.has(turn.turn)) continue;
    lines.push(`Turn ${turn.turn}`);
    if (turn.toolCalls.length === 0 && turn.toolResults.length === 0) {
      lines.push("  (no tool calls)");
      lines.push("");
      continue;
    }
    for (const call of turn.toolCalls) {
      const args = call.args ? ` ${JSON.stringify(call.args)}` : "";
      lines.push(`  call: ${call.tool ?? "unknown"}${args}`);
    }
    for (const result of turn.toolResults) {
      const status = result.isError === true ? "error" : "ok";
      lines.push(
        `  result: ${result.toolName ?? "unknown"} [${status}] ${clipListCell(result.output ?? "", 220)}`,
      );
    }
    lines.push("");
  }
  return lines.join("\n").trimEnd();
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function parseTraceOutlineEntries(result: Record<string, unknown>): SessionTraceOutlineEntry[] {
  const outline = result.outline;
  if (!isRecord(outline) || !Array.isArray(outline.entries)) {
    throw new Error("Local API did not return a trace outline entries array");
  }

  return outline.entries.map((value) => {
    if (
      !isRecord(value) ||
      typeof value.id !== "string" ||
      typeof value.kind !== "string" ||
      typeof value.summary !== "string"
    ) {
      throw new Error("Local API returned an invalid trace outline entry");
    }
    return {
      id: value.id,
      kind: value.kind,
      summary: value.summary,
      ...(typeof value.timestamp === "string" ? { timestamp: value.timestamp } : {}),
      ...(typeof value.tool === "string" ? { tool: value.tool } : {}),
      ...(typeof value.isError === "boolean" ? { isError: value.isError } : {}),
    };
  });
}

function traceEventsFromOutline(entries: SessionTraceOutlineEntry[]): SessionTraceEvent[] {
  return entries.flatMap((entry): SessionTraceEvent[] => {
    switch (entry.kind) {
      case "user":
      case "assistant":
      case "system":
      case "compaction":
        return [{ id: entry.id, type: entry.kind, text: entry.summary }];
      case "thinking":
        return [{ id: entry.id, type: "thinking", thinking: entry.summary }];
      case "tool": {
        const call: SessionTraceEvent = {
          id: entry.id,
          type: "toolCall",
          ...(entry.tool ? { tool: entry.tool } : {}),
        };
        if (entry.isError === undefined) return [call];
        return [
          call,
          {
            type: "toolResult",
            ...(entry.tool ? { toolName: entry.tool } : {}),
            isError: entry.isError,
          },
        ];
      }
      default:
        return [];
    }
  });
}

function printTraceOutline(id: string, result: Record<string, unknown>): void {
  const entries = parseTraceOutlineEntries(result);

  printList(
    `Trace outline for ${id} (${entries.length})`,
    entries.map((entry) => ({
      id: entry.id,
      status: entry.kind,
      title: entry.summary,
      meta: [entry.tool ? `tool ${entry.tool}` : "", entry.isError === true ? "error" : ""],
    })),
    { empty: "No trace entries found." },
  );
}

function savedAgentReference(agent: string | undefined): string | undefined {
  const normalized = agent?.trim();
  if (!normalized || normalized === "default" || normalized === "workspace_default")
    return undefined;
  return normalized;
}

function eventText(event: SessionTraceEvent): string {
  if (typeof event.text === "string") return event.text;
  if (typeof event.message === "string") return event.message;
  return "";
}

// ─── Steering (send / abort) ───

type SessionSendKind = "prompt" | "steer" | "follow_up";

function resolveSendStreamingKind(
  flags: Record<string, string>,
): "steer" | "follow_up" | undefined {
  const steer = flags.steer === "true";
  const followUp = flags["follow-up"] === "true";
  if (steer && followUp) {
    throw new Error("--steer and --follow-up cannot be used together");
  }
  if (steer) return "steer";
  if (followUp) return "follow_up";
  return undefined;
}

// Compact, single-line session output. Agents parse --json; humans get the fact without framing.
function printSessionNotice(message: string): void {
  console.log(message);
}

async function sendSessionInput(
  id: string,
  commandType: SessionSendKind,
  text: string,
  call: SessionListApiCall,
): Promise<Record<string, unknown>> {
  try {
    return await call<Record<string, unknown>>(`/sessions/${encodeURIComponent(id)}/command`, {
      method: "POST",
      body: { type: commandType, message: text },
    });
  } catch (err) {
    // The runtime rejects a plain prompt on a streaming turn. Point the operator at the
    // steering flags that map to the runtime's steer/follow_up command types.
    if (commandType === "prompt" && err instanceof Error && /idle session/i.test(err.message)) {
      err.message = `${err.message}. Retry with --steer to interrupt the current turn or --follow-up to queue after it.`;
    }
    throw err;
  }
}

// ─── Extension UI dialogs (dialogs / respond) ───

type DialogOptionSummary = { value?: string; label?: string; description?: string };

type DialogQuestionSummary = {
  id?: string;
  question?: string;
  options?: DialogOptionSummary[];
  multiSelect?: boolean;
};

type DialogResponseMode = "answers" | "cancel" | "confirm" | "decline" | "option" | "text";

type DialogSnapshot = {
  id?: string;
  sessionId?: string;
  method?: string;
  title?: string;
  message?: string;
  placeholder?: string;
  prefill?: string;
  options?: string[];
  questions?: DialogQuestionSummary[];
  allowCustom?: boolean;
  timeout?: number;
  timeoutAt?: number;
};

function dialogPromptText(dialog: DialogSnapshot): string {
  const questions = dialog.questions ?? [];
  if (questions.length === 1) {
    return questions[0]?.question?.trim() || dialog.title?.trim() || "(dialog)";
  }
  if (questions.length > 1) {
    return `${questions.length} questions`;
  }
  return dialog.title?.trim() || dialog.message?.trim() || `(${dialog.method ?? "dialog"})`;
}

function dialogMetaLabels(dialog: DialogSnapshot): string[] {
  const labels: string[] = [];
  if (dialog.allowCustom === true) labels.push("free text allowed");
  if (dialog.allowCustom === false) labels.push("options only");
  if (typeof dialog.timeout === "number") {
    labels.push(`timeout ${Math.round(dialog.timeout / 1000)}s`);
  }
  return labels;
}

function dialogOptionLabel(option: DialogOptionSummary): string {
  const value = option.value ?? "";
  const label = option.label ?? "";
  if (value && label && value !== label) return `${value} — ${label}`;
  return value || label || "(option)";
}

function dialogOptionDetails(dialog: DialogSnapshot): string[] {
  const details: string[] = [];
  for (const question of dialog.questions ?? []) {
    if (question.id || question.question) {
      details.push(`${question.id ?? "?"}: ${question.question ?? ""}`.trim());
    }
    for (const option of question.options ?? []) {
      details.push(`  - ${dialogOptionLabel(option)}`);
    }
  }
  if ((dialog.options?.length ?? 0) > 0) {
    details.push(`options: ${(dialog.options ?? []).join(", ")}`);
  }
  if (dialog.placeholder) details.push(`placeholder: ${dialog.placeholder}`);
  return details;
}

function resolveDialogTarget(
  dialogs: DialogSnapshot[],
  requestedId: string | undefined,
): DialogSnapshot {
  if (requestedId) {
    const match = dialogs.find((dialog) => dialog.id === requestedId);
    if (!match) {
      throw new Error(
        `No pending dialog "${requestedId}"; run 'oppi session dialogs <id>' to list pending dialogs`,
      );
    }
    return match;
  }
  if (dialogs.length > 1) {
    throw new Error(`Multiple pending dialogs (${dialogs.length}); pass --dialog <requestId>`);
  }
  const only = dialogs[0];
  if (!only) {
    throw new Error("No pending dialogs to respond to");
  }
  return only;
}

function dialogResponseMode(flags: Record<string, string>): DialogResponseMode | undefined {
  const modes: DialogResponseMode[] = [];
  if (flags.answers !== undefined) modes.push("answers");
  if (flags.cancel === "true") modes.push("cancel");
  if (flags.confirm === "true") modes.push("confirm");
  if (flags.decline === "true") modes.push("decline");
  if (flags.option !== undefined) modes.push("option");
  if (flags.text !== undefined) modes.push("text");
  if (modes.length > 1) {
    throw new Error(
      `Choose one dialog response flag; received ${modes.map((mode) => `--${mode}`).join(", ")}`,
    );
  }
  return modes[0];
}

// Map operator flags onto the generic extension_ui_response payload {value, confirmed, cancelled}.
// Selection here is driven by the semantic protocol method (ask/select/confirm/input), never by
// concrete tool, extension, or widget names.
function buildDialogResponse(
  target: DialogSnapshot,
  flags: Record<string, string>,
): Record<string, unknown> {
  const id = target.id?.trim();
  if (!id) throw new Error("Pending dialog is missing a request id");

  const mode = dialogResponseMode(flags);
  const payload: Record<string, unknown> = { type: "extension_ui_response", id };
  if (mode === "cancel") {
    payload.cancelled = true;
    return payload;
  }

  if (target.method === "confirm") {
    if (mode !== "confirm" && mode !== "decline") {
      throw new Error("Confirm dialog requires --confirm, --decline, or --cancel");
    }
    payload.confirmed = mode === "confirm";
    return payload;
  }

  if (target.method === "ask") {
    payload.value = buildAskResponseValue(target, flags, mode);
    return payload;
  }

  if (target.method === "select") {
    if (mode !== "option") throw new Error("Select dialog requires --option or --cancel");
    const value = flags.option ?? "";
    if (!(target.options ?? []).includes(value)) {
      throw new Error(`Unknown option "${value}" for dialog ${id}`);
    }
    payload.value = value;
    return payload;
  }

  if (target.method === "input") {
    if (mode !== "text") throw new Error("Input dialog requires --text or --cancel");
    payload.value = flags.text ?? "";
    return payload;
  }

  throw new Error(`Unsupported pending dialog method: ${target.method ?? "unknown"}`);
}

function buildAskResponseValue(
  target: DialogSnapshot,
  flags: Record<string, string>,
  mode: DialogResponseMode | undefined,
): string {
  const questions = target.questions ?? [];
  if (mode === "answers") {
    const rawAnswers = flags.answers?.trim();
    let parsed: unknown;
    try {
      parsed = JSON.parse(rawAnswers ?? "");
    } catch {
      throw new Error("--answers must be a JSON object mapping question id to answer");
    }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error("--answers must be a JSON object mapping question id to answer");
    }
    validateAskAnswers(target, parsed as Record<string, unknown>);
    return JSON.stringify(parsed);
  }

  if (mode !== "option" && mode !== "text") {
    throw new Error(
      "Answering an ask dialog requires --text/--option, --answers <json>, or --cancel",
    );
  }
  if (questions.length !== 1) {
    throw new Error(
      `Ask dialog has ${questions.length} questions; pass --answers '{"questionId":"answer"}'`,
    );
  }
  const question = questions[0];
  const questionId = question?.id;
  if (!questionId) {
    throw new Error("Ask dialog question is missing an id; pass --answers <json>");
  }
  const value = mode === "option" ? (flags.option ?? "") : (flags.text ?? "");
  if (mode === "option" && !(question.options ?? []).some((option) => option.value === value)) {
    throw new Error(`Unknown option "${value}" for question ${questionId}`);
  }
  if (mode === "text" && target.allowCustom === false) {
    throw new Error(`Question ${questionId} only accepts listed options; use --option`);
  }
  return JSON.stringify({ [questionId]: question.multiSelect ? [value] : value });
}

function validateAskAnswers(target: DialogSnapshot, answers: Record<string, unknown>): void {
  const questions = new Map((target.questions ?? []).map((question) => [question.id, question]));
  for (const [questionId, answer] of Object.entries(answers)) {
    const question = questions.get(questionId);
    if (!question) throw new Error(`Unknown question id in --answers: ${questionId}`);
    const values = Array.isArray(answer) ? answer : [answer];
    if (values.some((value) => typeof value !== "string")) {
      throw new Error(`Answer for ${questionId} must be a string or string array`);
    }
    if (question.multiSelect !== true && Array.isArray(answer)) {
      throw new Error(`Answer for ${questionId} must be a single string`);
    }
    if (question.multiSelect === true && !Array.isArray(answer)) {
      throw new Error(`Answer for ${questionId} must be a string array`);
    }
    if (target.allowCustom === false) {
      const allowed = new Set((question.options ?? []).map((option) => option.value));
      const invalid = (values as string[]).find((value) => !allowed.has(value));
      if (invalid !== undefined) {
        throw new Error(`Unknown option "${invalid}" for question ${questionId}`);
      }
    }
  }
}

function assertNoCommandError(result: Record<string, unknown>, hintSteering = false): void {
  const messages = Array.isArray(result.messages) ? result.messages : [];
  for (const message of messages) {
    if (
      message &&
      typeof message === "object" &&
      (message as { type?: unknown }).type === "error"
    ) {
      const errorText = (message as { error?: unknown }).error;
      let detail = typeof errorText === "string" ? errorText : "Session command was rejected";
      if (hintSteering && /idle session/i.test(detail)) {
        detail = `${detail}. Retry with --steer to interrupt the current turn or --follow-up to queue after it.`;
      }
      throw new Error(detail);
    }
  }
}

// ─── Watch / wait (shared polling core) ───
//
// A single state machine drives both `wait` (one session, resolves on a condition, prints the
// terminal record) and `watch` (many sessions, streams one compact line per state transition).
// Status comes from the live events/catch-up stream so busy→ready is observed without a tight
// status poll; pending dialogs come from the per-session dialogs route only when the condition
// needs them. Tool counts and the last assistant snippet are derived from the events already
// fetched, never from tool/extension names.

type SessionWatchCondition = "idle" | "attention" | "either" | "any-change";
type SessionWatchReason = "idle" | "attention" | "change";

interface WatchSessionState {
  sinceSeq: number;
  status?: string;
  messageCount?: number;
  pendingDialogs?: number;
  toolsThisTurn: number;
  last?: string;
  seenBaseline: boolean;
  met: boolean;
}

interface WatchTransition {
  ts: number;
  sessionId: string;
  kind: "transition" | "resolved";
  reason?: SessionWatchReason;
  prevStatus?: string;
  status?: string;
  messageCount?: number;
  toolsThisTurn: number;
  last?: string;
  pendingDialogs?: number;
}

type WatchOutcome =
  | {
      kind: "session";
      sessionId: string;
      reason: SessionWatchReason;
      status?: string;
      pendingDialogs?: number;
    }
  | {
      kind: "all";
      condition: SessionWatchCondition;
      sessions: Array<{ sessionId: string; status?: string; pendingDialogs?: number }>;
    };

interface WatchOptions {
  condition: SessionWatchCondition;
  requireAll: boolean;
  intervalMs: number;
  timeoutMs: number;
}

class SessionWatchTimeout extends Error {
  constructor(
    readonly condition: SessionWatchCondition,
    readonly pending: string[],
  ) {
    const target = pending.length === 1 ? `session ${pending[0]}` : `${pending.length} sessions`;
    super(`Timed out waiting for ${target} to reach ${condition}`);
    this.name = "SessionWatchTimeout";
  }
}

function parseWatchCondition(
  raw: string | undefined,
  fallback: SessionWatchCondition,
): SessionWatchCondition {
  const value = raw?.trim().toLowerCase();
  if (!value) return fallback;
  if (value === "idle" || value === "attention" || value === "either") return value;
  if (value === "any-change") return "any-change";
  throw new Error("condition must be idle, attention, either, or any-change");
}

function isIdleSessionStatus(status: string | undefined): boolean {
  // A turn has settled once the runtime leaves the working states. Terminal stopped/error
  // sessions also count as idle so a supervisor wait resolves instead of timing out.
  return status === "ready" || status === "stopped" || status === "error";
}

async function observeSession(
  id: string,
  state: WatchSessionState,
  needDialogs: boolean,
  call: SessionListApiCall,
): Promise<{ activityChanged: boolean; stateChanged: boolean }> {
  const prevStatus = state.status;
  const prevPending = state.pendingDialogs;
  const prevSeq = state.sinceSeq;
  const prevMessageCount = state.messageCount;
  const prevTools = state.toolsThisTurn;
  const prevLast = state.last;
  let status: string | undefined;

  try {
    const events = await call<{
      session?: { status?: string; messageCount?: number; lastMessage?: string };
      events?: Array<Record<string, unknown>>;
      currentSeq?: number;
    }>(`/sessions/${encodeURIComponent(id)}/events?since=${state.sinceSeq}`);
    status = events.session?.status;
    if (typeof events.session?.messageCount === "number") {
      state.messageCount = events.session.messageCount;
    }
    if (typeof events.currentSeq === "number") state.sinceSeq = events.currentSeq;
    for (const event of events.events ?? []) {
      const type = event.type;
      if (type === "agent_start") state.toolsThisTurn = 0;
      else if (type === "tool_start") state.toolsThisTurn += 1;
      else if (type === "message_end" && event.role === "assistant") {
        const content = event.content;
        if (typeof content === "string" && content.trim()) state.last = content.trim();
      }
    }
    if (!state.last && typeof events.session?.lastMessage === "string") {
      state.last = events.session.lastMessage;
    }
  } catch (err) {
    if (apiStatus(err) === 404) {
      const snapshot = await call<{
        session?: { status?: string; messageCount?: number; lastMessage?: string };
      }>(`/sessions/${encodeURIComponent(id)}`);
      status = snapshot.session?.status;
      if (typeof snapshot.session?.messageCount === "number") {
        state.messageCount = snapshot.session.messageCount;
      }
      if (!state.last && typeof snapshot.session?.lastMessage === "string") {
        state.last = snapshot.session.lastMessage;
      }
    } else {
      throw err;
    }
  }

  state.status = status;
  if (needDialogs) {
    const list = await call<{ dialogs?: unknown[] }>(`/sessions/${encodeURIComponent(id)}/dialogs`);
    state.pendingDialogs = Array.isArray(list.dialogs) ? list.dialogs.length : 0;
  }

  const stateChanged = state.status !== prevStatus || state.pendingDialogs !== prevPending;
  return {
    stateChanged,
    activityChanged:
      stateChanged ||
      state.sinceSeq !== prevSeq ||
      state.messageCount !== prevMessageCount ||
      state.toolsThisTurn !== prevTools ||
      state.last !== prevLast,
  };
}

function evaluateWatchCondition(
  condition: SessionWatchCondition,
  state: WatchSessionState,
  isBaseline: boolean,
  activityChanged: boolean,
): SessionWatchReason | undefined {
  if (condition === "any-change") {
    return !isBaseline && activityChanged ? "change" : undefined;
  }
  const idle = isIdleSessionStatus(state.status);
  const attention = (state.pendingDialogs ?? 0) > 0;
  if (condition === "idle") return idle ? "idle" : undefined;
  if (condition === "attention") return attention ? "attention" : undefined;
  if (attention) return "attention";
  return idle ? "idle" : undefined;
}

function buildWatchTransition(
  id: string,
  state: WatchSessionState,
  kind: "transition" | "resolved",
  prevStatus: string | undefined,
  reason?: SessionWatchReason,
): WatchTransition {
  return {
    ts: Date.now(),
    sessionId: id,
    kind,
    ...(reason !== undefined ? { reason } : {}),
    ...(prevStatus !== undefined ? { prevStatus } : {}),
    ...(state.status !== undefined ? { status: state.status } : {}),
    ...(state.messageCount !== undefined ? { messageCount: state.messageCount } : {}),
    toolsThisTurn: state.toolsThisTurn,
    ...(state.last !== undefined ? { last: state.last } : {}),
    ...(state.pendingDialogs !== undefined ? { pendingDialogs: state.pendingDialogs } : {}),
  };
}

async function runSessionWatch(
  ids: string[],
  options: WatchOptions,
  call: SessionListApiCall,
  emit: (transition: WatchTransition) => void,
): Promise<WatchOutcome> {
  if (options.intervalMs < 1) throw new Error("--interval must be a positive duration");
  if (options.timeoutMs < 1) throw new Error("--timeout must be a positive duration");
  const needDialogs = options.condition !== "idle";
  const states = new Map<string, WatchSessionState>();
  for (const id of ids) {
    states.set(id, {
      sinceSeq: 0,
      toolsThisTurn: 0,
      seenBaseline: false,
      met: false,
    });
  }
  const deadline = Date.now() + options.timeoutMs;

  for (;;) {
    for (const id of ids) {
      const state = states.get(id);
      if (!state) continue;
      const prevStatus = state.status;
      const { activityChanged, stateChanged } = await observeSession(id, state, needDialogs, call);
      const isBaseline = !state.seenBaseline;
      state.seenBaseline = true;
      const reason = evaluateWatchCondition(options.condition, state, isBaseline, activityChanged);
      state.met =
        options.condition === "any-change"
          ? state.met || reason !== undefined
          : reason !== undefined;
      if (reason && !options.requireAll) {
        emit(buildWatchTransition(id, state, "resolved", prevStatus, reason));
        return {
          kind: "session",
          sessionId: id,
          reason,
          ...(state.status !== undefined ? { status: state.status } : {}),
          ...(state.pendingDialogs !== undefined ? { pendingDialogs: state.pendingDialogs } : {}),
        };
      }
      if (
        !isBaseline &&
        (stateChanged || (options.condition === "any-change" && activityChanged))
      ) {
        emit(buildWatchTransition(id, state, "transition", prevStatus));
      }
    }

    if (options.requireAll && ids.every((id) => states.get(id)?.met)) {
      return {
        kind: "all",
        condition: options.condition,
        sessions: ids.map((id) => {
          const state = states.get(id);
          return {
            sessionId: id,
            ...(state?.status !== undefined ? { status: state.status } : {}),
            ...(state?.pendingDialogs !== undefined
              ? { pendingDialogs: state.pendingDialogs }
              : {}),
          };
        }),
      };
    }

    if (Date.now() >= deadline) {
      throw new SessionWatchTimeout(
        options.condition,
        ids.filter((id) => !states.get(id)?.met),
      );
    }
    await sleep(Math.min(options.intervalMs, Math.max(0, deadline - Date.now())));
  }
}

function clipWatchSnippet(text: string, budget: number): string {
  const oneLine = text.replace(/\s+/g, " ").trim();
  if (oneLine.length <= budget) return oneLine;
  return `${oneLine.slice(0, Math.max(0, budget - 1))}…`;
}

function formatWatchTransitionLine(transition: WatchTransition): string {
  const time = new Date(transition.ts).toTimeString().slice(0, 8);
  const state =
    transition.prevStatus === undefined
      ? `status=${transition.status ?? "?"}`
      : `${transition.prevStatus}→${transition.status ?? "?"}`;
  const reason = transition.reason ? ` reason=${transition.reason}` : "";
  const dialogs =
    transition.pendingDialogs !== undefined ? ` dialogs=${transition.pendingDialogs}` : "";
  const prefix = `${time} ${transition.sessionId} ${state}${reason} tools=${transition.toolsThisTurn}${dialogs}`;
  if (!transition.last) return prefix;
  const budget = Math.max(8, 100 - prefix.length - 9);
  return `${prefix} last='${clipWatchSnippet(transition.last, budget)}'`;
}

function watchTransitionJson(transition: WatchTransition): Record<string, unknown> {
  return {
    event: transition.kind,
    ts: transition.ts,
    session_id: transition.sessionId,
    ...(transition.reason !== undefined ? { reason: transition.reason } : {}),
    ...(transition.prevStatus !== undefined ? { prev: transition.prevStatus } : {}),
    status: transition.status ?? null,
    tool_calls: transition.toolsThisTurn,
    ...(transition.pendingDialogs !== undefined
      ? { pending_dialogs: transition.pendingDialogs }
      : {}),
    ...(transition.messageCount !== undefined ? { message_count: transition.messageCount } : {}),
    ...(transition.last !== undefined ? { last: clipWatchSnippet(transition.last, 200) } : {}),
  };
}

function watchResolvedJson(
  outcome: Extract<WatchOutcome, { kind: "all" }>,
): Record<string, unknown> {
  return {
    event: "resolved",
    all: true,
    condition: outcome.condition,
    sessions: outcome.sessions.map((session) => ({
      session_id: session.sessionId,
      status: session.status ?? null,
      ...(session.pendingDialogs !== undefined ? { pending_dialogs: session.pendingDialogs } : {}),
    })),
  };
}

function formatWatchResolved(outcome: Extract<WatchOutcome, { kind: "all" }>): string {
  return `all ${outcome.sessions.length} sessions reached ${outcome.condition}`;
}

async function watchSessions(
  positional: string[],
  flags: Record<string, string>,
  jsonOutput: boolean,
  call: SessionListApiCall,
): Promise<void> {
  const ids = positional.map((value) => value.trim()).filter(Boolean);
  if (ids.length === 0) throw new Error("at least one session id is required");
  if (new Set(ids).size !== ids.length) throw new Error("session ids must be unique");
  const condition = parseWatchCondition(flags.until, "idle");
  if (condition === "either") {
    throw new Error("--until must be idle, attention, or any-change");
  }
  const emit = (transition: WatchTransition): void => {
    if (jsonOutput) process.stdout.write(`${JSON.stringify(watchTransitionJson(transition))}\n`);
    else console.log(formatWatchTransitionLine(transition));
  };

  try {
    const outcome = await runSessionWatch(
      ids,
      {
        condition,
        requireAll: flags.all === "true",
        intervalMs: parseDurationMs(flags.interval ?? "2s"),
        timeoutMs: parseDurationMs(flags.timeout ?? "30m"),
      },
      call,
      emit,
    );
    if (outcome.kind === "all") {
      if (jsonOutput) process.stdout.write(`${JSON.stringify(watchResolvedJson(outcome))}\n`);
      else console.log(formatWatchResolved(outcome));
    }
  } catch (err) {
    if (err instanceof SessionWatchTimeout) {
      if (jsonOutput) {
        process.stdout.write(
          `${JSON.stringify({ event: "timeout", condition: err.condition, pending: err.pending })}\n`,
        );
      } else {
        console.log(c.red(`timeout: ${err.message}`));
      }
      process.exitCode = 1;
      return;
    }
    if (jsonOutput) {
      const message = err instanceof Error ? err.message : String(err);
      const status = apiStatus(err);
      process.stdout.write(
        `${JSON.stringify({ event: "error", message, ...(status ? { status } : {}) })}\n`,
      );
      process.exitCode = 1;
      return;
    }
    throw err;
  }
}

async function sleep(ms: number): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, ms));
}
