#!/usr/bin/env npx tsx
/**
 * Quick smoke test for the policy engine.
 */

import { PolicyEngine, parseBashCommand } from "./src/policy.js";

function test(name: string, fn: () => void): void {
  try {
    fn();
    console.log(`✅ ${name}`);
  } catch (err: any) {
    console.log(`❌ ${name}: ${err.message}`);
  }
}

function assert(condition: boolean, msg: string): void {
  if (!condition) throw new Error(msg);
}

// ─── Bash Parsing ───

console.log("\n--- Bash Command Parsing ---\n");

test("simple command", () => {
  const p = parseBashCommand("ls -la");
  assert(p.executable === "ls", `expected "ls", got "${p.executable}"`);
  assert(p.args[0] === "-la", `expected "-la", got "${p.args[0]}"`);
  assert(!p.hasPipe, "should not have pipe");
});

test("pipe detection", () => {
  const p = parseBashCommand("cat foo.txt | grep bar");
  assert(p.executable === "cat", `expected "cat", got "${p.executable}"`);
  assert(p.hasPipe, "should have pipe");
});

test("subshell detection", () => {
  const p = parseBashCommand("echo $(whoami)");
  assert(p.hasSubshell, "should have subshell");
});

test("redirect detection", () => {
  const p = parseBashCommand("echo hello > out.txt");
  assert(p.hasRedirect, "should have redirect");
});

test("env var prefix stripping", () => {
  const p = parseBashCommand("FOO=bar npm test");
  assert(p.executable === "npm", `expected "npm", got "${p.executable}"`);
});

test("quoted args", () => {
  const p = parseBashCommand('grep "hello world" file.txt');
  assert(p.executable === "grep", `expected "grep", got "${p.executable}"`);
  assert(p.args[0] === "hello world", `expected "hello world", got "${p.args[0]}"`);
});

// ─── Policy Engine (admin preset) ───

console.log("\n--- Policy Engine (admin) ---\n");

const admin = new PolicyEngine("admin");

test("ls is auto-allowed", () => {
  const d = admin.evaluate({ tool: "bash", input: { command: "ls -la" }, toolCallId: "1" });
  assert(d.action === "allow", `expected allow, got ${d.action}`);
});

test("read is auto-allowed", () => {
  const d = admin.evaluate({ tool: "read", input: { path: "src/index.ts" }, toolCallId: "2" });
  assert(d.action === "allow", `expected allow, got ${d.action}`);
});

test("sudo is denied", () => {
  const d = admin.evaluate({ tool: "bash", input: { command: "sudo rm -rf /" }, toolCallId: "3" });
  assert(d.action === "deny", `expected deny, got ${d.action}`);
});

test("git status is auto-allowed", () => {
  const d = admin.evaluate({ tool: "bash", input: { command: "git status" }, toolCallId: "4" });
  assert(d.action === "allow", `expected allow, got ${d.action}`);
});

test("git push triggers ask", () => {
  const d = admin.evaluate({ tool: "bash", input: { command: "git push origin main" }, toolCallId: "5" });
  assert(d.action === "ask", `expected ask, got ${d.action}: ${d.reason}`);
});

test("npm install triggers ask", () => {
  const d = admin.evaluate({ tool: "bash", input: { command: "npm install express" }, toolCallId: "6" });
  assert(d.action === "ask", `expected ask, got ${d.action}: ${d.reason}`);
});

test("pipe triggers ask (structural)", () => {
  const d = admin.evaluate({ tool: "bash", input: { command: "cat file | bash" }, toolCallId: "7" });
  assert(d.action === "ask", `expected ask, got ${d.action}: ${d.reason}`);
  assert(d.risk === "medium" || d.risk === "high", `expected medium/high risk, got ${d.risk}`);
});

test("write to .env is denied", () => {
  const d = admin.evaluate({ tool: "write", input: { path: "/project/.env.local" }, toolCallId: "8" });
  assert(d.action === "deny", `expected deny, got ${d.action}: ${d.reason}`);
});

test("write to normal file triggers ask", () => {
  const d = admin.evaluate({ tool: "write", input: { path: "src/main.ts" }, toolCallId: "9" });
  assert(d.action === "ask", `expected ask, got ${d.action}: ${d.reason}`);
});

test("grep tool is auto-allowed", () => {
  const d = admin.evaluate({ tool: "grep", input: { pattern: "TODO" }, toolCallId: "10" });
  assert(d.action === "allow", `expected allow, got ${d.action}`);
});

test("unknown tool triggers default (ask)", () => {
  const d = admin.evaluate({ tool: "custom_tool", input: { foo: "bar" }, toolCallId: "11" });
  assert(d.action === "ask", `expected ask, got ${d.action}`);
});

// ─── Policy Engine (restricted preset) ───

console.log("\n--- Policy Engine (restricted) ---\n");

const restricted = new PolicyEngine("restricted");

test("read is allowed", () => {
  const d = restricted.evaluate({ tool: "read", input: { path: "file.txt" }, toolCallId: "20" });
  assert(d.action === "allow", `expected allow, got ${d.action}`);
});

test("bash is denied", () => {
  const d = restricted.evaluate({ tool: "bash", input: { command: "ls" }, toolCallId: "21" });
  assert(d.action === "deny", `expected deny, got ${d.action}`);
});

test("write is denied", () => {
  const d = restricted.evaluate({ tool: "write", input: { path: "file.txt" }, toolCallId: "22" });
  assert(d.action === "deny", `expected deny, got ${d.action}`);
});

// ─── Display Summary ───

console.log("\n--- Display Summary ---\n");

test("bash display", () => {
  const s = admin.formatDisplaySummary({ tool: "bash", input: { command: "git push origin main" }, toolCallId: "x" });
  assert(s === "git push origin main", `got "${s}"`);
});

test("read display", () => {
  const s = admin.formatDisplaySummary({ tool: "read", input: { path: "src/index.ts" }, toolCallId: "x" });
  assert(s === "Read src/index.ts", `got "${s}"`);
});

console.log("\n--- Done ---\n");
