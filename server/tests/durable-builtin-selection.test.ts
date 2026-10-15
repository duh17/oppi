import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import { fauxProvider } from "@earendil-works/pi-ai/providers/faux";
import { AgentDoc, type ConversationId, type Harness } from "@earendil-works/pi-durable";
import { ensureControlConversationSession } from "../src/control-conversation-service.js";
import { SessionHost } from "../src/durable-harness.js";
import type { GondolinVm } from "../src/gondolin-ops.js";
import { SdkBackend } from "../src/sdk-backend.js";
import { SessionManager } from "../src/sessions.js";
import { Storage } from "../src/storage.js";
import type { Session } from "../src/types.js";

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
        "oppi.sessions",
      ],
      extensions: [
        "coding-tools",
        "ask",
        "working-words",
        "background-jobs",
        "project-context",
        "oppi.sessions",
      ],
      tools: ["read", "write", "edit", "bash", "ask", "background_job", "subagent"],
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
        add: ["ask", "working-words", "background-jobs", "oppi.sessions", "project-context"],
      },
      extensions: [
        "coding-tools",
        "oppi.sandbox-tools",
        "ask",
        "working-words",
        "background-jobs",
        "oppi.sessions",
        "project-context",
      ],
      tools: ["read", "write", "edit", "bash", "ask", "background_job", "subagent"],
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
        "oppi.sessions",
      ],
      extensions: [
        "coding-tools",
        "oppi.sandbox-tools",
        "ask",
        "working-words",
        "background-jobs",
        "project-context",
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
        add: ["ask", "working-words", "background-jobs", "oppi.sessions", "project-context"],
      },
      extensions: [
        "coding-tools",
        "oppi.sandbox-tools",
        "ask",
        "working-words",
        "background-jobs",
        "oppi.sessions",
        "project-context",
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
      stored: ["coding-tools", "ask", "working-words", "background-jobs", "project-context"],
      extensions: ["coding-tools", "ask", "working-words", "background-jobs", "project-context"],
      tools: ["read", "write", "edit", "bash", "ask", "background_job"],
      sections: ["ask-guidelines", "background-jobs", "project_context", "skills", "instructions"],
    },
    reattached: {
      stored: {
        add: ["ask", "working-words", "background-jobs", "project-context"],
        remove: ["oppi.sessions"],
      },
      extensions: [
        "coding-tools",
        "oppi.sandbox-tools",
        "ask",
        "working-words",
        "background-jobs",
        "project-context",
      ],
      tools: ["read", "write", "edit", "bash", "ask", "background_job"],
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

async function fixture() {
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
});
