/**
 * SDK exploration spike — throwaway.
 *
 * Answers the open questions from the migration plan:
 * 1. Does createAgentSession() support all session options we need?
 * 2. Can we suppress extension auto-discovery?
 * 3. Multiple concurrent sessions — any singleton state?
 * 4. Session file location control?
 * 5. Extension factory for in-process permission gate?
 *
 * Run: cd server && npx tsx spike/sdk-session.ts
 */

import {
  createAgentSession,
  AgentSession,
  DefaultResourceLoader,
  AuthStorage,
  ModelRegistry,
  SessionManager,
  SettingsManager,
  getAgentDir,
  type AgentSessionEvent,
  type CreateAgentSessionOptions,
  type ExtensionFactory,
} from "@mariozechner/pi-coding-agent";
import { getModel } from "@mariozechner/pi-ai";
import { homedir } from "os";
import { join } from "path";

// ─── Q1: Basic session creation ───

async function testBasicSession() {
  console.log("\n=== Q1: Basic session creation ===");

  const cwd = join(homedir(), "workspace/oppi");
  const agentDir = getAgentDir();
  const authStorage = AuthStorage.create(join(agentDir, "auth.json"));
  const modelRegistry = new ModelRegistry(authStorage, join(agentDir, "models.json"));

  // Use in-memory session manager to avoid writing files
  const sessionManager = SessionManager.inMemory();
  const settingsManager = SettingsManager.create(cwd, agentDir);

  const model = getModel("anthropic", "claude-sonnet-4-20250514");

  const { session } = await createAgentSession({
    cwd,
    agentDir,
    authStorage,
    modelRegistry,
    model,
    thinkingLevel: "low",
    sessionManager,
    settingsManager,
  });

  console.log("  Session created:", {
    model: session.model?.name,
    thinkingLevel: session.thinkingLevel,
    isStreaming: session.isStreaming,
    sessionFile: session.sessionFile,
    sessionId: session.sessionId,
  });

  return session;
}

// ─── Q2: Extension suppression ───

async function testNoExtensions() {
  console.log("\n=== Q2: Extension suppression ===");

  const cwd = join(homedir(), "workspace/oppi");
  const agentDir = getAgentDir();

  // ResourceLoader with no extension paths should skip auto-discovery
  const loader = new DefaultResourceLoader({
    cwd,
    agentDir,
    settingsManager: SettingsManager.create(cwd, agentDir),
    // Empty extension paths = no extensions loaded
    additionalExtensionPaths: [],
  });
  await loader.reload();

  const skills = await loader.getSkills();
  const extensions = await loader.getExtensions();
  console.log("  Skills found:", skills.length);
  console.log("  Extensions found:", extensions.length);

  // Does it still auto-discover from ~/.pi/agent/extensions?
  // If so, we need to explicitly override.
  return { skills: skills.length, extensions: extensions.length };
}

// ─── Q3: Concurrent sessions ───

async function testConcurrentSessions() {
  console.log("\n=== Q3: Concurrent sessions ===");

  const opts = (id: string): CreateAgentSessionOptions => ({
    cwd: join(homedir(), "workspace/oppi"),
    model: getModel("anthropic", "claude-sonnet-4-20250514"),
    thinkingLevel: "low",
    sessionManager: SessionManager.inMemory(),
  });

  const [r1, r2] = await Promise.all([
    createAgentSession(opts("s1")),
    createAgentSession(opts("s2")),
  ]);

  console.log("  Session 1:", r1.session.sessionId);
  console.log("  Session 2:", r2.session.sessionId);
  console.log("  Different IDs:", r1.session.sessionId !== r2.session.sessionId);

  // Verify independent state
  r1.session.setThinkingLevel("high");
  console.log("  S1 thinking:", r1.session.thinkingLevel);
  console.log("  S2 thinking:", r2.session.thinkingLevel);
  console.log("  Independent:", r1.session.thinkingLevel !== r2.session.thinkingLevel);

  r1.session.dispose();
  r2.session.dispose();
}

// ─── Q4: Session file location ───

async function testSessionFileControl() {
  console.log("\n=== Q4: Session file location ===");

  // In-memory: no file
  const inMemory = SessionManager.inMemory();
  console.log("  InMemory manager:", typeof inMemory);

  // File-based: specify path
  const tmpDir = join(homedir(), ".oppi-spike-test");
  const fileManager = SessionManager.create(tmpDir);
  console.log("  File manager for:", tmpDir);

  // Check if we can get session list
  const sessions = await SessionManager.list(tmpDir);
  console.log("  Existing sessions:", sessions.length);
}

// ─── Q5: Extension factory for permission gate ───

async function testExtensionFactory() {
  console.log("\n=== Q5: Extension factory (permission gate) ===");

  // Can we inject a custom extension that intercepts tool calls?
  // The ExtensionFactory type should allow this.

  // Check if createAgentSession accepts extension factories directly
  // or if we need to go through ResourceLoader

  const cwd = join(homedir(), "workspace/oppi");
  const agentDir = getAgentDir();
  const loader = new DefaultResourceLoader({
    cwd,
    agentDir,
    settingsManager: SettingsManager.create(cwd, agentDir),
    additionalExtensionPaths: [],
  });
  await loader.reload();

  console.log("  ResourceLoader type:", typeof loader);
  console.log("  Has getExtensions:", typeof loader.getExtensions);

  // The ExtensionFactory type from the SDK:
  // type ExtensionFactory = (api: ExtensionAPI) => void | Promise<void>;
  // We'd register a factory that hooks tool_call events.
  console.log("  ExtensionFactory is a function type — we can create one inline");
}

// ─── Q6: Event shape comparison ───

async function testEventShapes() {
  console.log("\n=== Q6: Event shapes (subscribe + prompt) ===");

  const { session } = await createAgentSession({
    cwd: join(homedir(), "workspace/oppi"),
    model: getModel("anthropic", "claude-sonnet-4-20250514"),
    thinkingLevel: "low",
    sessionManager: SessionManager.inMemory(),
  });

  const events: AgentSessionEvent[] = [];
  const unsub = session.subscribe((event) => {
    events.push(event);
  });

  try {
    await session.prompt("Say exactly: hello world");
  } catch (e) {
    console.log("  Prompt error:", e);
  }

  unsub();

  console.log("  Events received:", events.length);
  for (const event of events) {
    const type = event.type;
    if (type === "message_update") {
      const subType = event.assistantMessageEvent?.type;
      const delta = event.assistantMessageEvent?.delta;
      const preview = typeof delta === "string" && delta.length > 40
        ? delta.substring(0, 40) + "..."
        : delta;
      console.log(`  ${type} -> ${subType}: ${JSON.stringify(preview)}`);
    } else if (type === "message_end") {
      const msg = event.message;
      const content = msg?.content;
      if (Array.isArray(content)) {
        const contentTypes = content.map((b: any) => b.type);
        console.log(`  ${type} content types: [${contentTypes.join(", ")}]`);
      } else {
        const preview = typeof content === "string" && content.length > 60
          ? content.substring(0, 60) + "..."
          : content;
        console.log(`  ${type} content: ${JSON.stringify(preview)} (role: ${msg?.role})`);
      }
    } else if (type === "tool_execution_start") {
      console.log(`  ${type}: ${event.toolName}(${JSON.stringify(event.args).substring(0, 60)})`);
    } else {
      console.log(`  ${type}`);
    }
  }

  session.dispose();
}

// ─── Run ───

async function main() {
  console.log("SDK Exploration Spike");
  console.log("====================");

  try {
    const session = await testBasicSession();
    session.dispose();
  } catch (e) {
    console.error("Q1 failed:", e);
  }

  try {
    await testNoExtensions();
  } catch (e) {
    console.error("Q2 failed:", e);
  }

  try {
    await testConcurrentSessions();
  } catch (e) {
    console.error("Q3 failed:", e);
  }

  try {
    await testSessionFileControl();
  } catch (e) {
    console.error("Q4 failed:", e);
  }

  try {
    await testExtensionFactory();
  } catch (e) {
    console.error("Q5 failed:", e);
  }

  try {
    await testEventShapes();
  } catch (e) {
    console.error("Q6 failed:", e);
  }

  console.log("\n=== Done ===");
  process.exit(0);
}

main();
