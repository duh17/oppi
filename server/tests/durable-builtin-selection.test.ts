import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import {
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall,
  type FauxResponseStep,
} from "@earendil-works/pi-ai/providers/faux";
import type { NotifyInput } from "../extensions/durable/notify/contract.js";
import { AgentDoc, type ConversationId, type Harness } from "@earendil-works/pi-durable";
import { ensureControlConversationSession } from "../src/control-conversation-service.js";
import { SessionHost } from "../src/durable-harness.js";
import type { GondolinVm } from "../src/gondolin-ops.js";
import { LiveVoiceSpeech, type RunOutcome } from "../src/live-voice-speech.js";
import { SdkBackend } from "../src/sdk-backend.js";
import { SessionManager } from "../src/sessions.js";
import { Storage } from "../src/storage.js";
import type { ServerMessage, Session } from "../src/types.js";

// What each kind of durable session selects, pinned by name: the built-in extensions, the tools
// offered, and the prompt sections, in order, when the conversation is created and after it
// attaches again (a bound conversation's `{ add }` edit). Loading built-ins from packages must
// not change any of it.

/**
 * Recorded from the server before built-ins became packages (main at c68f8ca64). Note the
 * reattached host and child sessions: their `{ add }` edit applies to the Harness default
 * selection, which includes the sandbox tools; only their `read` wrap is active, and it reads
 * the host as before.
 */
const PINNED = {
  host: {
    created: {
      stored: [
        "coding-tools",
        "ask",
        "working-words",
        "background-jobs",
        "project-context",
        "sql-explorer",
        "oppi.sessions",
      ],
      extensions: [
        "coding-tools",
        "ask",
        "working-words",
        "background-jobs",
        "project-context",
        "sql-explorer",
        "oppi.sessions",
      ],
      tools: [
        "read",
        "write",
        "edit",
        "bash",
        "ask",
        "background_job",
        "sqlite_schema",
        "sqlite_query",
        "subagent",
      ],
      sections: [
        "ask-guidelines",
        "background-jobs",
        "project_context",
        "skills",
        "sessions",
        "instructions",
      ],
    },
    reattached: {
      stored: {
        add: [
          "ask",
          "working-words",
          "background-jobs",
          "oppi.sessions",
          "project-context",
          "sql-explorer",
        ],
        // No device registered for pushes: no `notify`.
        remove: ["oppi.notify"],
      },
      extensions: [
        "coding-tools",
        "oppi.sandbox-tools",
        "ask",
        "working-words",
        "background-jobs",
        "oppi.sessions",
        "project-context",
        "sql-explorer",
      ],
      tools: [
        "read",
        "write",
        "edit",
        "bash",
        "ask",
        "background_job",
        "sqlite_schema",
        "sqlite_query",
        "subagent",
      ],
      sections: [
        "ask-guidelines",
        "background-jobs",
        "sessions",
        "project_context",
        "skills",
        "instructions",
      ],
    },
  },
  sandbox: {
    created: {
      stored: [
        "coding-tools",
        "oppi.sandbox-tools",
        "ask",
        "working-words",
        "background-jobs",
        "project-context",
        "sql-explorer",
        "oppi.sessions",
      ],
      extensions: [
        "coding-tools",
        "oppi.sandbox-tools",
        "ask",
        "working-words",
        "background-jobs",
        "project-context",
        "sql-explorer",
        "oppi.sessions",
      ],
      tools: [
        "read",
        "write",
        "edit",
        "bash",
        "ls",
        "find",
        "grep",
        "ask",
        "background_job",
        "sqlite_schema",
        "sqlite_query",
        "subagent",
      ],
      sections: [
        "ask-guidelines",
        "background-jobs",
        "project_context",
        "skills",
        "sessions",
        "instructions",
      ],
    },
    reattached: {
      stored: {
        add: [
          "ask",
          "working-words",
          "background-jobs",
          "oppi.sessions",
          "project-context",
          "sql-explorer",
        ],
        remove: ["oppi.notify"],
      },
      extensions: [
        "coding-tools",
        "oppi.sandbox-tools",
        "ask",
        "working-words",
        "background-jobs",
        "oppi.sessions",
        "project-context",
        "sql-explorer",
      ],
      tools: [
        "read",
        "write",
        "edit",
        "bash",
        "ls",
        "find",
        "grep",
        "ask",
        "background_job",
        "sqlite_schema",
        "sqlite_query",
        "subagent",
      ],
      sections: [
        "ask-guidelines",
        "background-jobs",
        "sessions",
        "project_context",
        "skills",
        "instructions",
      ],
    },
  },
  child: {
    created: {
      stored: [
        "coding-tools",
        "ask",
        "working-words",
        "background-jobs",
        "project-context",
        "sql-explorer",
      ],
      extensions: [
        "coding-tools",
        "ask",
        "working-words",
        "background-jobs",
        "project-context",
        "sql-explorer",
      ],
      tools: [
        "read",
        "write",
        "edit",
        "bash",
        "ask",
        "background_job",
        "sqlite_schema",
        "sqlite_query",
      ],
      sections: ["ask-guidelines", "background-jobs", "project_context", "skills", "instructions"],
    },
    reattached: {
      stored: {
        add: ["ask", "working-words", "background-jobs", "project-context", "sql-explorer"],
        remove: ["oppi.sessions", "oppi.notify"],
      },
      extensions: [
        "coding-tools",
        "oppi.sandbox-tools",
        "ask",
        "working-words",
        "background-jobs",
        "project-context",
        "sql-explorer",
      ],
      tools: [
        "read",
        "write",
        "edit",
        "bash",
        "ask",
        "background_job",
        "sqlite_schema",
        "sqlite_query",
      ],
      sections: ["ask-guidelines", "background-jobs", "project_context", "skills", "instructions"],
    },
  },
  control: {
    created: {
      stored: ["ask", "working-words", "oppi.control", "codemode"],
      extensions: ["ask", "working-words", "oppi.control", "codemode"],
      tools: [
        "ask",
        "oppi",
        "agents_list",
        "agents_get",
        "agents_create",
        "agents_update",
        "agents_archive",
        "schedules_list",
        "schedules_get",
        "schedules_create",
        "schedules_update",
        "schedules_run",
        "sessions_create",
        "sessions_send",
        "sessions_wait",
        "sessions_response",
        "workspaces_list",
        "workspaces_get",
        "codemode",
      ],
      sections: ["ask-guidelines", "oppi-control", "codemode"],
    },
    reattached: {
      stored: ["ask", "working-words", "oppi.control", "codemode"],
      extensions: ["ask", "working-words", "oppi.control", "codemode"],
      tools: [
        "ask",
        "oppi",
        "agents_list",
        "agents_get",
        "agents_create",
        "agents_update",
        "agents_archive",
        "schedules_list",
        "schedules_get",
        "schedules_create",
        "schedules_update",
        "schedules_run",
        "sessions_create",
        "sessions_send",
        "sessions_wait",
        "sessions_response",
        "workspaces_list",
        "workspaces_get",
        "codemode",
      ],
      sections: ["ask-guidelines", "oppi-control", "codemode"],
    },
  },
};

const managers: SessionManager[] = [];
const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
afterEach(async () => {
  await Promise.all(managers.splice(0).map((manager) => manager.close()));
  vi.restoreAllMocks();
  if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
});

async function fixture(responses: FauxResponseStep[] = []) {
  const dir = mkdtempSync(join(tmpdir(), "oppi-durable-selection-"));
  // No user packages: only Oppi's own extensions.
  process.env.PI_CODING_AGENT_DIR = join(dir, "agent");
  const models = await ModelRuntime.create({
    authPath: join(dir, "auth.json"),
    modelsPath: null,
    modelsStorePath: join(dir, "models-cache.json"),
    refreshOnCreate: false,
  });
  const faux = fauxProvider();
  faux.setResponses(responses);
  models.registerNativeProvider(faux.provider);
  await models.setRuntimeApiKey("faux", "test-only-faux-credential");
  await models.refresh({ allowNetwork: false });
  vi.spyOn(ModelRuntime, "create").mockResolvedValue(models);
  vi.spyOn(SettingsManager, "create").mockImplementation(() =>
    SettingsManager.inMemory({
      defaultProvider: "faux",
      defaultModel: "faux-1",
      defaultThinkingLevel: "off",
      compaction: { enabled: false },
    }),
  );
  const opening = vi.spyOn(SessionHost.prototype, "open");
  const storage = new Storage(dir);
  storage.updateConfig({ experimental: { serverDurable: true } });
  const manager = new SessionManager(storage);
  managers.push(manager);
  await manager.resumeDurableSessions();
  return { dir, storage, manager, opening };
}

type Fixture = Awaited<ReturnType<typeof fixture>>;

/** A VM that only answers the calls attaching a sandbox session makes. */
const vm: GondolinVm = {
  fs: {
    mkdir: async () => {},
    access: async () => {},
    readFile: async () => {
      throw new Error("ENOENT");
    },
    writeFile: async () => {},
  },
  exec: (argv) =>
    Object.assign(
      Promise.resolve({
        ok: true,
        exitCode: 0,
        stdout: argv.includes("oppi-realpath") ? `${argv.at(-1)}\0` : "",
        stdoutBuffer: argv.includes("oppi-realpath")
          ? Buffer.from(`${argv.at(-1)}\0`)
          : Buffer.alloc(0),
      }),
      { async *output() {}, write() {}, end() {} },
    ),
};

async function selection(f: Fixture, sessionId: string) {
  const harness: Harness = (await f.opening.mock.results.at(-1)!.value).harness;
  const id = f.storage.getSession(sessionId)!.serverDurable!.conversationId as ConversationId;
  const agent = await (await harness.conversation(id, context))!.agent(context);
  const stored = await harness.snapshot(AgentDoc, id, context);
  return {
    stored: stored?.extensions,
    extensions: agent.extensions.map((extension) => extension.name),
    tools: agent.tools.map((tool) => tool.name),
    sections: agent.sections.map((section) => section.key),
  };
}

/** The selection when the session's conversation is created, then after it attaches again. */
async function createdAndReattached(
  f: Fixture,
  session: Session,
  workspace?: Parameters<SessionManager["startSession"]>[1],
) {
  await f.manager.startSession(session.id, workspace);
  const created = await selection(f, session.id);
  await f.manager.stopSession(session.id);
  await f.manager.startSession(session.id, workspace);
  const reattached = await selection(f, session.id);
  await f.manager.stopSession(session.id);
  return { created, reattached };
}

function workspaceSession(f: Fixture, runtime: "host" | "sandbox", launch?: Session["launch"]) {
  const workspace = f.storage.createWorkspace({ name: runtime, hostMount: f.dir });
  if (runtime === "sandbox") {
    workspace.runtime = "sandbox";
    f.storage.updateWorkspace(workspace.id, { runtime: "sandbox" });
  }
  const session = f.storage.createSession(runtime, "faux/faux-1");
  session.serverDurable = { storeId: session.id };
  session.workspaceId = workspace.id;
  if (launch) session.launch = launch;
  f.storage.saveSession(session);
  return { workspace, session };
}

describe("durable built-in selection", () => {
  it("pins extensions, tools, and sections per runtime", async () => {
    const f = await fixture();
    vi.spyOn(SdkBackend, "ensureSandboxWorkspaceVm").mockResolvedValue(vm);
    const host = workspaceSession(f, "host");
    const sandbox = workspaceSession(f, "sandbox");
    // A delegated child without the nested-delegation grant: no `subagent`.
    const child = workspaceSession(f, "host", {
      source: "agent",
      parentSessionId: host.session.id,
      target: { server: true },
      status: "accepted",
      requestedAt: Date.now(),
    } as unknown as Session["launch"]);
    const { session: control } = ensureControlConversationSession(f.storage, {
      model: "faux/faux-1",
    });
    const pinned = {
      host: await createdAndReattached(f, host.session, host.workspace),
      sandbox: await createdAndReattached(f, sandbox.session, sandbox.workspace),
      child: await createdAndReattached(f, child.session, child.workspace),
      control: await createdAndReattached(f, control),
    };
    expect(pinned).toEqual(PINNED);
  });

  it("offers notify only while the server does, and sends a call through it", async () => {
    const f = await fixture([
      fauxAssistantMessage(
        [fauxToolCall("notify", { title: "Report ready", body: "Read the summary." })],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("Sent."),
    ]);
    let offered = true;
    const sent: Array<[string, NotifyInput]> = [];
    f.manager.notifyPort = {
      offersNotify: () => offered,
      notify: async (sessionId, input) => {
        sent.push([sessionId, input]);
        return { status: "sent", devices: 1 };
      },
    };
    const { session, workspace } = workspaceSession(f, "host");

    await f.manager.startSession(session.id, workspace);
    const created = await selection(f, session.id);
    expect(created.extensions).toContain("oppi.notify");
    expect(created.tools).toContain("notify");
    expect(created.sections).toContain("notify-guidelines");

    const ended = new Promise<void>((resolve) => {
      const unsubscribe = f.manager.subscribe(session.id, (message: ServerMessage) => {
        if (message.type !== "agent_end") return;
        unsubscribe();
        resolve();
      });
    });
    await f.manager.sendPrompt(session.id, "Write the report");
    await ended;
    expect(sent).toEqual([[session.id, { title: "Report ready", body: "Read the summary." }]]);
    const harness: Harness = (await f.opening.mock.results.at(-1)!.value).harness;
    const id = f.storage.getSession(session.id)!.serverDurable!.conversationId as ConversationId;
    const page = await (await harness.conversation(id, context))!.entries(
      {},
      50,
      undefined,
      context,
    );
    const result = page.items
      .map((entry) => entry.model?.[0])
      .find((message) => message?.role === "toolResult");
    expect(result).toMatchObject({
      toolName: "notify",
      isError: false,
      content: [{ type: "text", text: "Notification sent to 1 device." }],
    });
    await f.manager.stopSession(session.id);

    // Push turned off: the next attach drops the tool.
    offered = false;
    await f.manager.startSession(session.id, workspace);
    const reattached = await selection(f, session.id);
    expect(reattached.extensions).not.toContain("oppi.notify");
    expect(reattached.tools).not.toContain("notify");
    await f.manager.stopSession(session.id);
  });

  it("gives speak only during a Live Voice call and says each reply's opening as it is written", async () => {
    const f = await fixture([
      fauxAssistantMessage([fauxToolCall("speak", { text: "On it." })], {
        stopReason: "toolUse",
      }),
      fauxAssistantMessage("Checked the logs. Nothing failed.\n\n- `server.log`: clean"),
      fauxAssistantMessage("All five tests pass."),
    ]);
    const spoken: string[] = [];
    const ended: RunOutcome[] = [];
    const speech = new LiveVoiceSpeech({
      speak: (_sessionId, text) => spoken.push(text),
      speakSentence: (_sessionId, _replyId, text) => spoken.push(text),
      openingWritten: () => {},
      runEnded: (_sessionId, outcome) => ended.push(outcome),
    });
    f.manager.liveVoiceSpeech = speech;
    const { session, workspace } = workspaceSession(f, "host");
    const voiced = (s: Awaited<ReturnType<typeof selection>>) =>
      s.extensions.includes("oppi.live-voice") &&
      s.tools.includes("speak") &&
      s.sections.includes("live-voice");
    const run = async (prompt: string) => {
      const done = new Promise<void>((resolve) => {
        const unsubscribe = f.manager.subscribe(session.id, (message: ServerMessage) => {
          if (message.type !== "agent_end") return;
          unsubscribe();
          resolve();
        });
      });
      await f.manager.sendPrompt(session.id, prompt);
      await done;
    };

    await f.manager.startSession(session.id, workspace);
    expect(voiced(await selection(f, session.id))).toBe(false);

    speech.setCallAttached(session.id, true);
    await vi.waitFor(async () => expect(voiced(await selection(f, session.id))).toBe(true));
    // A restart mid-call keeps the voice: the attach's `{ add }` edit drops it, the toggle restores it.
    await f.manager.stopSession(session.id);
    await f.manager.startSession(session.id, workspace);
    await vi.waitFor(async () => expect(voiced(await selection(f, session.id))).toBe(true));

    // A heads-up with speak, then the reply's spoken opening, sentence by sentence.
    await run("check the logs");
    expect(spoken).toEqual(["On it.", "Checked the logs.", "Nothing failed."]);
    expect(ended.at(-1)).toEqual({ kind: "final", spoken: "Checked the logs. Nothing failed." });

    await run("did the tests pass");
    expect(spoken.slice(3)).toEqual(["All five tests pass."]);
    expect(ended.at(-1)).toEqual({ kind: "final", spoken: "All five tests pass." });

    speech.setCallAttached(session.id, false);
    await vi.waitFor(async () => expect(voiced(await selection(f, session.id))).toBe(false));
    await f.manager.stopSession(session.id);
  });
});
