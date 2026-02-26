#!/usr/bin/env node
/**
 * dispatch.mjs — Create and prompt an oppi session via REST + WebSocket.
 *
 * Usage:
 *   node dispatch.mjs --workspace <id|name> --prompt "..." [--name "..."] [--model "..."] [--todo "TODO-xxxxxxxx"] [--context-file <path>]
 *
 * Reads oppi config from ~/.config/oppi/config.json for auth token and port.
 * Creates a session, starts it, sends the prompt, then exits.
 * The session continues running — monitor it from the oppi iOS app.
 *
 * Exit codes:
 *   0  — session created and prompt sent
 *   1  — argument/config error
 *   2  — API error (create/resume/ws)
 */

import { existsSync, readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

// ---------------------------------------------------------------------------
// Args
// ---------------------------------------------------------------------------

const args = process.argv.slice(2);
function flag(name) {
  const i = args.indexOf(name);
  if (i === -1) return undefined;
  return args[i + 1];
}

function flagValues(name) {
  const values = [];
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] !== name) continue;
    const value = args[i + 1];
    if (!value || value.startsWith("--")) continue;
    values.push(value);
  }
  return values;
}

const workspaceArg = flag("--workspace");
const prompt = flag("--prompt");
const sessionName = flag("--name");
const model = flag("--model");
const thinkingLevel = flag("--thinking");
const todoArg = flag("--todo");
const contextFiles = flagValues("--context-file");

if (!workspaceArg || !prompt) {
  console.error("Usage: dispatch.mjs --workspace <id|name> --prompt \"...\" [--name \"...\"] [--model \"...\"] [--todo \"TODO-xxxxxxxx\"] [--context-file <path>]");
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const configPath = join(homedir(), ".config", "oppi", "config.json");
let config;
try {
  config = JSON.parse(readFileSync(configPath, "utf8"));
} catch {
  console.error(`Failed to read oppi config at ${configPath}`);
  process.exit(1);
}

const token = config.token;
const port = config.port || 7749;
const host = "127.0.0.1";
const baseUrl = `http://${host}:${port}`;

if (!token) {
  console.error("No token found in oppi config");
  process.exit(1);
}

const headers = {
  Authorization: `Bearer ${token}`,
  "Content-Type": "application/json",
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function api(method, path, body) {
  const res = await fetch(`${baseUrl}${path}`, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json();
  if (!res.ok) {
    throw new Error(`${method} ${path} ${res.status}: ${data.error || JSON.stringify(data)}`);
  }
  return data;
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
    console.error(`error: context file not found: ${pathArg}`);
    process.exit(1);
  }

  let content = "";
  try {
    content = readFileSync(resolvedPath, "utf8");
  } catch (error) {
    console.error(`error: failed to read context file ${resolvedPath}: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  }

  const maxChars = 80_000;
  const trimmed = content.trim();
  if (trimmed.length === 0) {
    console.error(`error: context file is empty: ${resolvedPath}`);
    process.exit(1);
  }

  const finalContent = trimmed.slice(0, maxChars);
  const truncated = trimmed.length > maxChars;
  return { path: resolvedPath, content: finalContent, truncated };
}

function extractTodoIds(text) {
  if (!text) return [];
  const ids = new Set();
  const regex = /TODO-([a-zA-Z0-9]{6,40})\b/g;
  let m;
  while ((m = regex.exec(text)) !== null) {
    const normalized = normalizeTodoId(m[1]);
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
    // git may return a relative path (usually .git)
    if (out.startsWith("/")) return out;
    return join(dirPath, out);
  } catch {
    return undefined;
  }
}

function todoFileCandidates(todoId, workspace) {
  const candidates = [];

  // Caller repo first (usually where dispatch command is run)
  candidates.push(join(process.cwd(), ".pi", "todos", `${todoId}.md`));

  // Workspace mount direct
  if (workspace?.hostMount) {
    candidates.push(join(workspace.hostMount, ".pi", "todos", `${todoId}.md`));

    // Worktree fallback: resolve git common dir and map back to main repo root
    const commonDir = gitCommonDirFor(workspace.hostMount);
    if (commonDir) {
      const repoRoot = commonDir.endsWith("/.git") ? dirname(commonDir) : dirname(commonDir);
      candidates.push(join(repoRoot, ".pi", "todos", `${todoId}.md`));
    }
  }

  // Home fallback
  candidates.push(join(homedir(), ".pi", "todos", `${todoId}.md`));

  // Deduplicate while preserving order
  const seen = new Set();
  const unique = [];
  for (const p of candidates) {
    if (!seen.has(p)) {
      seen.add(p);
      unique.push(p);
    }
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
      // try next candidate
    }
  }
  return undefined;
}

function buildPromptWithTodoContext(promptText, workspace, explicitTodo) {
  const todoIds = explicitTodo ? [normalizeTodoId(explicitTodo)].filter(Boolean) : extractTodoIds(promptText);
  if (todoIds.length === 0) {
    return { finalPrompt: promptText, injectedTodos: [], missingTodos: [] };
  }

  const loaded = [];
  const missing = [];

  for (const todoId of todoIds) {
    const todo = loadTodoMarkdown(todoId, workspace);
    if (todo) {
      loaded.push(todo);
    } else {
      missing.push(todoId);
    }
  }

  if (explicitTodo && loaded.length === 0) {
    console.error(`error: --todo ${explicitTodo} was provided, but no matching todo file was found.`);
    process.exit(1);
  }

  if (missing.length > 0) {
    console.error(`warning: could not resolve TODO context for: ${missing.map((id) => `TODO-${id}`).join(", ")}`);
  }

  if (loaded.length === 0) {
    return { finalPrompt: promptText, injectedTodos: [], missingTodos: missing };
  }

  const todoContext = loaded
    .map((todo) => {
      return [
        `---`,
        `Full TODO context: TODO-${todo.id}`,
        `Source: ${todo.path}`,
        "",
        todo.content,
      ].join("\n");
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

  const loaded = paths.map((p) => loadContextFile(p));
  const context = loaded
    .map((file) => {
      return [
        "---",
        `Attached file context: ${file.path}`,
        file.truncated ? "(truncated to 80k chars)" : "",
        "",
        file.content,
      ].filter(Boolean).join("\n");
    })
    .join("\n\n");

  return {
    finalPrompt: `${promptText}\n\n${context}`,
    injectedFiles: loaded.map((file) => ({ path: file.path, truncated: file.truncated })),
  };
}

// ---------------------------------------------------------------------------
// Resolve workspace
// ---------------------------------------------------------------------------

const { workspaces } = await api("GET", "/workspaces");
const workspace = workspaces.find(
  (w) => w.id === workspaceArg || w.name.toLowerCase() === workspaceArg.toLowerCase(),
);
if (!workspace) {
  console.error(`Workspace not found: ${workspaceArg}`);
  console.error(`Available: ${workspaces.map((w) => `${w.name} (${w.id})`).join(", ")}`);
  process.exit(1);
}

const todoPrompt = buildPromptWithTodoContext(prompt, workspace, todoArg);
const filePrompt = buildPromptWithFileContext(todoPrompt.finalPrompt, contextFiles);

const finalPrompt = filePrompt.finalPrompt;
const injectedTodos = todoPrompt.injectedTodos;
const missingTodos = todoPrompt.missingTodos;
const injectedFiles = filePrompt.injectedFiles;

if (injectedTodos.length > 0) {
  console.error(
    `info: injected TODO context for ${injectedTodos.map((t) => `TODO-${t.id}`).join(", ")}`,
  );
}
if (missingTodos.length > 0) {
  console.error(
    `warning: dispatching without full context for ${missingTodos.map((id) => `TODO-${id}`).join(", ")}`,
  );
}
if (injectedFiles.length > 0) {
  console.error(
    `info: injected file context: ${injectedFiles.map((f) => f.path).join(", ")}`,
  );
}

// ---------------------------------------------------------------------------
// Create session
// ---------------------------------------------------------------------------

const createBody = {};
if (sessionName) createBody.name = sessionName;
if (model) createBody.model = model;

const { session } = await api("POST", `/workspaces/${workspace.id}/sessions`, createBody);
const sessionId = session.id;

// ---------------------------------------------------------------------------
// Resume (start pi process)
// ---------------------------------------------------------------------------

await api("POST", `/workspaces/${workspace.id}/sessions/${sessionId}/resume`);

// ---------------------------------------------------------------------------
// WebSocket: subscribe + prompt, then disconnect
// ---------------------------------------------------------------------------

// Dynamic import ws — try bare specifier, then resolve relative to this script's
// location (works when this file lives inside the oppi server's skills/ directory).
const scriptDir = dirname(new URL(import.meta.url).pathname);
const wsModuleCandidates = [
  "ws",
  join(scriptDir, "..", "..", "node_modules", "ws", "index.js"),
];

let WebSocket;
for (const candidate of wsModuleCandidates) {
  try {
    const mod = await import(candidate);
    // ws CJS exports: mod.default has { WebSocket, ... } or mod.WebSocket directly
    WebSocket = mod.WebSocket || mod.default?.WebSocket || mod.default;
    if (typeof WebSocket === "function") break;
    WebSocket = undefined;
  } catch {
    continue;
  }
}

if (!WebSocket) {
  // Fallback: session is created and started, just can't send prompt via WS
  console.error("Warning: ws module not found. Session started but prompt not sent.");
  console.log(JSON.stringify({
    sessionId,
    workspaceId: workspace.id,
    workspaceName: workspace.name,
    prompted: false,
    injectedTodos: injectedTodos.map((todo) => `TODO-${todo.id}`),
    injectedFiles: injectedFiles.map((file) => file.path),
  }));
  process.exit(0);
}

await new Promise((resolve, reject) => {
  const ws = new WebSocket(`ws://${host}:${port}/stream`, {
    headers: { Authorization: `Bearer ${token}` },
  });

  const timeout = setTimeout(() => {
    ws.close();
    reject(new Error("WebSocket timeout (15s)"));
  }, 15000);

  let subscribed = false;
  let prompted = false;

  ws.on("open", () => {
    ws.send(JSON.stringify({ type: "subscribe", sessionId, level: "full" }));
  });

  ws.on("message", (data) => {
    const msg = JSON.parse(data.toString());

    if (msg.type === "command_result" && msg.command === "subscribe" && msg.success) {
      subscribed = true;
      // Set thinking level if specified
      if (thinkingLevel) {
        ws.send(JSON.stringify({
          type: "set_thinking_level",
          sessionId,
          level: thinkingLevel,
        }));
      }
      // Send prompt with requestId so we get a command_result back
      ws.send(JSON.stringify({
        type: "prompt",
        sessionId,
        message: finalPrompt,
        requestId: "dispatch-prompt",
      }));
    }

    // Prompt accepted — agent runs autonomously from here
    if (msg.type === "command_result" && msg.requestId === "dispatch-prompt" && msg.success) {
      prompted = true;
      clearTimeout(timeout);
      ws.close();
      resolve();
    }

    // Also accept agent_start as confirmation (belt + suspenders)
    if (!prompted && subscribed && msg.type === "agent_start") {
      prompted = true;
      clearTimeout(timeout);
      ws.close();
      resolve();
    }

    if (msg.type === "error" && !prompted) {
      clearTimeout(timeout);
      ws.close();
      reject(new Error(msg.error || "Unknown WS error"));
    }
  });

  ws.on("error", (err) => {
    clearTimeout(timeout);
    reject(err);
  });
});

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

console.log(JSON.stringify({
  sessionId,
  workspaceId: workspace.id,
  workspaceName: workspace.name,
  model: session.model,
  prompted: true,
  injectedTodos: injectedTodos.map((todo) => `TODO-${todo.id}`),
  injectedFiles: injectedFiles.map((file) => file.path),
  promptChars: finalPrompt.length,
}));
