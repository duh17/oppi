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
import type { AskQuestion, ServerMessage, StyledSegment } from "../types.js";
import type { RouteDispatcher, RouteHelpers, RouteContext } from "./types.js";

const MAX_E2E_UI_MESSAGE_BYTES = 2 * 1024 * 1024;
const MAX_E2E_FIXTURE_FILE_BYTES = 5 * 1024 * 1024;
const MAX_E2E_FIXTURE_BODY_BYTES = 8 * 1024 * 1024;
const MAX_E2E_STOPPED_SESSION_FIXTURES = 500;
const e2eStoppedSessionFixtureIds = new Set<string>();

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

    const quietModeResetMatch = path.match(/^\/e2e\/ui\/reset-quiet-mode$/);
    if (quietModeResetMatch) {
      if (method !== "POST") {
        helpers.error(res, 405, "Method not allowed");
        return true;
      }
      await handleQuietModeReset(helpers, req, res);
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

    const stoppedSessionsFixtureMatch = path.match(/^\/e2e\/ui\/fixtures\/stopped-sessions$/);
    if (stoppedSessionsFixtureMatch) {
      if (method === "POST") {
        await handleStoppedSessionsFixture(ctx, helpers, req, res);
      } else if (method === "DELETE") {
        await handleDeleteStoppedSessionsFixture(ctx, helpers, req, res);
      } else {
        helpers.error(res, 405, "Method not allowed");
      }
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

async function handleQuietModeReset(
  helpers: RouteHelpers,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = await helpers.parseBody<Record<string, unknown>>(req, {
    maxBytes: MAX_E2E_UI_MESSAGE_BYTES,
  });
  const simulatorUDID = stringField(body.simulatorUDID)?.trim();
  if (!simulatorUDID || !/^[0-9A-Fa-f-]{36}$/.test(simulatorUDID)) {
    helpers.error(res, 400, "Compact turns reset requires a simulator UDID");
    return;
  }
  const enabled = booleanField(body.enabled) === true;
  const defaultsArgs = enabled
    ? ([
        "write",
        "dev.chenda.Oppi",
        "dev.chenda.Oppi.chatDisplay.compactTurns",
        "-bool",
        "true",
      ] as const)
    : (["delete", "dev.chenda.Oppi", "dev.chenda.Oppi.chatDisplay.compactTurns"] as const);
  const plistCommand = enabled
    ? "Set :dev.chenda.Oppi.chatDisplay.compactTurns true"
    : "Delete :dev.chenda.Oppi.chatDisplay.compactTurns";

  let simctlError: unknown;
  try {
    execFileSync("xcrun", ["simctl", "spawn", simulatorUDID, "defaults", ...defaultsArgs], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 10_000,
    });
  } catch (error) {
    simctlError = error;
    const output =
      error instanceof Error && "stderr" in error
        ? String(error.stderr)
        : error instanceof Error
          ? error.message
          : String(error);
    const normalizedOutput = output.toLowerCase();
    if (
      enabled ||
      (!normalizedOutput.includes("does not exist") &&
        !normalizedOutput.includes("not found") &&
        !normalizedOutput.includes("found nothing"))
    ) {
      helpers.error(res, 500, "Compact turns simctl reset failed");
      return;
    }
  }

  // iOS XCTest cannot spawn simctl. The host harness writes the exact
  // persisted key; some Xcode runtimes also need the app-container plist.
  try {
    const containerPath = execFileSync(
      "xcrun",
      ["simctl", "get_app_container", simulatorUDID, "dev.chenda.Oppi", "data"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 10_000 },
    ).trim();
    execFileSync(
      "/usr/libexec/PlistBuddy",
      ["-c", plistCommand, join(containerPath, "Library", "Preferences", "dev.chenda.Oppi.plist")],
      { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 10_000 },
    );
  } catch {
    if (enabled) {
      try {
        const containerPath = execFileSync(
          "xcrun",
          ["simctl", "get_app_container", simulatorUDID, "dev.chenda.Oppi", "data"],
          { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 10_000 },
        ).trim();
        execFileSync(
          "/usr/libexec/PlistBuddy",
          [
            "-c",
            "Add :dev.chenda.Oppi.chatDisplay.compactTurns bool true",
            join(containerPath, "Library", "Preferences", "dev.chenda.Oppi.plist"),
          ],
          { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 10_000 },
        );
      } catch {
        // The app assertion remains the final guard.
      }
    }
  }

  helpers.json(res, { ok: true, alreadyReset: simctlError !== undefined, enabled });
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

async function handleStoppedSessionsFixture(
  ctx: RouteContext,
  helpers: RouteHelpers,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = await helpers.parseBody<Record<string, unknown>>(req, {
    maxBytes: MAX_E2E_FIXTURE_BODY_BYTES,
  });
  const workspaceId = stringField(body.workspaceId)?.trim();
  const count = numberField(body.count);
  const lastActivityMs = numberField(body.lastActivityMs);
  const namePrefix = stringField(body.namePrefix)?.trim() || "E2E Stopped Session";

  if (
    !workspaceId ||
    count === undefined ||
    !Number.isInteger(count) ||
    count < 1 ||
    count > MAX_E2E_STOPPED_SESSION_FIXTURES ||
    lastActivityMs === undefined ||
    lastActivityMs < 0
  ) {
    helpers.error(
      res,
      400,
      `Fixture requires workspaceId, count 1-${MAX_E2E_STOPPED_SESSION_FIXTURES}, and lastActivityMs`,
    );
    return;
  }

  const workspace = ctx.storage.getWorkspace(workspaceId);
  if (!workspace) {
    helpers.error(res, 404, "Workspace not found");
    return;
  }

  const sessionIds: string[] = [];
  for (let index = 0; index < count; index += 1) {
    const session = ctx.storage.createSession(`${namePrefix} ${index + 1}`);
    session.workspaceId = workspace.id;
    session.workspaceName = workspace.name;
    session.status = "stopped";
    session.createdAt = Math.max(0, lastActivityMs - 1_000);
    session.lastActivity = lastActivityMs;
    session.messageCount = 1;
    ctx.storage.saveSession(session);
    e2eStoppedSessionFixtureIds.add(session.id);
    sessionIds.push(session.id);
  }

  helpers.json(res, { ok: true, count: sessionIds.length, sessionIds });
}

async function handleDeleteStoppedSessionsFixture(
  ctx: RouteContext,
  helpers: RouteHelpers,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = await helpers.parseBody<Record<string, unknown>>(req, {
    maxBytes: MAX_E2E_FIXTURE_BODY_BYTES,
  });
  const workspaceId = stringField(body.workspaceId)?.trim();
  const sessionIds = stringArrayField(body.sessionIds);
  if (
    !workspaceId ||
    !sessionIds ||
    sessionIds.length < 1 ||
    sessionIds.length > MAX_E2E_STOPPED_SESSION_FIXTURES
  ) {
    helpers.error(
      res,
      400,
      `Fixture cleanup requires workspaceId and 1-${MAX_E2E_STOPPED_SESSION_FIXTURES} sessionIds`,
    );
    return;
  }

  const sessions = sessionIds.map((sessionId) => ctx.storage.getSession(sessionId));
  const ownsEverySession = sessionIds.every(
    (sessionId, index) =>
      e2eStoppedSessionFixtureIds.has(sessionId) &&
      sessions[index]?.workspaceId === workspaceId &&
      sessions[index]?.status === "stopped",
  );
  if (!ownsEverySession) {
    helpers.error(res, 409, "Fixture cleanup only deletes owned stopped sessions");
    return;
  }

  let deletedCount = 0;
  for (const sessionId of sessionIds) {
    if (ctx.storage.deleteSession(sessionId)) {
      deletedCount += 1;
      e2eStoppedSessionFixtureIds.delete(sessionId);
    }
  }
  helpers.json(res, { ok: true, deletedCount });
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

  if (
    booleanField(body.persist) === true &&
    message.type === "message_end" &&
    message.role === "assistant" &&
    !ctx.sessions.appendE2EAssistantMessage(sessionId, message.content)
  ) {
    helpers.error(res, 409, "Assistant fixture could not be persisted");
    return;
  }

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
    case "agent_settled":
      return { type: "agent_settled" };
    case "text_delta":
      return normalizeTextDelta(body);
    case "message_end":
      return normalizeMessageEnd(body);
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

function normalizeTextDelta(body: Record<string, unknown>): ServerMessage | null {
  const delta = stringField(body.delta);
  if (delta === undefined) return null;
  return { type: "text_delta", delta };
}

function normalizeMessageEnd(body: Record<string, unknown>): ServerMessage | null {
  const role = stringField(body.role);
  const content = stringField(body.content);
  if ((role !== "user" && role !== "assistant") || content === undefined) return null;
  return { type: "message_end", role, content };
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
  const callSegments = styledSegmentsField(body.callSegments);
  return {
    type: "tool_start",
    tool,
    args: recordField(body.args) ?? {},
    toolCallId: stringField(body.toolCallId),
    ...(callSegments ? { callSegments } : {}),
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
  const resultSegments = styledSegmentsField(body.resultSegments);
  return {
    type: "tool_end",
    tool,
    toolCallId: stringField(body.toolCallId),
    details: recordField(body.details),
    isError: booleanField(body.isError),
    ...(resultSegments ? { resultSegments } : {}),
  };
}

function styledSegmentsField(value: unknown): StyledSegment[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const allowedStyles = new Set<NonNullable<StyledSegment["style"]>>([
    "bold",
    "muted",
    "dim",
    "accent",
    "success",
    "warning",
    "error",
  ]);
  const segments = value.flatMap((item): StyledSegment[] => {
    const record = recordField(item);
    const text = stringField(record?.text);
    if (text === undefined) return [];
    const style = stringField(record?.style);
    return [
      {
        text,
        ...(style && allowedStyles.has(style as NonNullable<StyledSegment["style"]>)
          ? { style: style as NonNullable<StyledSegment["style"]> }
          : {}),
      },
    ];
  });
  return segments.length > 0 ? segments : undefined;
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
