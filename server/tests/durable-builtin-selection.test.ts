import { existsSync, writeFileSync } from "node:fs";
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
import type { NotifyInput } from "../plugins/notify/contract.js";
import { AgentDoc, type ConversationId, type Harness } from "@earendil-works/pi-durable";
import { ensureControlConversationSession } from "../src/control-conversation-service.js";
import { SessionHost } from "../src/durable-harness.js";
import type { GondolinVm } from "../src/gondolin-ops.js";
import { LiveVoiceSpeech, type RunOutcome } from "../src/live-voice-speech.js";
import { SdkBackend } from "../src/sdk-backend.js";
import { SessionManager } from "../src/sessions.js";
import { Storage } from "../src/storage.js";
import type { ServerConfig, ServerMessage, Session } from "../src/types.js";
import { buildMobileOutputGuide, buildOppiSystemPromptAppend } from "../src/oppi-docs.js";
import { OPPI_CLI_SYSTEM_PROMPT_HINT } from "../src/oppi-cli-prompt.js";
import { getCurrentSystemPrompt } from "@earendil-works/pi-ai/utils/transcript";
import { makeTempDir } from "./harness/temp-dir.js";
import { toolArguments, toolNamed } from "./helpers/tool-arguments.js";
import { DurableNotify } from "../plugins/notify/server.js";
import { DurableLiveVoice } from "../plugins/live-voice/server.js";

// What each kind of durable session selects, pinned by name: the built-in extensions, the tools
// offered, and the prompt sections, in order, when the conversation is created and after it
// attaches again (a bound conversation's `{ add }` edit). Loading built-ins from packages must
// not change any of it.

/**
 * Every workspace session selects the file tools and codemode; the Pi Tools setting (Pi's
 * defaults here: read, bash, edit, write) decides which of their tools it offers, so neither
 * ls, find, grep, nor codemode is offered. Note the reattached sessions: their `{ add }` edit
 * applies to the Harness default selection.
 */
/** The `project-context` sections: Oppi's prompt appends, then AGENTS files and Skills. */
const PROMPT_SECTIONS = [
  "oppi_docs",
  "mobile_output_guide",
  "oppi_cli",
  "project_context",
  "skills",
];

const PINNED = {
  host: {
    created: {
      stored: [
        "coding-tools",
        "oppi.file-tools",
        "ask",
        "working-words",
        "background-jobs",
        "project-context",
        "sql-explorer",
        "codemode",
        "oppi.sessions",
      ],
      extensions: [
        "coding-tools",
        "oppi.file-tools",
        "ask",
        "working-words",
        "background-jobs",
        "project-context",
        "sql-explorer",
        "codemode",
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
        ...PROMPT_SECTIONS,
        "codemode",
        "sessions",
        "instructions",
      ],
    },
    reattached: {
      stored: {
        add: [
          "oppi.file-tools",
          "ask",
          "working-words",
          "background-jobs",
          "oppi.sessions",
          "project-context",
          "sql-explorer",
          "codemode",
        ],
        remove: ["oppi.notify"],
      },
      extensions: [
        "coding-tools",
        "oppi.file-tools",
        "ask",
        "working-words",
        "background-jobs",
        "oppi.sessions",
        "project-context",
        "sql-explorer",
        "codemode",
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
        ...PROMPT_SECTIONS,
        "codemode",
        "instructions",
      ],
    },
  },
  sandbox: {
    created: {
      stored: [
        "coding-tools",
        "oppi.file-tools",
        "ask",
        "working-words",
        "background-jobs",
        "project-context",
        "sql-explorer",
        "codemode",
        "oppi.sessions",
      ],
      extensions: [
        "coding-tools",
        "oppi.file-tools",
        "ask",
        "working-words",
        "background-jobs",
        "project-context",
        "sql-explorer",
        "codemode",
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
        ...PROMPT_SECTIONS,
        "codemode",
        "sessions",
        "instructions",
      ],
    },
    reattached: {
      stored: {
        add: [
          "oppi.file-tools",
          "ask",
          "working-words",
          "background-jobs",
          "oppi.sessions",
          "project-context",
          "sql-explorer",
          "codemode",
        ],
        remove: ["oppi.notify"],
      },
      extensions: [
        "coding-tools",
        "oppi.file-tools",
        "ask",
        "working-words",
        "background-jobs",
        "oppi.sessions",
        "project-context",
        "sql-explorer",
        "codemode",
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
        ...PROMPT_SECTIONS,
        "codemode",
        "instructions",
      ],
    },
  },
  child: {
    created: {
      stored: [
        "coding-tools",
        "oppi.file-tools",
        "ask",
        "working-words",
        "background-jobs",
        "project-context",
        "sql-explorer",
        "codemode",
      ],
      extensions: [
        "coding-tools",
        "oppi.file-tools",
        "ask",
        "working-words",
        "background-jobs",
        "project-context",
        "sql-explorer",
        "codemode",
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
      sections: [
        "ask-guidelines",
        "background-jobs",
        ...PROMPT_SECTIONS,
        "codemode",
        "instructions",
      ],
    },
    reattached: {
      stored: {
        add: [
          "oppi.file-tools",
          "ask",
          "working-words",
          "background-jobs",
          "project-context",
          "sql-explorer",
          "codemode",
        ],
        remove: ["oppi.sessions", "oppi.notify"],
      },
      extensions: [
        "coding-tools",
        "oppi.file-tools",
        "ask",
        "working-words",
        "background-jobs",
        "project-context",
        "sql-explorer",
        "codemode",
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
      sections: [
        "ask-guidelines",
        "background-jobs",
        ...PROMPT_SECTIONS,
        "codemode",
        "instructions",
      ],
    },
  },
  control: {
    created: {
      stored: ["ask", "working-words", "oppi.control", "codemode", "coding-tools"],
      extensions: ["ask", "working-words", "oppi.control", "codemode", "coding-tools"],
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
        "read",
        "write",
        "edit",
        "bash",
      ],
      sections: ["ask-guidelines", "oppi-control", "codemode"],
    },
    reattached: {
      stored: ["ask", "working-words", "oppi.control", "codemode", "coding-tools"],
      extensions: ["ask", "working-words", "oppi.control", "codemode", "coding-tools"],
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
        "read",
        "write",
        "edit",
        "bash",
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

/** `defaultTools` is the Pi Tools setting; Pi's default when unset. */
async function fixture(
  responses: FauxResponseStep[] = [],
  defaultTools?: string[],
  config?: Partial<ServerConfig>,
) {
  const dir = makeTempDir("oppi-durable-selection-");
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
      ...(defaultTools ? { defaultTools } : {}),
    }),
  );
  const opening = vi.spyOn(SessionHost.prototype, "open");
  const storage = new Storage(dir);
  storage.mutateConfig(() => ({ experimental: { serverDurable: true }, ...config }));
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

  it("offers the Pi tools the Pi Tools setting enables: host grep and a codemode script over them", async () => {
    const f = await fixture(
      [
        fauxAssistantMessage([fauxToolCall("grep", { pattern: "needle" })], {
          stopReason: "toolUse",
        }),
        fauxAssistantMessage(
          [
            fauxToolCall("codemode", {
              code: [
                'const found = await tools.grep({ pattern: "needle" });',
                'const text = await tools.read({ path: "notes.txt" });',
                'console.log("SCRIPT", typeof found, text.trim());',
              ].join("\n"),
            }),
          ],
          { stopReason: "toolUse" },
        ),
        fauxAssistantMessage([fauxToolCall("write", { path: "x.txt", content: "no" })], {
          stopReason: "toolUse",
        }),
        fauxAssistantMessage("Done."),
      ],
      ["+grep", "+codemode", "-write"],
    );
    const { session, workspace } = workspaceSession(f, "host");
    writeFileSync(join(f.dir, "notes.txt"), "a needle in the hay\n");

    await f.manager.startSession(session.id, workspace);
    const created = await selection(f, session.id);
    expect(created.tools).toEqual(expect.arrayContaining(["grep", "codemode", "read"]));
    expect(created.tools).not.toContain("write");
    expect(created.tools).not.toContain("ls");

    const ended = new Promise<void>((resolve) => {
      const unsubscribe = f.manager.subscribe(session.id, (message: ServerMessage) => {
        if (message.type !== "agent_end") return;
        unsubscribe();
        resolve();
      });
    });
    await f.manager.sendPrompt(session.id, "Find the needle");
    await ended;
    const harness: Harness = (await f.opening.mock.results.at(-1)!.value).harness;
    const id = f.storage.getSession(session.id)!.serverDurable!.conversationId as ConversationId;
    const page = await (await harness.conversation(id, context))!.entries(
      {},
      50,
      undefined,
      context,
    );
    const results = page.items
      .map((entry) => entry.model?.[0])
      .filter((message) => message?.role === "toolResult")
      .map((message) => JSON.stringify(message?.content));
    expect(results).toEqual(
      expect.arrayContaining([
        // Pi's grep ran over the host workspace.
        expect.stringContaining("notes.txt:1: a needle in the hay"),
        // The script called the same tools as nested calls.
        expect.stringContaining("SCRIPT string a needle in the hay"),
        // The setting's `-write` leaves the model without it.
        expect.stringContaining("Tool write is not available"),
      ]),
    );
    expect(existsSync(join(f.dir, "x.txt"))).toBe(false);
    await f.manager.stopSession(session.id);
  });

  it("runs a sandbox session's codemode script tools in its VM", async () => {
    const f = await fixture(
      [
        fauxAssistantMessage(
          [
            fauxToolCall("codemode", {
              code: 'const run = await tools.bash({ command: "echo from-script" }); console.log("EXIT", run.exitCode);',
            }),
          ],
          { stopReason: "toolUse" },
        ),
        fauxAssistantMessage("Done."),
      ],
      ["+codemode"],
    );
    const commands: string[] = [];
    vi.spyOn(SdkBackend, "ensureSandboxWorkspaceVm").mockResolvedValue({
      ...vm,
      exec: (argv, options) => {
        const command = [...(argv as string[])].join(" ");
        if (!command.includes("oppi-exec")) return vm.exec(argv, options);
        // A guest shell: its process identity line, then the command's output.
        commands.push(command);
        const result = { ok: true, exitCode: 0, stdout: "", stdoutBuffer: Buffer.alloc(0) };
        return Object.assign(Promise.resolve(result), {
          async *output() {
            yield { stream: "stdout" as const, data: Buffer.from("42 12345\nfrom-script\n") };
          },
          write() {},
          end() {},
        });
      },
    });
    const { session, workspace } = workspaceSession(f, "sandbox");
    await f.manager.startSession(session.id, workspace);
    expect((await selection(f, session.id)).tools).toContain("codemode");

    const ended = new Promise<void>((resolve) => {
      const unsubscribe = f.manager.subscribe(session.id, (message: ServerMessage) => {
        if (message.type !== "agent_end") return;
        unsubscribe();
        resolve();
      });
    });
    await f.manager.sendPrompt(session.id, "Run it");
    await ended;
    // The script's nested bash ran in the guest, not on the host.
    expect(commands.some((command) => command.includes("echo from-script"))).toBe(true);
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
    expect(JSON.stringify(result?.content)).toContain("EXIT 0");
    await f.manager.stopSession(session.id);
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

// Argument shapes models sent these tools in recorded durable sessions.
describe("notify and speak arguments", () => {
  it("take the recorded shapes and reject a field the tool does not have", () => {
    const notify = toolNamed(DurableNotify.tools, "notify");
    const call = { title: "Oppi installed", body: "Release build is on your phone." };
    expect(toolArguments(notify, call)).toEqual(call);
    expect(() => toolArguments(notify, { ...call, urgent: true })).toThrow("urgent: unknown field");

    const speak = toolNamed(DurableLiveVoice.tools, "speak");
    expect(toolArguments(speak, { text: "Checking the logs." })).toEqual({
      text: "Checking the logs.",
    });
    expect(() => toolArguments(speak, { text: "Checking.", voice: "calm" })).toThrow(
      "voice: unknown field",
    );
  });
});

// Oppi's appends to a durable session's prompt, as `buildSdkAppendSystemPrompt` gates them for a
// classic one, read from what the model is actually sent.
describe("durable prompt appends", () => {
  const WORKSPACE_PROMPT = "WORKSPACE_PROMPT_MARKER";
  const GUIDE = buildMobileOutputGuide();
  const DOCS = buildOppiSystemPromptAppend()!;

  /** Faux steps that record each request's rendered system prompt. */
  function capturing(count: number) {
    const prompts: string[] = [];
    const steps: FauxResponseStep[] = Array.from({ length: count }, () => (request) => {
      prompts.push(getCurrentSystemPrompt(request.messages));
      return fauxAssistantMessage("ok");
    });
    return { prompts, steps };
  }

  async function turn(f: Fixture, sessionId: string) {
    const ended = new Promise<void>((resolve) => {
      const unsubscribe = f.manager.subscribe(sessionId, (message: ServerMessage) => {
        if (message.type !== "agent_end") return;
        unsubscribe();
        resolve();
      });
    });
    await f.manager.sendPrompt(sessionId, "hello");
    await ended;
  }

  function setGuide(f: Fixture, enabled: boolean) {
    const current = f.storage.getMobileOutputGuideSettings();
    expect(f.storage.replaceMobileOutputGuideSettings(current.revision, { enabled }).ok).toBe(true);
  }

  function withWorkspacePrompt(f: Fixture, runtime: "host" | "sandbox") {
    const created = workspaceSession(f, runtime);
    created.workspace.systemPrompt = WORKSPACE_PROMPT;
    f.storage.updateWorkspace(created.workspace.id, { systemPrompt: WORKSPACE_PROMPT });
    return created;
  }

  it("renders the docs hint, guide, and CLI hint before the workspace prompt on the host; a sandbox gets only the guide", async () => {
    expect(DOCS).toContain("Oppi documentation");
    const { prompts, steps } = capturing(2);
    const f = await fixture(steps, undefined, { oppiCliPrompt: { enabled: true } });
    vi.spyOn(SdkBackend, "ensureSandboxWorkspaceVm").mockResolvedValue(vm);
    setGuide(f, true);
    const host = withWorkspacePrompt(f, "host");
    const sandbox = withWorkspacePrompt(f, "sandbox");
    for (const { session, workspace } of [host, sandbox]) {
      await f.manager.startSession(session.id, workspace);
      await turn(f, session.id);
      await f.manager.stopSession(session.id);
    }
    const [hostPrompt, sandboxPrompt] = prompts as [string, string];

    const order = [DOCS, GUIDE, OPPI_CLI_SYSTEM_PROMPT_HINT, WORKSPACE_PROMPT].map((text) =>
      hostPrompt.indexOf(text),
    );
    expect(order.every((index) => index >= 0)).toBe(true);
    expect([...order].sort((a, b) => a - b)).toEqual(order);

    // A sandbox prompt never names host paths: no docs hint, no host `oppi` CLI.
    expect(sandboxPrompt).toContain(GUIDE);
    expect(sandboxPrompt).toContain(WORKSPACE_PROMPT);
    expect(sandboxPrompt).not.toContain("Oppi documentation");
    expect(sandboxPrompt).not.toContain(OPPI_CLI_SYSTEM_PROMPT_HINT);
  });

  it("leaves out the docs and CLI hints while oppiDocsPrompt and oppiCliPrompt are off, and the guide while its setting is off", async () => {
    const { prompts, steps } = capturing(1);
    const f = await fixture(steps, undefined, {
      oppiDocsPrompt: { enabled: false },
      oppiCliPrompt: { enabled: false },
    });
    const { session, workspace } = withWorkspacePrompt(f, "host");
    await f.manager.startSession(session.id, workspace);
    await turn(f, session.id);
    await f.manager.stopSession(session.id);

    expect(prompts[0]).toContain(WORKSPACE_PROMPT);
    expect(prompts[0]).not.toContain("Oppi documentation");
    expect(prompts[0]).not.toContain(OPPI_CLI_SYSTEM_PROMPT_HINT);
    expect(prompts[0]).not.toContain(GUIDE);
  });

  it("gives a bound conversation a Mobile Output Guide change on its next turn after it attaches again or reloads", async () => {
    const { prompts, steps } = capturing(3);
    const f = await fixture(steps);
    const { session, workspace } = withWorkspacePrompt(f, "host");
    await f.manager.startSession(session.id, workspace);
    await turn(f, session.id);

    // As a classic session: the setting applies when the runtime is built again.
    setGuide(f, true);
    await f.manager.stopSession(session.id);
    await f.manager.startSession(session.id, workspace);
    await turn(f, session.id);

    setGuide(f, false);
    await f.manager.runCommand(session.id, { type: "reload" });
    await turn(f, session.id);
    await f.manager.stopSession(session.id);

    expect(prompts.map((prompt) => prompt.includes(GUIDE))).toEqual([false, true, false]);
  });
});
