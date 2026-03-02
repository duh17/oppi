#!/usr/bin/env node
/**
 * agent-sessions.mjs
 *
 * Unified session lifecycle CLI for oppi:
 * - list/status/latest/stop/trace
 * - dispatch (REST create/resume + WebSocket prompt delivery)
 * - events/messages
 * - review (mechanical ai-review + optional review dispatch)
 */

import https from "node:https";
import { existsSync, readFileSync } from "node:fs";
import { execFileSync, spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(SCRIPT_DIR, "../../../..");

const CONFIG_PATH = join(homedir(), ".config", "oppi", "config.json");
const DEFAULT_HOST = "localhost";
const DEFAULT_PORT = 7749;
const HTTPS_AGENT = new https.Agent({ rejectUnauthorized: false });

const REVIEW_MODEL = "openai-codex/gpt-5.3-codex";
const REVIEW_THINKING = "high";
const REVIEW_NAME = "ai-review";

class CliError extends Error {
  constructor(message, exitCode = 1, details = undefined) {
    super(message);
    this.name = "CliError";
    this.exitCode = exitCode;
    this.details = details;
  }
}

class ApiError extends Error {
  constructor(message, status, data) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.data = data;
  }
}

function usage() {
  return [
    "Usage:",
    "  agent-sessions list [--workspace <name>] [--limit N] [--human]",
    "  agent-sessions status <id> [--workspace <name>] [--human]",
    "  agent-sessions dispatch --workspace <name> --prompt '...' [--name ...] [--model ...] [--thinking ...] [--todo ...] [--context-file ...] [--human]",
    "  agent-sessions stop <id> [--workspace <name>] [--human]",
    "  agent-sessions events <id> [--workspace <name>] [--since N] [--human]",
    "  agent-sessions messages <id> [--workspace <name>] [--human]",
    "  agent-sessions trace <id> [--workspace <name>] [--jsonl] [--human]",
    "  agent-sessions review [--commits N] [--staged] [--dispatch] [--workspace <name>] [--human]",
    "  agent-sessions latest [--workspace <name>] [--human]",
  ].join("\n");
}

function flag(args, name) {
  const i = args.indexOf(name);
  if (i === -1) return undefined;
  return args[i + 1];
}

function flagValues(args, name) {
  const values = [];
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] !== name) continue;
    const value = args[i + 1];
    if (!value || value.startsWith("--")) continue;
    values.push(value);
  }
  return values;
}

function hasFlag(args, name) {
  return args.includes(name);
}

function stripFlag(args, name) {
  let found = false;
  const out = [];
  for (const token of args) {
    if (token === name) {
      found = true;
      continue;
    }
    out.push(token);
  }
  return { found, args: out };
}

function stripKnownFlagWithValue(args, name) {
  const out = [];
  let skipNext = false;
  for (let i = 0; i < args.length; i += 1) {
    if (skipNext) {
      skipNext = false;
      continue;
    }
    const token = args[i];
    if (token === name) {
      skipNext = true;
      continue;
    }
    out.push(token);
  }
  return out;
}

function ensureNoUnknownFlags(args, allowedFlags) {
  for (const token of args) {
    if (!token.startsWith("--")) continue;
    if (!allowedFlags.has(token)) {
      throw new CliError(`Unknown flag: ${token}`);
    }
  }
}

function requirePositional(args, commandName) {
  const value = args[0];
  if (!value || value.startsWith("--")) {
    throw new CliError(`Usage: agent-sessions ${commandName} <id> [--workspace <name>]`);
  }
  return value;
}

function parsePositiveInt(value, flagName) {
  const parsed = Number.parseInt(String(value), 10);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new CliError(`${flagName} must be a positive integer`);
  }
  return parsed;
}

function parseNonNegativeInt(value, flagName) {
  const parsed = Number.parseInt(String(value), 10);
  if (!Number.isInteger(parsed) || parsed < 0) {
    throw new CliError(`${flagName} must be a non-negative integer`);
  }
  return parsed;
}

function loadConfig() {
  let config;
  try {
    config = JSON.parse(readFileSync(CONFIG_PATH, "utf8"));
  } catch {
    throw new CliError(`Failed to read oppi config at ${CONFIG_PATH}`);
  }

  const token = typeof config.token === "string" ? config.token : "";
  if (!token) {
    throw new CliError("No token found in ~/.config/oppi/config.json (token field)");
  }

  const configuredPort = Number.parseInt(String(config.port ?? DEFAULT_PORT), 10);
  const port = Number.isInteger(configuredPort) && configuredPort > 0 ? configuredPort : DEFAULT_PORT;

  return {
    token,
    port,
  };
}

function createApiClient({ token, port }) {
  const defaultHeaders = {
    Authorization: `Bearer ${token}`,
  };

  return async function api(method, path, body) {
    const payload = body === undefined ? undefined : JSON.stringify(body);
    const headers = {
      ...defaultHeaders,
    };

    if (payload !== undefined) {
      headers["Content-Type"] = "application/json";
      headers["Content-Length"] = String(Buffer.byteLength(payload));
    }

    return await new Promise((resolvePromise, rejectPromise) => {
      const req = https.request(
        {
          hostname: DEFAULT_HOST,
          port,
          method,
          path,
          headers,
          agent: HTTPS_AGENT,
        },
        (res) => {
          const chunks = [];
          res.on("data", (chunk) => {
            chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
          });
          res.on("end", () => {
            const raw = Buffer.concat(chunks).toString("utf8");
            let parsed = {};
            if (raw.trim().length > 0) {
              try {
                parsed = JSON.parse(raw);
              } catch {
                parsed = { raw };
              }
            }

            const status = res.statusCode ?? 500;
            if (status >= 200 && status < 300) {
              resolvePromise(parsed);
              return;
            }

            const message =
              typeof parsed?.error === "string"
                ? parsed.error
                : typeof parsed?.raw === "string"
                  ? parsed.raw
                  : `HTTP ${status}`;
            rejectPromise(new ApiError(`${method} ${path} ${status}: ${message}`, status, parsed));
          });
        },
      );

      req.on("error", (error) => {
        rejectPromise(new CliError(`Request failed: ${error.message}`));
      });

      if (payload !== undefined) {
        req.write(payload);
      }
      req.end();
    });
  };
}

function normalizeWorkspaceArg(value) {
  return typeof value === "string" ? value.trim() : "";
}

async function listWorkspaces(api) {
  const data = await api("GET", "/workspaces");
  if (!Array.isArray(data?.workspaces)) {
    throw new CliError("Invalid /workspaces response shape", 2, data);
  }
  return data.workspaces;
}

function findWorkspace(workspaces, workspaceArg) {
  const key = normalizeWorkspaceArg(workspaceArg);
  if (!key) return undefined;
  return workspaces.find(
    (workspace) =>
      workspace.id === key ||
      (typeof workspace.name === "string" && workspace.name.toLowerCase() === key.toLowerCase()),
  );
}

function expandMaybeHome(pathValue) {
  if (!pathValue || typeof pathValue !== "string") return undefined;
  if (pathValue.startsWith("~/")) return join(homedir(), pathValue.slice(2));
  return pathValue;
}

function normalizePath(pathValue) {
  const expanded = expandMaybeHome(pathValue);
  if (!expanded) return undefined;
  return resolve(expanded);
}

function inferWorkspaceForRepo(workspaces, repoRoot) {
  const repoPath = normalizePath(repoRoot);
  const repoName = basename(repoRoot).toLowerCase();

  if (repoPath) {
    const exactPath = workspaces.find((workspace) => {
      const mount = normalizePath(workspace.hostMount);
      return Boolean(mount) && mount === repoPath;
    });
    if (exactPath) return exactPath;

    const containsPath = workspaces.find((workspace) => {
      const mount = normalizePath(workspace.hostMount);
      return Boolean(mount) && (repoPath.startsWith(`${mount}/`) || mount.startsWith(`${repoPath}/`));
    });
    if (containsPath) return containsPath;
  }

  const byName = workspaces.find(
    (workspace) =>
      typeof workspace.name === "string" && workspace.name.toLowerCase() === repoName,
  );
  if (byName) return byName;

  const oppiByName = workspaces.find(
    (workspace) =>
      typeof workspace.name === "string" && workspace.name.toLowerCase() === "oppi",
  );
  if (oppiByName) return oppiByName;

  return undefined;
}

async function resolveWorkspace(api, workspaceArg, { required = true, repoRoot } = {}) {
  const workspaces = await listWorkspaces(api);

  if (workspaceArg) {
    const workspace = findWorkspace(workspaces, workspaceArg);
    if (!workspace) {
      throw new CliError(
        `Workspace not found: ${workspaceArg}. Available: ${workspaces
          .map((w) => `${w.name} (${w.id})`)
          .join(", ")}`,
      );
    }
    return workspace;
  }

  if (repoRoot) {
    const inferred = inferWorkspaceForRepo(workspaces, repoRoot);
    if (inferred) return inferred;
  }

  if (required) {
    throw new CliError("--workspace is required");
  }

  return undefined;
}

function sortSessionsByLastActivity(sessions) {
  return [...sessions].sort((a, b) => (b.lastActivity || 0) - (a.lastActivity || 0));
}

function sessionPath(workspaceId, sessionId, suffix = "") {
  const ws = encodeURIComponent(workspaceId);
  const sid = encodeURIComponent(sessionId);
  return `/workspaces/${ws}/sessions/${sid}${suffix}`;
}

async function listSessionsForWorkspace(api, workspace) {
  const data = await api("GET", `/workspaces/${encodeURIComponent(workspace.id)}/sessions`);
  const sessions = Array.isArray(data?.sessions) ? data.sessions : [];
  return sessions.map((session) => ({
    ...session,
    workspaceId: session.workspaceId || workspace.id,
    workspaceName: session.workspaceName || workspace.name,
  }));
}

async function getSessionDetail(api, workspaceId, sessionId, view = undefined) {
  const query = view ? `?view=${encodeURIComponent(view)}` : "";
  return await api("GET", `${sessionPath(workspaceId, sessionId)}${query}`);
}

async function locateSession(api, sessionId, workspaceArg) {
  if (workspaceArg) {
    const workspace = await resolveWorkspace(api, workspaceArg, { required: true });
    const detail = await getSessionDetail(api, workspace.id, sessionId);
    return { workspace, detail };
  }

  const workspaces = await listWorkspaces(api);
  for (const workspace of workspaces) {
    try {
      const detail = await getSessionDetail(api, workspace.id, sessionId);
      return { workspace, detail };
    } catch (error) {
      if (error instanceof ApiError && error.status === 404) continue;
      throw error;
    }
  }

  throw new CliError(`Session not found: ${sessionId}`);
}

function normalizeTodoId(raw) {
  if (!raw || typeof raw !== "string") return undefined;
  const trimmed = raw.trim();
  if (!trimmed) return undefined;
  const withoutPrefix = trimmed.replace(/^TODO-/i, "");
  const compact = withoutPrefix.replace(/[^a-zA-Z0-9]/g, "");
  if (!compact) return undefined;
  return compact.toLowerCase();
}

function resolveContextPath(rawPath) {
  if (!rawPath || typeof rawPath !== "string") return undefined;
  if (rawPath.startsWith("~/")) return join(homedir(), rawPath.slice(2));
  if (rawPath.startsWith("/")) return rawPath;
  return join(process.cwd(), rawPath);
}

function loadContextFile(pathArg) {
  const resolvedPath = resolveContextPath(pathArg);
  if (!resolvedPath || !existsSync(resolvedPath)) {
    throw new CliError(`context file not found: ${pathArg}`);
  }

  let content = "";
  try {
    content = readFileSync(resolvedPath, "utf8");
  } catch (error) {
    throw new CliError(
      `failed to read context file ${resolvedPath}: ${error instanceof Error ? error.message : String(error)}`,
    );
  }

  const maxChars = 80_000;
  const trimmed = content.trim();
  if (trimmed.length === 0) {
    throw new CliError(`context file is empty: ${resolvedPath}`);
  }

  const finalContent = trimmed.slice(0, maxChars);
  const truncated = trimmed.length > maxChars;
  return { path: resolvedPath, content: finalContent, truncated };
}

function extractTodoIds(text) {
  if (!text) return [];
  const ids = new Set();
  const regex = /TODO-([a-zA-Z0-9]{6,40})\b/g;
  let match;
  while ((match = regex.exec(text)) !== null) {
    const normalized = normalizeTodoId(match[1]);
    if (normalized) ids.add(normalized);
  }
  return [...ids];
}

function gitCommonDirFor(dirPath) {
  try {
    const out = execFileSync("git", ["-C", dirPath, "rev-parse", "--git-common-dir"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (!out) return undefined;
    if (out.startsWith("/")) return out;
    return join(dirPath, out);
  } catch {
    return undefined;
  }
}

function todoFileCandidates(todoId, workspace) {
  const candidates = [];

  candidates.push(join(process.cwd(), ".pi", "todos", `${todoId}.md`));

  if (workspace?.hostMount) {
    candidates.push(join(workspace.hostMount, ".pi", "todos", `${todoId}.md`));

    const commonDir = gitCommonDirFor(workspace.hostMount);
    if (commonDir) {
      const repoRoot = dirname(commonDir);
      candidates.push(join(repoRoot, ".pi", "todos", `${todoId}.md`));
    }
  }

  candidates.push(join(homedir(), ".pi", "todos", `${todoId}.md`));

  const seen = new Set();
  const unique = [];
  for (const pathCandidate of candidates) {
    if (seen.has(pathCandidate)) continue;
    seen.add(pathCandidate);
    unique.push(pathCandidate);
  }
  return unique;
}

function loadTodoMarkdown(todoId, workspace) {
  for (const candidate of todoFileCandidates(todoId, workspace)) {
    if (!existsSync(candidate)) continue;
    try {
      const content = readFileSync(candidate, "utf8");
      if (content.trim().length > 0) {
        return { id: todoId, path: candidate, content };
      }
    } catch {
      // Try next candidate.
    }
  }
  return undefined;
}

function buildPromptWithTodoContext(promptText, workspace, explicitTodo) {
  const todoIds = explicitTodo
    ? [normalizeTodoId(explicitTodo)].filter(Boolean)
    : extractTodoIds(promptText);

  if (todoIds.length === 0) {
    return { finalPrompt: promptText, injectedTodos: [], missingTodos: [] };
  }

  const loaded = [];
  const missing = [];

  for (const todoId of todoIds) {
    const todo = loadTodoMarkdown(todoId, workspace);
    if (todo) loaded.push(todo);
    else missing.push(todoId);
  }

  if (explicitTodo && loaded.length === 0) {
    throw new CliError(`--todo ${explicitTodo} was provided, but no matching todo file was found.`);
  }

  if (loaded.length === 0) {
    return { finalPrompt: promptText, injectedTodos: [], missingTodos: missing };
  }

  const todoContext = loaded
    .map((todo) => {
      return ["---", `Full TODO context: TODO-${todo.id}`, `Source: ${todo.path}`, "", todo.content].join(
        "\n",
      );
    })
    .join("\n\n");

  const finalPrompt = `${promptText}\n\n${todoContext}`;

  return {
    finalPrompt,
    injectedTodos: loaded.map((todo) => ({ id: todo.id, path: todo.path })),
    missingTodos: missing,
  };
}

function buildPromptWithFileContext(promptText, paths) {
  if (!Array.isArray(paths) || paths.length === 0) {
    return { finalPrompt: promptText, injectedFiles: [] };
  }

  const loaded = paths.map((pathArg) => loadContextFile(pathArg));
  const context = loaded
    .map((file) => {
      return [
        "---",
        `Attached file context: ${file.path}`,
        file.truncated ? "(truncated to 80k chars)" : "",
        "",
        file.content,
      ]
        .filter(Boolean)
        .join("\n");
    })
    .join("\n\n");

  return {
    finalPrompt: `${promptText}\n\n${context}`,
    injectedFiles: loaded.map((file) => ({ path: file.path, truncated: file.truncated })),
  };
}

async function loadWebSocketCtor() {
  const moduleCandidates = [
    "ws",
    join(REPO_ROOT, "server", "node_modules", "ws", "index.js"),
    join(process.cwd(), "server", "node_modules", "ws", "index.js"),
    join(homedir(), "workspace", "oppi", "server", "node_modules", "ws", "index.js"),
  ];

  for (const candidate of moduleCandidates) {
    try {
      const mod = await import(candidate);
      const ctor = mod.WebSocket || mod.default?.WebSocket || mod.default;
      if (typeof ctor === "function") {
        return ctor;
      }
    } catch {
      // Try next candidate.
    }
  }

  return undefined;
}

async function dispatchSession(api, config, {
  workspaceArg,
  prompt,
  sessionName,
  model,
  thinkingLevel,
  todoArg,
  contextFiles,
}) {
  if (!workspaceArg || !prompt) {
    throw new CliError(
      "Usage: agent-sessions dispatch --workspace <id|name> --prompt '...' [--name ...] [--model ...] [--thinking ...] [--todo ...] [--context-file ...]",
    );
  }

  const workspace = await resolveWorkspace(api, workspaceArg, { required: true });

  const todoPrompt = buildPromptWithTodoContext(prompt, workspace, todoArg);
  const filePrompt = buildPromptWithFileContext(todoPrompt.finalPrompt, contextFiles);

  const finalPrompt = filePrompt.finalPrompt;
  const injectedTodos = todoPrompt.injectedTodos;
  const missingTodos = todoPrompt.missingTodos;
  const injectedFiles = filePrompt.injectedFiles;

  const createBody = {};
  if (sessionName) createBody.name = sessionName;
  if (model) createBody.model = model;

  const createResult = await api("POST", `/workspaces/${encodeURIComponent(workspace.id)}/sessions`, createBody);
  const session = createResult?.session;
  const sessionId = session?.id;
  if (!sessionId) {
    throw new CliError("Session create response missing session.id", 2, createResult);
  }

  await api("POST", `${sessionPath(workspace.id, sessionId)}/resume`);

  const WebSocket = await loadWebSocketCtor();
  if (!WebSocket) {
    return {
      sessionId,
      workspaceId: workspace.id,
      workspaceName: workspace.name,
      model: session.model,
      prompted: false,
      warning: "ws module not found; session created and resumed but prompt was not sent",
      injectedTodos: injectedTodos.map((todo) => `TODO-${todo.id}`),
      missingTodos: missingTodos.map((id) => `TODO-${id}`),
      injectedFiles: injectedFiles.map((file) => file.path),
      promptChars: finalPrompt.length,
    };
  }

  await new Promise((resolvePromise, rejectPromise) => {
    const ws = new WebSocket(`wss://${DEFAULT_HOST}:${config.port}/stream`, {
      headers: { Authorization: `Bearer ${config.token}` },
      rejectUnauthorized: false,
    });

    const timeout = setTimeout(() => {
      ws.close();
      rejectPromise(new CliError("WebSocket timeout (15s)", 2));
    }, 15_000);

    let subscribed = false;
    let prompted = false;

    ws.on("open", () => {
      ws.send(JSON.stringify({ type: "subscribe", sessionId, level: "full" }));
    });

    ws.on("message", (rawData) => {
      let msg;
      try {
        msg = JSON.parse(rawData.toString());
      } catch {
        return;
      }

      if (msg.type === "command_result" && msg.command === "subscribe" && msg.success) {
        subscribed = true;

        if (thinkingLevel) {
          ws.send(
            JSON.stringify({
              type: "set_thinking_level",
              sessionId,
              level: thinkingLevel,
            }),
          );
        }

        ws.send(
          JSON.stringify({
            type: "prompt",
            sessionId,
            message: finalPrompt,
            requestId: "dispatch-prompt",
          }),
        );
      }

      if (msg.type === "command_result" && msg.requestId === "dispatch-prompt" && msg.success) {
        prompted = true;
        clearTimeout(timeout);
        ws.close();
        resolvePromise();
      }

      if (!prompted && subscribed && msg.type === "agent_start") {
        prompted = true;
        clearTimeout(timeout);
        ws.close();
        resolvePromise();
      }

      if (msg.type === "error" && !prompted) {
        clearTimeout(timeout);
        ws.close();
        rejectPromise(new CliError(msg.error || "Unknown WebSocket error", 2));
      }
    });

    ws.on("error", (error) => {
      clearTimeout(timeout);
      rejectPromise(new CliError(error.message, 2));
    });
  });

  return {
    sessionId,
    workspaceId: workspace.id,
    workspaceName: workspace.name,
    model: session.model,
    prompted: true,
    injectedTodos: injectedTodos.map((todo) => `TODO-${todo.id}`),
    missingTodos: missingTodos.map((id) => `TODO-${id}`),
    injectedFiles: injectedFiles.map((file) => file.path),
    promptChars: finalPrompt.length,
  };
}

function extractAssistantMessagesFromTrace(trace) {
  if (!Array.isArray(trace)) return [];
  return trace
    .filter(
      (event) =>
        event && event.type === "assistant" && typeof event.text === "string" && event.text.trim().length > 0,
    )
    .map((event) => event.text);
}

function latestJsonlPath(session) {
  if (typeof session?.piSessionFile === "string" && session.piSessionFile.trim()) {
    return session.piSessionFile;
  }
  if (Array.isArray(session?.piSessionFiles) && session.piSessionFiles.length > 0) {
    const file = session.piSessionFiles[session.piSessionFiles.length - 1];
    if (typeof file === "string" && file.trim()) return file;
  }
  return undefined;
}

function getGitRoot() {
  try {
    return execFileSync("git", ["rev-parse", "--show-toplevel"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
  } catch {
    throw new CliError("Not inside a git repository");
  }
}

function runAiReview(aiReviewPath, reviewArgs, repoRoot) {
  const result = spawnSync("node", [aiReviewPath, ...reviewArgs], {
    cwd: repoRoot,
    encoding: "utf8",
  });

  if (result.error) {
    throw new CliError(`Failed to run ai-review.mjs: ${result.error.message}`);
  }

  return {
    status: result.status ?? 1,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

function parseAiReviewOutput(stdout) {
  const summaryMatch = stdout.match(/=== AI Review Summary ===\n([\s\S]*?)\n\n=== AI Review Prompt ===/);
  const promptMatch = stdout.match(/=== AI Review Prompt ===\n([\s\S]*)/);

  if (!summaryMatch || !promptMatch) {
    throw new CliError("Failed to parse ai-review output");
  }

  let summary;
  try {
    summary = JSON.parse(summaryMatch[1]);
  } catch {
    throw new CliError("Failed to parse ai-review summary JSON");
  }

  return {
    summary,
    reviewPrompt: promptMatch[1],
  };
}

function buildReviewDispatchPrompt(reviewPrompt) {
  return `You are a code reviewer for the Oppi project.

The mechanical pre-checks have already run. Your job is to review the actual diff for:
1. Correctness — bugs, logic errors, missing edge cases
2. Architecture compliance — do changes follow ARCHITECTURE.md dependency rules?
3. Golden principles — are docs/golden-principles.md invariants respected?
4. Protocol discipline — if protocol files changed, are both sides updated?
5. Test coverage — are new behaviors tested?
6. Documentation — are docs updated to reflect changes?

Here is the mechanical review output and full diff:

${reviewPrompt}

Provide a structured review with:
- Summary (1-2 sentences)
- Issues found (if any), with file:line references
- Verdict: PASS / WARN / FAIL`;
}

async function cmdList(api, args) {
  ensureNoUnknownFlags(args, new Set(["--workspace", "--limit"]));

  const workspaceArg = flag(args, "--workspace");
  const limitArg = flag(args, "--limit");
  const limit = limitArg ? parsePositiveInt(limitArg, "--limit") : 10;

  let sessions = [];
  let scope = "all";

  if (workspaceArg) {
    const workspace = await resolveWorkspace(api, workspaceArg, { required: true });
    sessions = await listSessionsForWorkspace(api, workspace);
    scope = workspace.name || workspace.id;
  } else {
    const workspaces = await listWorkspaces(api);
    for (const workspace of workspaces) {
      const workspaceSessions = await listSessionsForWorkspace(api, workspace);
      sessions.push(...workspaceSessions);
    }
  }

  const sorted = sortSessionsByLastActivity(sessions);

  return {
    command: "list",
    scope,
    total: sorted.length,
    limit,
    sessions: sorted.slice(0, limit),
  };
}

async function cmdStatus(api, args) {
  ensureNoUnknownFlags(args.slice(1), new Set(["--workspace"]));

  const sessionId = requirePositional(args, "status");
  const workspaceArg = flag(args.slice(1), "--workspace");

  const located = await locateSession(api, sessionId, workspaceArg);
  const traceLength = Array.isArray(located.detail?.trace) ? located.detail.trace.length : 0;

  return {
    command: "status",
    workspaceId: located.workspace.id,
    workspaceName: located.workspace.name,
    session: located.detail?.session,
    traceLength,
  };
}

async function cmdLatest(api, args) {
  ensureNoUnknownFlags(args, new Set(["--workspace"]));

  const workspaceArg = flag(args, "--workspace");

  let sessions = [];
  if (workspaceArg) {
    const workspace = await resolveWorkspace(api, workspaceArg, { required: true });
    sessions = await listSessionsForWorkspace(api, workspace);
  } else {
    const workspaces = await listWorkspaces(api);
    for (const workspace of workspaces) {
      const workspaceSessions = await listSessionsForWorkspace(api, workspace);
      sessions.push(...workspaceSessions);
    }
  }

  const sorted = sortSessionsByLastActivity(sessions);
  const latest = sorted[0];
  if (!latest) {
    throw new CliError("No sessions found");
  }

  const detail = await getSessionDetail(api, latest.workspaceId, latest.id);

  return {
    command: "latest",
    workspaceId: latest.workspaceId,
    workspaceName: latest.workspaceName,
    session: detail?.session || latest,
    traceLength: Array.isArray(detail?.trace) ? detail.trace.length : 0,
  };
}

async function cmdStop(api, args) {
  ensureNoUnknownFlags(args.slice(1), new Set(["--workspace"]));

  const sessionId = requirePositional(args, "stop");
  const workspaceArg = flag(args.slice(1), "--workspace");

  const located = await locateSession(api, sessionId, workspaceArg);
  const result = await api("POST", `${sessionPath(located.workspace.id, sessionId)}/stop`);

  return {
    command: "stop",
    workspaceId: located.workspace.id,
    workspaceName: located.workspace.name,
    ok: result?.ok === true,
    session: result?.session,
  };
}

async function cmdEvents(api, args) {
  ensureNoUnknownFlags(args.slice(1), new Set(["--workspace", "--since"]));

  const sessionId = requirePositional(args, "events");
  const workspaceArg = flag(args.slice(1), "--workspace");
  const sinceArg = flag(args.slice(1), "--since");
  const since = sinceArg ? parseNonNegativeInt(sinceArg, "--since") : 0;

  const located = await locateSession(api, sessionId, workspaceArg);
  const result = await api(
    "GET",
    `${sessionPath(located.workspace.id, sessionId)}/events?since=${encodeURIComponent(String(since))}`,
  );

  return {
    command: "events",
    workspaceId: located.workspace.id,
    workspaceName: located.workspace.name,
    since,
    ...result,
  };
}

async function cmdMessages(api, args) {
  ensureNoUnknownFlags(args.slice(1), new Set(["--workspace"]));

  const sessionId = requirePositional(args, "messages");
  const workspaceArg = flag(args.slice(1), "--workspace");

  const located = await locateSession(api, sessionId, workspaceArg);
  const detail = await getSessionDetail(api, located.workspace.id, sessionId, "full");
  const assistantMessages = extractAssistantMessagesFromTrace(detail?.trace);
  const finalAssistantText = assistantMessages.length > 0 ? assistantMessages[assistantMessages.length - 1] : null;

  return {
    command: "messages",
    workspaceId: located.workspace.id,
    workspaceName: located.workspace.name,
    sessionId,
    finalAssistantText,
    assistantMessageCount: assistantMessages.length,
  };
}

async function cmdTrace(api, args) {
  ensureNoUnknownFlags(args.slice(1), new Set(["--workspace", "--jsonl"]));

  const sessionId = requirePositional(args, "trace");
  const workspaceArg = flag(args.slice(1), "--workspace");
  const includeJsonl = hasFlag(args.slice(1), "--jsonl");

  const located = await locateSession(api, sessionId, workspaceArg);
  const session = located.detail?.session;
  const tracePath = latestJsonlPath(session);

  if (!tracePath) {
    throw new CliError("No JSONL trace file recorded for session");
  }

  if (!includeJsonl) {
    return {
      command: "trace",
      workspaceId: located.workspace.id,
      workspaceName: located.workspace.name,
      sessionId,
      tracePath,
      tracePaths: Array.isArray(session?.piSessionFiles) ? session.piSessionFiles : [],
    };
  }

  if (!existsSync(tracePath)) {
    throw new CliError(`JSONL file not found: ${tracePath}`);
  }

  const content = readFileSync(tracePath, "utf8");
  return {
    command: "trace",
    workspaceId: located.workspace.id,
    workspaceName: located.workspace.name,
    sessionId,
    tracePath,
    jsonl: content,
  };
}

async function cmdDispatch(api, config, args) {
  ensureNoUnknownFlags(
    stripKnownFlagWithValue(
      stripKnownFlagWithValue(
        stripKnownFlagWithValue(
          stripKnownFlagWithValue(
            stripKnownFlagWithValue(
              stripKnownFlagWithValue(
                stripKnownFlagWithValue(args, "--workspace"),
                "--prompt",
              ),
              "--name",
            ),
            "--model",
          ),
          "--thinking",
        ),
        "--todo",
      ),
      "--context-file",
    ).filter((token) => token.startsWith("--")),
    new Set(),
  );

  const workspaceArg = flag(args, "--workspace");
  const prompt = flag(args, "--prompt");
  const sessionName = flag(args, "--name");
  const model = flag(args, "--model");
  const thinkingLevel = flag(args, "--thinking");
  const todoArg = flag(args, "--todo");
  const contextFiles = flagValues(args, "--context-file");

  const result = await dispatchSession(api, config, {
    workspaceArg,
    prompt,
    sessionName,
    model,
    thinkingLevel,
    todoArg,
    contextFiles,
  });

  return {
    command: "dispatch",
    ...result,
  };
}

async function cmdReview(api, config, args) {
  ensureNoUnknownFlags(args, new Set(["--commits", "--staged", "--dispatch", "--workspace"]));

  const commitsArg = flag(args, "--commits");
  const staged = hasFlag(args, "--staged");
  const dispatchRequested = hasFlag(args, "--dispatch");
  const workspaceArg = flag(args, "--workspace");

  if (commitsArg && staged) {
    throw new CliError("Use either --staged or --commits N, not both");
  }

  const reviewArgs = [];
  if (commitsArg) {
    reviewArgs.push("--commits", String(parsePositiveInt(commitsArg, "--commits")));
  } else {
    reviewArgs.push("--staged");
  }

  const repoRoot = getGitRoot();
  const aiReviewPath = join(repoRoot, "server", "scripts", "ai-review.mjs");
  if (!existsSync(aiReviewPath)) {
    throw new CliError(`ai-review.mjs not found at ${aiReviewPath}`);
  }

  const run = runAiReview(aiReviewPath, reviewArgs, repoRoot);
  const parsed = parseAiReviewOutput(run.stdout);

  let dispatch = undefined;
  if (dispatchRequested && parsed.summary?.status !== "pass") {
    const reviewWorkspace = workspaceArg
      ? await resolveWorkspace(api, workspaceArg, { required: true })
      : await resolveWorkspace(api, undefined, { required: true, repoRoot });

    const prompt = buildReviewDispatchPrompt(parsed.reviewPrompt);
    const dispatchResult = await dispatchSession(api, config, {
      workspaceArg: reviewWorkspace.id,
      prompt,
      sessionName: REVIEW_NAME,
      model: REVIEW_MODEL,
      thinkingLevel: REVIEW_THINKING,
      todoArg: undefined,
      contextFiles: [],
    });

    dispatch = {
      dispatched: true,
      workspaceId: reviewWorkspace.id,
      workspaceName: reviewWorkspace.name,
      sessionId: dispatchResult.sessionId,
    };
  } else if (dispatchRequested) {
    dispatch = {
      dispatched: false,
      reason: "mechanical review passed",
    };
  }

  return {
    command: "review",
    repoRoot,
    aiReviewPath,
    reviewArgs,
    mechanicalExitCode: run.status,
    summary: parsed.summary,
    dispatch,
  };
}

function emitResult(result, human) {
  const indent = human ? 2 : 0;
  console.log(JSON.stringify(result, null, indent));
}

function emitError(error) {
  if (error instanceof CliError) {
    console.error(
      JSON.stringify(
        {
          error: error.message,
          details: error.details,
        },
        null,
        0,
      ),
    );
    process.exit(error.exitCode || 1);
  }

  if (error instanceof ApiError) {
    console.error(
      JSON.stringify(
        {
          error: error.message,
          status: error.status,
          data: error.data,
        },
        null,
        0,
      ),
    );
    process.exit(2);
  }

  const message = error instanceof Error ? error.message : String(error);
  console.error(JSON.stringify({ error: message }, null, 0));
  process.exit(1);
}

async function main() {
  const strippedHuman = stripFlag(process.argv.slice(2), "--human");
  const args = strippedHuman.args;
  const human = strippedHuman.found;

  if (args.length === 0 || args[0] === "-h" || args[0] === "--help" || args[0] === "help") {
    console.log(usage());
    process.exit(0);
  }

  const command = args[0];
  const commandArgs = args.slice(1);

  const config = loadConfig();
  const api = createApiClient(config);

  let result;

  switch (command) {
    case "list":
      result = await cmdList(api, commandArgs);
      break;
    case "status":
      result = await cmdStatus(api, commandArgs);
      break;
    case "dispatch":
      result = await cmdDispatch(api, config, commandArgs);
      break;
    case "stop":
      result = await cmdStop(api, commandArgs);
      break;
    case "events":
      result = await cmdEvents(api, commandArgs);
      break;
    case "messages":
      result = await cmdMessages(api, commandArgs);
      break;
    case "trace":
      result = await cmdTrace(api, commandArgs);
      break;
    case "review":
      result = await cmdReview(api, config, commandArgs);
      break;
    case "latest":
      result = await cmdLatest(api, commandArgs);
      break;
    default:
      throw new CliError(`Unknown command: ${command}\n\n${usage()}`);
  }

  emitResult(result, human);
}

main().catch(emitError);
