/* eslint-disable no-console */
import { readFileSync } from "node:fs";
import * as c from "../../ansi.js";
import type { Session } from "../../types.js";
import {
  localApiRequest,
  type LocalApiConnection,
  type LocalApiRequestOptions,
} from "../local-api-client.js";
import {
  codeValue,
  nonEmptyDetails,
  printDetails,
  printList,
  printTextBlock,
  setCapturedCliExitCode,
  writeHumanLine,
  writeJsonEnvelope,
} from "../output.js";
import { inferWorkspaceIdFromCwdForCli, resolveWorkspaceIdForCli } from "../resources.js";
import { resolveModelFlagForCli } from "../model-resolution.js";
import { createLocalApiCommandContext, handleModelResolvingCliError } from "../command-support.js";
import {
  assertNotSelfTargetingSession,
  callerSessionIdFromEnvironment,
} from "../../session-caller-identity.js";
import { parseDurationMs } from "./wait.js";
import {
  clipListCell,
  compactSessionListRow,
  listSessions,
  sessionWorkspaceMeta,
} from "./session-list.js";
import {
  eventText,
  inspectJsonResult,
  inspectSession,
  printTraceOutline,
  type SessionTraceEvent,
} from "./session-inspect.js";
import {
  assertNoCommandError,
  buildDialogResponse,
  type DialogSnapshot,
  dialogMetaLabels,
  dialogOptionDetails,
  dialogPromptText,
  printSessionNotice,
  resolveDialogTarget,
  resolveSendStreamingKind,
  sendSessionInput,
} from "./session-interactions.js";
import { parseWatchCondition, runSessionWatch, watchSessions } from "./session-watch.js";

type SessionListApiCall = <T>(path: string, options?: LocalApiRequestOptions) => Promise<T>;
type SessionCliOutput = (data: Record<string, unknown>, human: () => void) => void;

export interface SessionCliCallerContext {
  /** Immutable for one in-process command; shell callers continue using the environment fallback. */
  callerSessionId?: string;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

export async function cmdSession(
  storage: LocalApiConnection,
  action: string | undefined,
  positional: string[],
  flags: Record<string, string>,
  cwd = process.cwd(),
  callerContext: SessionCliCallerContext = {},
): Promise<void> {
  const requestedMode = action || "list";
  const mode = requestedMode === "start" ? "create" : requestedMode;
  const jsonOutput = flags.json === "true";

  const { call, output } = createLocalApiCommandContext(storage, jsonOutput);

  try {
    flags = normalizeSessionFlagAliases(mode, flags);
    assertSessionFlags(mode, flags);
    const callerSessionId = callerContext.callerSessionId ?? callerSessionIdFromEnvironment();
    assertNotSelfTargetingSession(sessionTargetsForMode(mode, positional), callerSessionId);

    if (mode === "list") {
      const result = await listSessions(storage, flags, call);
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
      await createSession(storage, flags, jsonOutput, output, callerSessionId);
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
      const outputDelta = outcome.kind === "session" ? outcome.outputDelta : undefined;
      const outputDeltaKind = outcome.kind === "session" ? outcome.outputDeltaKind : undefined;
      output(
        {
          session_id: id,
          reason,
          status,
          ...(pendingDialogs !== undefined ? { pending_dialogs: pendingDialogs } : {}),
          ...(outputDelta !== undefined ? { output_delta: outputDelta } : {}),
          ...(outputDeltaKind !== undefined ? { output_delta_kind: outputDeltaKind } : {}),
        },
        () => {
          const waitDetails: [string, unknown][] = [
            ["Session", codeValue(id)],
            ["Reason", reason],
            ["Status", status ?? "unknown"],
          ];
          if (pendingDialogs !== undefined) waitDetails.push(["Dialogs", pendingDialogs]);
          printDetails("✓ Wait condition met", waitDetails);
          if (outputDelta) {
            printTextBlock(
              outputDeltaKind === "delta" ? "Output delta" : "Latest output",
              outputDelta,
            );
          }
        },
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
        const workspaceId = await resolveWorkspaceIdForCli(storage, flags.workspace);
        params.set("workspaceId", workspaceId);
      } else if (flags.all !== "true") {
        const workspaceId = await inferWorkspaceIdFromCwdForCli(storage, cwd);
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
        writeHumanLine(result.text || "(empty)");
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
      "Usage: oppi session list|get|create|send|abort|dialogs|respond|watch|wait|read|events|trace|search|inspect|stop|resume|fork|delete|tool-output|trace-page|trace-outline",
    );
  } catch (err: unknown) {
    handleModelResolvingCliError(err, jsonOutput);
  }
}

async function createSession(
  storage: LocalApiConnection,
  flags: Record<string, string>,
  jsonOutput: boolean,
  output: SessionCliOutput,
  parentSessionId?: string,
): Promise<void> {
  const workspaceRef = flags.workspace?.trim();
  const promptText =
    flags.prompt === undefined ? undefined : resolvePromptInput(flags.prompt, "--prompt");
  if (!workspaceRef || promptText === undefined) {
    const message = "--workspace and --prompt are required";
    if (jsonOutput) {
      writeJsonEnvelope({ ok: false, error: { message } });
      setCapturedCliExitCode(1);
    } else {
      console.log(c.red(`  Error: ${message}`));
      console.log(c.dim("  Usage: oppi session create --workspace <id> --prompt <text> [--json]"));
      process.exitCode = 1;
    }
    return;
  }
  const workspaceId = await resolveWorkspaceIdForCli(storage, workspaceRef);
  const resolvedModel = await resolveModelFlagForCli(storage, flags.model);
  const savedAgent = savedAgentReference(flags.agent);
  const allowNestedDelegation = flags["allow-nested-delegation"] === "true";
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
            ...(parentSessionId ? { parentSessionId } : {}),
            ...(allowNestedDelegation ? { allowNestedDelegation: true } : {}),
            ...(flags["idempotency-key"] ? { idempotencyKey: flags["idempotency-key"] } : {}),
          },
        },
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
            ...(parentSessionId ? { parentSessionId } : {}),
            ...(allowNestedDelegation ? { allowNestedDelegation: true } : {}),
            ...(flags["idempotency-key"] ? { launchIdempotencyKey: flags["idempotency-key"] } : {}),
          },
        },
      );
  output({ session_id: result.session.id }, () =>
    printSessionNotice(`session ${result.session.id} created in ${workspaceId}`),
  );
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
    "allow-nested-delegation",
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

function sessionTargetsForMode(mode: string, positional: string[]): string[] {
  if (mode === "watch") return positional.map((value) => value.trim()).filter(Boolean);
  if (
    [
      "get",
      "send",
      "abort",
      "dialogs",
      "respond",
      "wait",
      "read",
      "events",
      "trace",
      "inspect",
      "stop",
      "delete",
      "resume",
      "fork",
      "tool-output",
      "trace-page",
      "trace-outline",
    ].includes(mode)
  ) {
    const id = positional[0]?.trim();
    return id ? [id] : [];
  }
  return [];
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

async function resolveSessionWorkspaceId(id: string, call: SessionListApiCall): Promise<string> {
  const result = await call<{ session?: Partial<Session> }>(`/sessions/${encodeURIComponent(id)}`);
  const workspaceId = result.session?.workspaceId?.trim();
  if (!workspaceId) throw new Error("Session has no workspaceId");
  return workspaceId;
}

function savedAgentReference(agent: string | undefined): string | undefined {
  const normalized = agent?.trim();
  if (!normalized || normalized === "default" || normalized === "workspace_default")
    return undefined;
  return normalized;
}
