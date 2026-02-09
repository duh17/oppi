/**
 * Test: buildSessionContext matches pi TUI behavior.
 *
 * Reads a real JSONL file with compaction and verifies that:
 * 1. Pre-compaction messages are hidden
 * 2. Compaction summary is emitted first
 * 3. Kept messages + post-compaction messages are correct
 * 4. Entry count matches pi TUI expectations
 */

import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { parseJsonl } from "./src/trace.js";

// ─── Test Helpers ───

let passed = 0;
let failed = 0;

function assert(condition: boolean, msg: string): void {
  if (condition) {
    passed++;
    console.log(`  PASS: ${msg}`);
  } else {
    failed++;
    console.log(`  FAIL: ${msg}`);
  }
}

// ─── Test 1: Compacted session ───

console.log("\n=== Test 1: Session with compaction ===");

const compactedFile = join(
  process.env.HOME!,
  ".pi/agent/sessions/--Users-chenda-.config-dotfiles--/2026-02-04T16-53-14-033Z_c7ce61c7-b5b6-49e6-aaa0-427fc3e68a10.jsonl",
);

if (existsSync(compactedFile)) {
  const content = readFileSync(compactedFile, "utf-8");
  const rawLineCount = content.split("\n").filter(l => l.trim()).length;
  const rawMessageCount = content.split("\n")
    .filter(l => l.trim())
    .filter(l => { try { return JSON.parse(l).type === "message"; } catch { return false; } })
    .length;

  const events = parseJsonl(content);

  console.log(`  Raw JSONL lines: ${rawLineCount}`);
  console.log(`  Raw message entries: ${rawMessageCount}`);
  console.log(`  Session context events: ${events.length}`);

  // Must be significantly fewer than raw messages (compaction hides old ones)
  assert(events.length < rawMessageCount, `Context (${events.length}) < raw messages (${rawMessageCount})`);
  assert(events.length < rawMessageCount / 2, `Context is less than half of raw messages`);

  // First event should be compaction summary
  assert(events[0]?.type === "compaction", `First event is compaction summary (got: ${events[0]?.type})`);
  assert(events[0]?.text?.includes("compacted") || false, `Compaction text mentions 'compacted'`);

  // Should have user and assistant messages
  const userCount = events.filter(e => e.type === "user").length;
  const assistantCount = events.filter(e => e.type === "assistant").length;
  const toolCallCount = events.filter(e => e.type === "toolCall").length;
  const toolResultCount = events.filter(e => e.type === "toolResult").length;

  console.log(`  Users: ${userCount}, Assistants: ${assistantCount}, Tools: ${toolCallCount}, Results: ${toolResultCount}`);

  assert(userCount > 0, "Has user messages");
  assert(assistantCount > 0, "Has assistant messages");
  assert(toolCallCount > 0, "Has tool calls");
  assert(toolResultCount > 0, "Has tool results");

  // Verify no duplicate IDs (except intentional sub-IDs like entry-text-0)
  const ids = events.map(e => e.id);
  const uniqueIds = new Set(ids);
  assert(ids.length === uniqueIds.size, `All event IDs are unique (${ids.length} total, ${uniqueIds.size} unique)`);
} else {
  console.log("  SKIP: Compacted session file not found");
}

// ─── Test 2: Simple session (no compaction) ───

console.log("\n=== Test 2: Session without compaction ===");

const simpleFile = join(
  process.env.HOME!,
  ".pi/agent/sessions/--Users-chenda-workspace-pios--/2026-02-09T02-20-19-802Z_d8639a2a-c988-4a4f-aa8e-d3f8dc0505a2.jsonl",
);

if (existsSync(simpleFile)) {
  const content = readFileSync(simpleFile, "utf-8");
  const rawLines = content.split("\n").filter(l => l.trim());
  const rawMessageCount = rawLines
    .filter(l => { try { return JSON.parse(l).type === "message"; } catch { return false; } })
    .length;

  const events = parseJsonl(content);

  console.log(`  Raw message entries: ${rawMessageCount}`);
  console.log(`  Session context events: ${events.length}`);

  // No compaction → first event should NOT be compaction
  assert(events[0]?.type !== "compaction", `First event is not compaction (got: ${events[0]?.type})`);

  // Should have model_change and thinking_level_change as system events
  const systemEvents = events.filter(e => e.type === "system");
  console.log(`  System events: ${systemEvents.length}`);
  const hasModelChange = systemEvents.some(e => e.text?.includes("Model:"));
  const hasThinkingChange = systemEvents.some(e => e.text?.includes("Thinking level:"));
  assert(hasModelChange, "Has model change system event");
  assert(hasThinkingChange, "Has thinking level system event");
} else {
  console.log("  SKIP: Simple session file not found");
}

// ─── Test 3: Synthetic compaction test ───

console.log("\n=== Test 3: Synthetic compaction (controlled) ===");

const syntheticJsonl = [
  '{"type":"session","version":3,"id":"test-session","timestamp":"2026-01-01T00:00:00Z","cwd":"/tmp"}',
  '{"type":"message","id":"m1","parentId":null,"timestamp":"2026-01-01T00:01:00Z","message":{"role":"user","content":"old question"}}',
  '{"type":"message","id":"m2","parentId":"m1","timestamp":"2026-01-01T00:02:00Z","message":{"role":"assistant","content":[{"type":"text","text":"old answer"}]}}',
  '{"type":"message","id":"m3","parentId":"m2","timestamp":"2026-01-01T00:03:00Z","message":{"role":"user","content":"another old question"}}',
  '{"type":"message","id":"m4","parentId":"m3","timestamp":"2026-01-01T00:04:00Z","message":{"role":"assistant","content":[{"type":"text","text":"another old answer"}]}}',
  // Compaction: keep from m3 onward
  '{"type":"compaction","id":"c1","parentId":"m4","timestamp":"2026-01-01T00:05:00Z","summary":"User asked two questions about testing","firstKeptEntryId":"m3","tokensBefore":50000}',
  '{"type":"message","id":"m5","parentId":"c1","timestamp":"2026-01-01T00:06:00Z","message":{"role":"user","content":"new question"}}',
  '{"type":"message","id":"m6","parentId":"m5","timestamp":"2026-01-01T00:07:00Z","message":{"role":"assistant","content":[{"type":"text","text":"new answer"}]}}',
].join("\n");

const syntheticEvents = parseJsonl(syntheticJsonl);

console.log(`  Events: ${syntheticEvents.length}`);
for (const e of syntheticEvents) {
  console.log(`    ${e.type}: ${e.text?.substring(0, 60) || e.id}`);
}

// Compaction summary first
assert(syntheticEvents[0]?.type === "compaction", "First event is compaction");
assert(syntheticEvents[0]?.text?.includes("50,000 tokens") || false, "Compaction shows token count");

// Kept messages: m3 (user) and m4 (assistant) — before compaction, from firstKeptEntryId
assert(syntheticEvents[1]?.type === "user", "Second event is kept user message");
assert(syntheticEvents[1]?.text === "another old question", "Kept user text correct");
assert(syntheticEvents[2]?.type === "assistant", "Third event is kept assistant message");
assert(syntheticEvents[2]?.text === "another old answer", "Kept assistant text correct");

// Post-compaction: m5, m6
assert(syntheticEvents[3]?.type === "user", "Fourth event is post-compaction user");
assert(syntheticEvents[3]?.text === "new question", "Post-compaction user text correct");
assert(syntheticEvents[4]?.type === "assistant", "Fifth event is post-compaction assistant");
assert(syntheticEvents[4]?.text === "new answer", "Post-compaction assistant text correct");

// Hidden messages: m1 and m2 should NOT appear
assert(syntheticEvents.length === 5, `Exactly 5 events (got ${syntheticEvents.length})`);
const allTexts = syntheticEvents.map(e => e.text || "");
assert(!allTexts.some(t => t.includes("old question") && !t.includes("another")), "m1 (old question) is hidden");
assert(!allTexts.some(t => t.includes("old answer") && !t.includes("another")), "m2 (old answer) is hidden");

// ─── Test 4: Tool call matching ───

console.log("\n=== Test 4: Tool call / result matching ===");

const toolJsonl = [
  '{"type":"session","version":3,"id":"test-tools","timestamp":"2026-01-01T00:00:00Z","cwd":"/tmp"}',
  '{"type":"message","id":"u1","parentId":null,"timestamp":"2026-01-01T00:01:00Z","message":{"role":"user","content":"list files"}}',
  '{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-01-01T00:02:00Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"I should use bash to list files"},{"type":"text","text":"Let me check."},{"type":"toolCall","id":"tc1","name":"bash","arguments":{"command":"ls -la"}}]}}',
  '{"type":"message","id":"r1","parentId":"a1","timestamp":"2026-01-01T00:03:00Z","message":{"role":"toolResult","content":[{"type":"text","text":"file1.txt\\nfile2.txt"}],"toolCallId":"tc1","toolName":"bash","isError":false}}',
  '{"type":"message","id":"a2","parentId":"r1","timestamp":"2026-01-01T00:04:00Z","message":{"role":"assistant","content":[{"type":"text","text":"Found 2 files."}]}}',
].join("\n");

const toolEvents = parseJsonl(toolJsonl);

console.log(`  Events: ${toolEvents.length}`);
for (const e of toolEvents) {
  const summary = e.text || e.thinking || e.tool || e.output || "";
  console.log(`    ${e.type}: ${summary.substring(0, 60)}`);
}

assert(toolEvents.length === 6, `6 events: user, thinking, assistant, toolCall, toolResult, assistant`);
assert(toolEvents[0]?.type === "user", "User message");
assert(toolEvents[1]?.type === "thinking", "Thinking block");
assert(toolEvents[2]?.type === "assistant", "Assistant text before tool");
assert(toolEvents[3]?.type === "toolCall", "Tool call");
assert(toolEvents[3]?.tool === "bash", "Tool is bash");
assert(toolEvents[4]?.type === "toolResult", "Tool result");
assert(toolEvents[4]?.toolCallId === "tc1", "Tool result links to tc1");
assert(toolEvents[5]?.type === "assistant", "Final assistant message");

// ─── Summary ───

console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
process.exit(failed > 0 ? 1 : 0);
