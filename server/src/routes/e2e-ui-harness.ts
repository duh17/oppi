import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { realpathSync } from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

import {
  clearRecordedE2EUIResponses,
  getRecordedE2EUIResponses,
  recordSyntheticE2EUIRequest,
} from "../e2e-ui-harness-state.js";
import {
  buildExtensionUINotificationMessage,
  buildExtensionUIRequestMessage,
  normalizeExtensionUIWidgetNativeSurface,
} from "../extension-ui-contract.js";
import { discoverLocalSessions, getPiSessionsRoot } from "../local-sessions.js";
import { hasToolMediaDetails } from "../session-agent-event-media.js";
import { materializeToolMediaDetails } from "../session-attachments.js";
import type { AskQuestion, ServerMessage } from "../types.js";
import type { RouteDispatcher, RouteHelpers, RouteContext } from "./types.js";

const MAX_E2E_UI_MESSAGE_BYTES = 2 * 1024 * 1024;
const MAX_E2E_FIXTURE_FILE_BYTES = 5 * 1024 * 1024;
const MAX_E2E_FIXTURE_BODY_BYTES = 8 * 1024 * 1024;

export function createE2EUIHarnessRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
): RouteDispatcher {
  return async ({ method, path, req, res }) => {
    if (!path.startsWith("/e2e/ui/")) {
      return false;
    }

    if (process.env.OPPI_E2E_UI_HARNESS !== "1") {
      helpers.error(res, 404, "Not found");
      return true;
    }

    const fixtureMatch = path.match(/^\/e2e\/ui\/fixtures\/workspace-file$/);
    if (fixtureMatch) {
      if (method !== "POST") {
        helpers.error(res, 405, "Method not allowed");
        return true;
      }
      await handleWorkspaceFileFixture(ctx, helpers, req, res);
      return true;
    }

    const gitWorktreeFixtureMatch = path.match(/^\/e2e\/ui\/fixtures\/git-worktree$/);
    if (gitWorktreeFixtureMatch) {
      if (method !== "POST") {
        helpers.error(res, 405, "Method not allowed");
        return true;
      }
      await handleGitWorktreeFixture(ctx, helpers, req, res);
      return true;
    }

    const localPiSessionFixtureMatch = path.match(/^\/e2e\/ui\/fixtures\/local-pi-session$/);
    if (localPiSessionFixtureMatch) {
      if (method !== "POST") {
        helpers.error(res, 405, "Method not allowed");
        return true;
      }
      await handleLocalPiSessionFixture(ctx, helpers, req, res);
      return true;
    }

    const responseMatch = path.match(/^\/e2e\/ui\/sessions\/([^/]+)\/responses$/);
    if (responseMatch) {
      handleHarnessResponses(helpers, decodeURIComponent(responseMatch[1]), method, res);
      return true;
    }

    const subscriberMatch = path.match(/^\/e2e\/ui\/sessions\/([^/]+)\/subscribers$/);
    if (subscriberMatch) {
      if (method !== "GET") {
        helpers.error(res, 405, "Method not allowed");
        return true;
      }
      const sessionId = decodeURIComponent(subscriberMatch[1]);
      helpers.json(res, {
        ok: true,
        sessionId,
        subscriberCount: ctx.sessions.getSubscriberCount(sessionId),
      });
      return true;
    }

    const messageMatch = path.match(/^\/e2e\/ui\/sessions\/([^/]+)\/message$/);
    if (!messageMatch) {
      helpers.error(res, 404, "Not found");
      return true;
    }

    if (method !== "POST") {
      helpers.error(res, 405, "Method not allowed");
      return true;
    }

    await handleHarnessMessage(ctx, helpers, decodeURIComponent(messageMatch[1]), req, res);
    return true;
  };
}

async function handleWorkspaceFileFixture(
  ctx: RouteContext,
  helpers: RouteHelpers,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = await helpers.parseBody<Record<string, unknown>>(req, {
    maxBytes: MAX_E2E_FIXTURE_BODY_BYTES,
  });
  const directoryName = safePathSegment(stringField(body.directoryName));
  const filename = safePathSegment(stringField(body.filename));
  const rawBase64 = stringField(body.base64);

  if (!directoryName || !filename || !rawBase64) {
    helpers.error(res, 400, "Fixture requires directoryName, filename, and base64");
    return;
  }

  const compactBase64 = rawBase64.replace(/\s/g, "");
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(compactBase64)) {
    helpers.error(res, 400, "Fixture base64 is invalid");
    return;
  }

  const bytes = Buffer.from(compactBase64, "base64");
  if (bytes.length === 0 || bytes.length > MAX_E2E_FIXTURE_FILE_BYTES) {
    helpers.error(res, 400, "Fixture file size is invalid");
    return;
  }

  const root = join(ctx.storage.getDataDir(), "e2e-fixtures");
  const hostMount = join(root, directoryName);
  const filePath = join(hostMount, filename);
  await mkdir(hostMount, { recursive: true, mode: 0o700 });
  await writeFile(filePath, bytes, { mode: 0o600 });
  helpers.json(res, { ok: true, hostMount, filePath, filename });
}

async function handleGitWorktreeFixture(
  ctx: RouteContext,
  helpers: RouteHelpers,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = await helpers.parseBody<Record<string, unknown>>(req, {
    maxBytes: MAX_E2E_FIXTURE_BODY_BYTES,
  });
  const directoryName = safePathSegment(stringField(body.directoryName));
  const rawBranchName = stringField(body.branchName);
  const branchName =
    rawBranchName === undefined ? "feature/e2e-worktree" : safeBranchName(rawBranchName);

  if (!directoryName) {
    helpers.error(res, 400, "Fixture requires directoryName");
    return;
  }
  if (!branchName) {
    helpers.error(res, 400, "Fixture branchName is invalid");
    return;
  }

  const root = join(ctx.storage.getDataDir(), "e2e-fixtures", directoryName);
  const repoPath = join(root, "repo");
  const managedWorktreesRoot = join(repoPath, ".pi", "worktrees");
  const worktreePath = join(managedWorktreesRoot, "repo-feature");

  try {
    await rm(root, { recursive: true, force: true });
    await mkdir(repoPath, { recursive: true, mode: 0o700 });
    runFixtureGit(repoPath, ["init", "--initial-branch=main"]);
    runFixtureGit(repoPath, ["config", "user.email", "oppi-e2e@example.invalid"]);
    runFixtureGit(repoPath, ["config", "user.name", "Oppi E2E"]);
    await writeFile(join(repoPath, "README.md"), "main checkout\n", { mode: 0o600 });
    await writeFile(join(repoPath, ".gitignore"), ".pi/\n", { mode: 0o600 });
    runFixtureGit(repoPath, ["add", "README.md", ".gitignore"]);
    runFixtureGit(repoPath, ["commit", "-m", "initial"]);
    runFixtureGit(repoPath, ["branch", branchName]);
    await mkdir(managedWorktreesRoot, { recursive: true, mode: 0o700 });
    runFixtureGit(repoPath, ["worktree", "add", worktreePath, branchName]);
  } catch {
    helpers.error(res, 500, "Failed to create git worktree fixture");
    return;
  }

  helpers.json(res, {
    ok: true,
    hostMount: realpathSync(repoPath),
    worktreePath: realpathSync(worktreePath),
    branchName,
  });
}

async function handleLocalPiSessionFixture(
  ctx: RouteContext,
  helpers: RouteHelpers,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = await helpers.parseBody<Record<string, unknown>>(req, {
    maxBytes: MAX_E2E_FIXTURE_BODY_BYTES,
  });
  const directoryName = safePathSegment(stringField(body.directoryName));
  const cwd = stringField(body.cwd)?.trim();
  const sessionId = safePathSegment(stringField(body.sessionId) ?? `e2e-${randomUUID()}`);
  const rawFilename = stringField(body.filename) ?? `${sessionId}.jsonl`;
  const filename = safePathSegment(
    rawFilename.endsWith(".jsonl") ? rawFilename : `${rawFilename}.jsonl`,
  );

  if (!directoryName || !cwd || !sessionId || !filename) {
    helpers.error(
      res,
      400,
      "Fixture requires directoryName, cwd, and safe optional sessionId/filename",
    );
    return;
  }

  const infoEntryId = safePathSegment(stringField(body.infoEntryId) ?? randomTraceEntryId());
  const modelEntryId = safePathSegment(stringField(body.modelEntryId) ?? randomTraceEntryId());
  const userEntryId = safePathSegment(stringField(body.userEntryId) ?? randomTraceEntryId());
  const assistantEntryId = safePathSegment(
    stringField(body.assistantEntryId) ?? randomTraceEntryId(),
  );
  if (!infoEntryId || !modelEntryId || !userEntryId || !assistantEntryId) {
    helpers.error(res, 400, "Fixture trace entry ids are invalid");
    return;
  }

  const name = stringField(body.name)?.trim() || "E2E Local Pi Session";
  const firstMessage =
    stringField(body.firstMessage)?.trim() || `Imported local Pi fixture ${sessionId}`;
  const assistantMessage =
    stringField(body.assistantMessage)?.trim() || "Imported local session fixture.";
  const model = stringField(body.model)?.trim() || "omlx/e2e-local-model";
  const slashIndex = model.indexOf("/");
  const provider = slashIndex > 0 ? model.slice(0, slashIndex) : "omlx";
  const modelId = slashIndex > 0 ? model.slice(slashIndex + 1) : model;
  const timestamp = new Date().toISOString();
  const root = getPiSessionsRoot();
  const sessionDir = join(root, directoryName);
  const filePath = join(sessionDir, filename);
  const lines = [
    { type: "session", id: sessionId, cwd, timestamp, version: 3 },
    { type: "session_info", id: infoEntryId, parentId: null, timestamp, name },
    {
      type: "model_change",
      id: modelEntryId,
      parentId: infoEntryId,
      timestamp,
      provider,
      modelId,
    },
    {
      type: "message",
      id: userEntryId,
      parentId: modelEntryId,
      timestamp,
      message: { role: "user", content: firstMessage },
    },
    {
      type: "message",
      id: assistantEntryId,
      parentId: userEntryId,
      timestamp,
      message: { role: "assistant", content: assistantMessage },
    },
  ];

  await mkdir(sessionDir, { recursive: true, mode: 0o700 });
  await writeFile(filePath, `${lines.map((line) => JSON.stringify(line)).join("\n")}\n`, {
    mode: 0o600,
  });

  await discoverLocalSessions(undefined, { dataDir: ctx.storage.getDataDir() });

  helpers.json(res, { ok: true, path: realpathSync(filePath), piSessionId: sessionId, cwd, name });
}

function randomTraceEntryId(): string {
  return randomUUID().replace(/-/g, "").slice(0, 8);
}

function runFixtureGit(cwd: string, args: string[]): string {
  return execFileSync("git", args, {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 10_000,
  });
}

function safePathSegment(value: string | undefined): string | null {
  if (!value || value === "." || value === ".." || value.includes("\0")) return null;
  if (!/^[A-Za-z0-9._-]+$/.test(value)) return null;
  return value;
}

function safeBranchName(value: string | undefined): string | null {
  const branch = value?.trim();
  if (!branch) return null;
  if (branch.startsWith("-") || branch.startsWith("/") || branch.endsWith("/")) return null;
  if (
    branch.includes("\0") ||
    branch.includes("..") ||
    branch.includes("@{") ||
    branch.includes("//")
  )
    return null;
  if (!/^[A-Za-z0-9._/-]+$/.test(branch)) return null;
  return branch;
}

function handleHarnessResponses(
  helpers: RouteHelpers,
  sessionId: string,
  method: string,
  res: ServerResponse,
): void {
  if (method === "GET") {
    helpers.json(res, { ok: true, responses: getRecordedE2EUIResponses(sessionId) });
    return;
  }

  if (method === "DELETE") {
    clearRecordedE2EUIResponses(sessionId);
    helpers.json(res, { ok: true });
    return;
  }

  helpers.error(res, 405, "Method not allowed");
}

async function handleHarnessMessage(
  ctx: RouteContext,
  helpers: RouteHelpers,
  sessionId: string,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const session = ctx.sessionRuntimes.getSessionSnapshot(sessionId);
  if (!session) {
    helpers.error(res, 404, "Session not found");
    return;
  }

  if (!ctx.sessions.isActive(sessionId)) {
    helpers.error(res, 409, "Session is not active");
    return;
  }

  const body = await helpers.parseBody<Record<string, unknown>>(req, {
    maxBytes: MAX_E2E_UI_MESSAGE_BYTES,
  });
  let message = normalizeHarnessMessage(sessionId, body);
  if (!message) {
    helpers.error(res, 400, "Unsupported E2E UI harness message");
    return;
  }

  message = materializeHarnessToolMedia(ctx, sessionId, message);

  let subscriberCount: number;
  if (message.type === "extension_ui_request") {
    recordSyntheticE2EUIRequest(sessionId, message.id);
    subscriberCount = ctx.sessions.injectExtensionUIRequest(sessionId, message);
  } else {
    subscriberCount = ctx.sessions.broadcastSessionMessage(sessionId, message);
  }
  helpers.json(res, { ok: true, subscriberCount, message });
}

function materializeHarnessToolMedia(
  ctx: RouteContext,
  sessionId: string,
  message: ServerMessage,
): ServerMessage {
  if (message.type !== "tool_end" || !message.details || !hasToolMediaDetails(message.details)) {
    return message;
  }

  try {
    return {
      ...message,
      details: materializeToolMediaDetails({
        dataDir: ctx.storage.getDataDir(),
        sessionId,
        toolCallId: message.toolCallId,
        details: message.details,
      }) as Record<string, unknown>,
    };
  } catch {
    return message;
  }
}

function normalizeHarnessMessage(
  sessionId: string,
  body: Record<string, unknown>,
): ServerMessage | null {
  switch (body.type) {
    case "extension_ui_request":
      return normalizeExtensionUIRequest(sessionId, body);
    case "extension_ui_notification":
      return normalizeExtensionUINotification(body);
    case "extension_ui_settled":
      return normalizeExtensionUISettled(sessionId, body);
    case "session_ended":
      return normalizeSessionEnded(body);
    case "agent_start":
      return { type: "agent_start" };
    case "agent_end":
      return { type: "agent_end" };
    case "thinking_delta":
      return normalizeThinkingDelta(body);
    case "tool_start":
      return normalizeToolStart(body);
    case "tool_output":
      return normalizeToolOutput(body);
    case "tool_end":
      return normalizeToolEnd(body);
    default:
      return null;
  }
}

function normalizeExtensionUIRequest(
  sessionId: string,
  body: Record<string, unknown>,
): ServerMessage | null {
  const id = stringField(body.id);
  const method = stringField(body.method);
  if (!id || !method) return null;

  return buildExtensionUIRequestMessage(sessionId, {
    id,
    method,
    title: stringField(body.title),
    options: stringArrayField(body.options),
    message: stringField(body.message),
    placeholder: stringField(body.placeholder),
    prefill: stringField(body.prefill),
    timeout: numberField(body.timeout),
    timeoutAt: numberField(body.timeoutAt),
    questions: askQuestionsField(body.questions),
    allowCustom: booleanField(body.allowCustom),
    extensionScopeId: stringField(body.extensionScopeId),
    extensionDisplayName: stringField(body.extensionDisplayName),
  });
}

function normalizeExtensionUINotification(body: Record<string, unknown>): ServerMessage | null {
  const method = stringField(body.method);
  if (!method) return null;
  const widgetKey = stringField(body.widgetKey);
  const hasNativeSurface = Object.hasOwn(body, "nativeSurface");
  const nativeSurface = hasNativeSurface
    ? normalizeExtensionUIWidgetNativeSurface(body.nativeSurface, widgetKey, {
        maxBytes: MAX_E2E_UI_MESSAGE_BYTES,
      })
    : undefined;

  if (hasNativeSurface && (!nativeSurface || method !== "setWidget")) {
    return null;
  }

  return buildExtensionUINotificationMessage({
    id: stringField(body.id) ?? "e2e-ui-notification",
    method,
    message: stringField(body.message),
    notifyType: stringField(body.notifyType),
    statusKey: stringField(body.statusKey),
    statusText: stringField(body.statusText),
    title: stringField(body.title),
    text: stringField(body.text),
    widgetKey,
    widgetLines: stringArrayField(body.widgetLines),
    widgetPlacement: stringField(body.widgetPlacement),
    extensionScopeId: stringField(body.extensionScopeId),
    extensionDisplayName: stringField(body.extensionDisplayName),
    workingIndicator: recordField(body.workingIndicator),
    workingVisible: booleanField(body.workingVisible),
    hiddenThinkingLabel: stringField(body.hiddenThinkingLabel),
    toolsExpanded: booleanField(body.toolsExpanded),
    nativeSurface,
  });
}

function normalizeThinkingDelta(body: Record<string, unknown>): ServerMessage {
  return {
    type: "thinking_delta",
    delta: stringField(body.delta) ?? "",
    contentIndex: numberField(body.contentIndex),
  };
}

function normalizeToolStart(body: Record<string, unknown>): ServerMessage | null {
  const tool = stringField(body.tool);
  if (!tool) return null;
  return {
    type: "tool_start",
    tool,
    args: recordField(body.args) ?? {},
    toolCallId: stringField(body.toolCallId),
  };
}

function normalizeToolOutput(body: Record<string, unknown>): ServerMessage | null {
  const output = stringField(body.output);
  if (output === undefined) return null;
  const mode = stringField(body.mode);
  return {
    type: "tool_output",
    output,
    isError: booleanField(body.isError),
    toolCallId: stringField(body.toolCallId),
    mode: mode === "replace" ? "replace" : mode === "append" ? "append" : undefined,
    truncated: booleanField(body.truncated),
    totalBytes: numberField(body.totalBytes),
    details: recordField(body.details),
  };
}

function normalizeToolEnd(body: Record<string, unknown>): ServerMessage | null {
  const tool = stringField(body.tool);
  if (!tool) return null;
  return {
    type: "tool_end",
    tool,
    toolCallId: stringField(body.toolCallId),
    details: recordField(body.details),
    isError: booleanField(body.isError),
  };
}

function normalizeExtensionUISettled(
  sessionId: string,
  body: Record<string, unknown>,
): ServerMessage | null {
  const id = stringField(body.id);
  if (!id) return null;

  return {
    type: "extension_ui_settled",
    id,
    sessionId,
  };
}

function normalizeSessionEnded(body: Record<string, unknown>): ServerMessage {
  return {
    type: "session_ended",
    reason: stringField(body.reason) ?? "e2e_ui_harness",
  };
}

function stringField(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function numberField(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function booleanField(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

function recordField(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function askQuestionsField(value: unknown): AskQuestion[] | undefined {
  return Array.isArray(value) ? (value as AskQuestion[]) : undefined;
}

function stringArrayField(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  return value.filter((item): item is string => typeof item === "string");
}
