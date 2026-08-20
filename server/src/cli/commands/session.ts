/* eslint-disable no-console */
import { readFileSync } from "node:fs";
import * as c from "../../ansi.js";
import type { Session } from "../../types.js";
import {
  localApiRequest,
  throwIfAborted,
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
import { resolveThinkingFromFlags, resolveToolPolicyFromFlags } from "../launch-flags.js";
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
  formatSessionListRelativeTime,
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
import { attributeManagedSessionMessage } from "../managed-session-message.js";
import type { SandboxOppiScope } from "../../sandbox-oppi-policy.js";
import {
  assertNoCommandError,
  printSessionNotice,
  resolveSendStreamingKind,
  sendSessionInput,
} from "./session-interactions.js";
import {
  parseWatchCondition,
  runSessionWatch,
  WAIT_DEFAULT_POLL,
  WAIT_DEFAULT_SUMMARY_EVERY,
  type WaitProgressSnapshot,
} from "./session-watch.js";

type SessionListApiCall = <T>(path: string, options?: LocalApiRequestOptions) => Promise<T>;
type SessionCliOutput = (data: Record<string, unknown>, human: () => void) => void;

export interface SessionCliCallerContext {
  /** Immutable for one in-process command; shell callers continue using the environment fallback. */
  callerSessionId?: string;
  /** Present only for sandbox-scoped Oppi tool calls. */
  sandboxScope?: SandboxOppiScope;
  /** Cancels long-running in-process session commands such as wait polling. */
  signal?: AbortSignal;
  /** UI-only wait snapshots. Not printed on the human CLI. */
  onLiveSnapshot?: (text: string) => void;
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

  const { call, output } = createLocalApiCommandContext(storage, jsonOutput, callerContext.signal);

  try {
    flags = normalizeSessionFlagAliases(mode, flags);
    assertSessionFlags(mode, flags);
    const callerSessionId = callerContext.callerSessionId ?? callerSessionIdFromEnvironment();
    assertNotSelfTargetingSession(sessionTargetsForMode(mode, positional), callerSessionId);
    if (callerContext.sandboxScope) {
      await assertSandboxScopeTargets(
        call,
        callerContext.sandboxScope,
        sessionTargetsForMode(mode, positional),
      );
    }

    if (mode === "list") {
      const result = await listSessions(storage, flags, call);
      const sessions = Array.isArray(result.sessions) ? result.sessions : [];
      output({ sessions: sessions.map(compactSessionListRow) }, () => {
        const nowMs =
          typeof result.serverNow === "number" && Number.isFinite(result.serverNow)
            ? result.serverNow
            : Date.now();
        printList(
          `Sessions (${sessions.length})`,
          sessions.map((session) => {
            const path = clipListCell(session.path ?? session.piSessionFile ?? "", 56);
            const activity = session.lastActivity ?? session.lastModified;
            const relativeActivity =
              typeof activity === "number" ? formatSessionListRelativeTime(activity, nowMs) : "";
            return {
              id: session.id ?? "?",
              status: session.status ?? "?",
              title: clipListCell(session.name ?? session.firstMessage ?? "(unnamed)", 88),
              meta: [
                sessionWorkspaceMeta(session),
                `worktree ${session.worktreeId ?? "main"}`,
                relativeActivity,
              ],
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
      const text = attributeManagedSessionMessage(
        resolvePromptInput(flags.text, "--text"),
        callerSessionId,
      );
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

    if (mode === "wait") {
      const ids = positional.map((value) => value.trim()).filter(Boolean);
      if (ids.length === 0) throw new Error("session id is required");
      if (new Set(ids).size !== ids.length) throw new Error("session ids must be unique");
      const condition = parseWatchCondition(flags.for, "either");
      if (condition === "any-change") {
        throw new Error("--for must be idle, attention, or either");
      }
      const requireAll = flags.all === "true" && ids.length > 1;
      const progress: WaitProgressSnapshot[] = [];
      const summaryEveryMs = parseDurationMs(flags["summary-every"] ?? WAIT_DEFAULT_SUMMARY_EVERY);
      const outcome = await runSessionWatch(
        ids,
        {
          condition,
          requireAll,
          intervalMs: parseDurationMs(flags.poll ?? WAIT_DEFAULT_POLL),
          timeoutMs: parseDurationMs(flags.timeout ?? "10m"),
          summaryEveryMs,
          onSummary: (snapshot) => {
            if (progress.length < 50) progress.push(snapshot);
            if (!jsonOutput) writeHumanLine(formatWaitProgress(snapshot));
          },
          ...(callerContext.onLiveSnapshot
            ? { onLiveSnapshot: callerContext.onLiveSnapshot }
            : {}),
          ...(callerContext.signal ? { signal: callerContext.signal } : {}),
        },
        call,
        () => {},
      );
      throwIfAborted(callerContext.signal);
      const progressJson =
        progress.length > 0 ? { progress: progress.map(progressJsonSnapshot) } : {};
      if (outcome.kind === "all") {
        output(
          {
            condition: outcome.condition,
            sessions: outcome.sessions.map((session) => ({
              session_id: session.sessionId,
              status: session.status ?? null,
              ...(session.pendingDialogs !== undefined
                ? { pending_dialogs: session.pendingDialogs }
                : {}),
            })),
            ...progressJson,
          },
          () => {
            printDetails("✓ Wait condition met", [
              ["Condition", outcome.condition],
              ["Sessions", outcome.sessions.length],
            ]);
            printList(
              "Sessions",
              outcome.sessions.map((session) => ({
                id: session.sessionId,
                status: session.status ?? "unknown",
                title: session.sessionId,
              })),
            );
          },
        );
        return;
      }
      const status = outcome.status ?? null;
      const reason = outcome.reason;
      const pendingDialogs = outcome.pendingDialogs;
      const outputDelta = outcome.outputDelta;
      const outputDeltaKind = outcome.outputDeltaKind;
      output(
        {
          session_id: outcome.sessionId,
          reason,
          status,
          ...(pendingDialogs !== undefined ? { pending_dialogs: pendingDialogs } : {}),
          ...(outputDelta !== undefined ? { output_delta: outputDelta } : {}),
          ...(outputDeltaKind !== undefined ? { output_delta_kind: outputDeltaKind } : {}),
          ...progressJson,
        },
        () => {
          const waitDetails: [string, unknown][] = [
            ["Session", codeValue(outcome.sessionId)],
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
      "Usage: oppi session list|get|create|send|abort|wait|read|events|trace|search|inspect|stop|resume|fork|delete|tool-output|trace-page|trace-outline",
    );
  } catch (err: unknown) {
    if (callerContext.signal?.aborted) throw err;
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
  const toolPolicy = resolveToolPolicyFromFlags(flags);
  const workspaceId = await resolveWorkspaceIdForCli(storage, workspaceRef);
  const prompt = attributeManagedSessionMessage(promptText, parentSessionId);
  const resolvedModel = await resolveModelFlagForCli(storage, flags.model);
  const thinking = resolveThinkingFromFlags(flags, resolvedModel?.thinkingLevel);
  const savedAgent = savedAgentReference(flags.agent);
  const allowNestedDelegation = flags["allow-nested-delegation"] === "true";
  const result = savedAgent
    ? await localApiRequest<{ session: Session; receipt?: Record<string, unknown> }>(
        storage,
        `/agents/${encodeURIComponent(savedAgent)}/sessions`,
        {
          method: "POST",
          body: {
            prompt: { text: prompt },
            target: {
              workspaceId,
              ...(flags.worktree ? { worktreeId: flags.worktree } : {}),
            },
            ...(flags.name ? { sessionName: flags.name } : {}),
            ...(resolvedModel || thinking || hasToolPolicy(toolPolicy)
              ? {
                  overrides: {
                    ...(resolvedModel ? { model: resolvedModel.canonicalId } : {}),
                    ...(thinking ? { thinkingLevel: thinking } : {}),
                    ...toolPolicy,
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
            prompt: prompt,
            ...(flags.name ? { name: flags.name } : {}),
            ...(resolvedModel ? { model: resolvedModel.canonicalId } : {}),
            ...(thinking ? { thinking } : {}),
            ...toolPolicy,
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
  list: ["agent", "json", "limit", "since", "status", "until", "workspace", "worktree"],
  get: ["json"],
  create: [
    "agent",
    "allow-nested-delegation",
    "exclude-tools",
    "idempotency-key",
    "json",
    "model",
    "name",
    "no-builtin-tools",
    "no-tools",
    "prompt",
    "thinking",
    "tools",
    "workspace",
    "worktree",
  ],
  send: ["follow-up", "json", "steer", "text"],
  abort: ["json"],
  wait: ["all", "for", "interval", "json", "poll", "summary-every", "timeout"],
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
        ? ([
            ["until", "for"],
            ["interval", "poll"],
          ] as const)
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

async function assertSandboxScopeTargets(
  call: SessionListApiCall,
  scope: SandboxOppiScope,
  targetSessionIds: readonly string[],
): Promise<void> {
  for (const targetId of targetSessionIds) {
    const targetResult = await call<{ session?: { workspaceId?: string } }>(
      `/sessions/${encodeURIComponent(targetId)}`,
    );
    const targetWorkspaceId = targetResult.session?.workspaceId?.trim();
    if (!targetWorkspaceId) {
      throw new Error("Sandbox Oppi could not verify the target stays in this workspace");
    }
    if (targetWorkspaceId !== scope.workspaceId) {
      throw new Error("Sandbox Oppi can only target sessions in this sandbox workspace");
    }
  }
}

function sessionTargetsForMode(mode: string, positional: string[]): string[] {
  if (mode === "wait") {
    return positional.map((value) => value.trim()).filter(Boolean);
  }
  if (
    [
      "get",
      "send",
      "abort",
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

function formatWaitProgress(snapshot: WaitProgressSnapshot): string {
  const elapsed = Math.max(1, Math.round(snapshot.elapsedMs / 1000));
  const rows = snapshot.sessions.map((session) => {
    const dialogs =
      session.pendingDialogs !== undefined ? ` dialogs=${session.pendingDialogs}` : "";
    return `    ${session.sessionId}  ${session.status ?? "?"}  tools=${session.toolsThisTurn}${dialogs}`;
  });
  return [`  still waiting (${elapsed}s)`, ...rows].join("\n");
}

function progressJsonSnapshot(snapshot: WaitProgressSnapshot): Record<string, unknown> {
  return {
    ts: snapshot.ts,
    elapsed_ms: snapshot.elapsedMs,
    sessions: snapshot.sessions.map((session) => ({
      session_id: session.sessionId,
      status: session.status ?? null,
      tools_this_turn: session.toolsThisTurn,
      ...(session.pendingDialogs !== undefined ? { pending_dialogs: session.pendingDialogs } : {}),
    })),
  };
}

function hasToolPolicy(policy: {
  tools?: string[];
  excludeTools?: string[];
  noTools?: "all" | "builtin";
}): boolean {
  return (
    policy.tools !== undefined || policy.excludeTools !== undefined || policy.noTools !== undefined
  );
}
