import { afterEach, describe, expect, it, vi } from "vitest";

import { localApiRequest } from "../src/cli/local-api-client.js";
import { OPPI_CALLER_SESSION_ID_ENV } from "../src/session-caller-identity.js";
import {
  applyOppiToolPolicy,
  createOppiToolExtensionFactory,
  executePreparedOppiCommand,
  OPPI_EXTENSION_APPROVAL_FAILED_ERROR,
  OPPI_EXTENSION_APPROVAL_REQUIRED_ERROR,
  OPPI_EXTENSION_READ_ONLY_ERROR,
  listAllowlistedOppiToolCommands,
  prepareOppiCommand,
  type OppiApprovalPolicy,
  type OppiToolCommandCategory,
  type OppiToolCommandResult,
  type PreparedOppiCommand,
} from "../src/oppi-tool-extension.js";

vi.mock("../src/cli/local-api-client.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/cli/local-api-client.js")>();
  return { ...actual, localApiRequest: vi.fn() };
});

const request = vi.mocked(localApiRequest);
const originalCallerSessionId = process.env[OPPI_CALLER_SESSION_ID_ENV];
const SKILL_FILE_REVISION = "a".repeat(64);

afterEach(() => {
  request.mockReset();
  if (originalCallerSessionId === undefined) delete process.env[OPPI_CALLER_SESSION_ID_ENV];
  else process.env[OPPI_CALLER_SESSION_ID_ENV] = originalCallerSessionId;
});

type MatrixCase = {
  category: OppiToolCommandCategory;
  command: string;
  args: string[];
};

const MATRIX_CASES: MatrixCase[] = [
  { category: "read", command: "status", args: ["status"] },
  { category: "read", command: "workspace list", args: ["workspace", "list"] },
  { category: "read", command: "workspace get", args: ["workspace", "get", "ws-1"] },
  {
    category: "read",
    command: "worktree list",
    args: ["worktree", "list", "--workspace", "ws-1"],
  },
  {
    category: "read",
    command: "worktree get",
    args: ["worktree", "get", "main", "--workspace", "ws-1"],
  },
  {
    category: "read",
    command: "worktree status",
    args: ["worktree", "status", "main", "--workspace", "ws-1"],
  },
  {
    category: "read",
    command: "worktree preview",
    args: ["worktree", "preview", "main", "--workspace", "ws-1", "--into", "main"],
  },
  { category: "read", command: "agent list", args: ["agent", "list"] },
  { category: "read", command: "agent get", args: ["agent", "get", "agent-1"] },
  { category: "read", command: "skill list", args: ["skill", "list"] },
  { category: "read", command: "skill get", args: ["skill", "get", "skill-1"] },
  {
    category: "read",
    command: "skill file",
    args: ["skill", "file", "skill-1", "--path", "SKILL.md"],
  },
  { category: "read", command: "session list", args: ["session", "list"] },
  { category: "read", command: "session get", args: ["session", "get", "sess-1"] },
  { category: "read", command: "session dialogs", args: ["session", "dialogs", "sess-1"] },
  { category: "read", command: "session read", args: ["session", "read", "sess-1"] },
  { category: "read", command: "session events", args: ["session", "events", "sess-1"] },
  { category: "read", command: "session trace", args: ["session", "trace", "sess-1"] },
  {
    category: "read",
    command: "session search",
    args: ["session", "search", "regression", "--all"],
  },
  {
    category: "read",
    command: "session inspect",
    args: ["session", "inspect", "sess-1", "--view", "summary"],
  },
  { category: "read", command: "session changes", args: ["session", "changes", "sess-1"] },
  {
    category: "read",
    command: "session diff",
    args: ["session", "diff", "sess-1", "--path", "README.md"],
  },
  {
    category: "read",
    command: "session tool-output",
    args: ["session", "tool-output", "sess-1", "call-1"],
  },
  {
    category: "read",
    command: "session trace-page",
    args: ["session", "trace-page", "sess-1", "--target-events", "20"],
  },
  {
    category: "read",
    command: "session trace-outline",
    args: ["session", "trace-outline", "sess-1"],
  },
  {
    category: "read",
    command: "session wait",
    args: ["session", "wait", "sess-1", "--for", "either", "--timeout", "30s"],
  },
  { category: "read", command: "schedule list", args: ["schedule", "list"] },
  { category: "read", command: "schedule get", args: ["schedule", "get", "sch-1"] },
  { category: "read", command: "schedule runs", args: ["schedule", "runs", "sch-1"] },

  {
    category: "nonDestructiveWrite",
    command: "workspace create",
    args: ["workspace", "create", "--name", "Scratch", "--host-mount", "/tmp/scratch"],
  },
  {
    category: "nonDestructiveWrite",
    command: "workspace update",
    args: ["workspace", "update", "ws-1", "--name", "Renamed"],
  },
  {
    category: "nonDestructiveWrite",
    command: "worktree create",
    args: ["worktree", "create", "--workspace", "ws-1", "--branch", "feature/review"],
  },
  {
    category: "nonDestructiveWrite",
    command: "worktree open",
    args: ["worktree", "open", "--workspace", "ws-1", "--branch", "feature/review"],
  },
  {
    category: "nonDestructiveWrite",
    command: "agent create",
    args: ["agent", "create", "--definition-json", '{"name":"Reviewer"}'],
  },
  {
    category: "nonDestructiveWrite",
    command: "skill update-file",
    args: [
      "skill",
      "update-file",
      "skill-1",
      "--path",
      "SKILL.md",
      "--base-revision",
      SKILL_FILE_REVISION,
      "--content-json",
      JSON.stringify("# Updated\n"),
    ],
  },
  {
    category: "nonDestructiveWrite",
    command: "agent update",
    args: ["agent", "update", "agent-1", "--definition-json", '{"description":"Short"}'],
  },
  {
    category: "nonDestructiveWrite",
    command: "session create",
    args: ["session", "create", "--workspace", "ws-1", "--prompt", "Review this"],
  },
  {
    category: "nonDestructiveWrite",
    command: "session send",
    args: ["session", "send", "sess-1", "--text", "Continue"],
  },
  {
    category: "nonDestructiveWrite",
    command: "session abort",
    args: ["session", "abort", "sess-1"],
  },
  {
    category: "nonDestructiveWrite",
    command: "session respond",
    args: ["session", "respond", "sess-1", "--dialog", "dialog-1", "--confirm"],
  },
  { category: "nonDestructiveWrite", command: "session stop", args: ["session", "stop", "sess-1"] },
  {
    category: "nonDestructiveWrite",
    command: "session resume",
    args: ["session", "resume", "sess-1"],
  },
  {
    category: "nonDestructiveWrite",
    command: "session fork",
    args: ["session", "fork", "sess-1", "--entry", "entry-1"],
  },
  {
    category: "nonDestructiveWrite",
    command: "schedule create",
    args: [
      "schedule",
      "create",
      "--workspace",
      "ws-1",
      "--prompt",
      "Daily review",
      "--every",
      "1d",
    ],
  },
  {
    category: "nonDestructiveWrite",
    command: "schedule update",
    args: ["schedule", "update", "sch-1", "--definition-json", '{"name":"Daily"}'],
  },
  {
    category: "nonDestructiveWrite",
    command: "schedule update",
    args: ["schedule", "update", "sch-1", "--model", "ds4/deepseek-v4-flash"],
  },
  {
    category: "nonDestructiveWrite",
    command: "schedule update",
    args: ["schedule", "update", "sch-1", "--clear-model"],
  },
  { category: "nonDestructiveWrite", command: "schedule run", args: ["schedule", "run", "sch-1"] },
  {
    category: "nonDestructiveWrite",
    command: "schedule pause",
    args: ["schedule", "pause", "sch-1"],
  },
  {
    category: "nonDestructiveWrite",
    command: "schedule resume",
    args: ["schedule", "resume", "sch-1"],
  },
  {
    category: "nonDestructiveWrite",
    command: "schedule restore",
    args: ["schedule", "restore", "sch-1"],
  },

  {
    category: "destructiveWrite",
    command: "workspace delete",
    args: ["workspace", "delete", "ws-1"],
  },
  {
    category: "destructiveWrite",
    command: "workspace remove",
    args: ["workspace", "remove", "ws-1"],
  },
  {
    category: "destructiveWrite",
    command: "worktree remove",
    args: ["worktree", "remove", "wt-1", "--workspace", "ws-1"],
  },
  { category: "destructiveWrite", command: "agent archive", args: ["agent", "archive", "agent-1"] },
  {
    category: "destructiveWrite",
    command: "session delete",
    args: ["session", "delete", "sess-1"],
  },
  {
    category: "destructiveWrite",
    command: "schedule archive",
    args: ["schedule", "archive", "sch-1"],
  },
];

const POLICIES: OppiApprovalPolicy[] = ["confirmDestructiveOnly", "confirmAllChanges", "readOnly"];

function prepared(args: string[]): PreparedOppiCommand {
  const result = prepareOppiCommand(args);
  expect(result, args.join(" ")).toMatchObject({ ok: true });
  if (!result.ok) throw new Error(result.reason);
  return result.command;
}

function successResult(): OppiToolCommandResult {
  return { ok: true, exitCode: 0, stdout: "{}\n", data: {} };
}

describe("Oppi command descriptor matrix", () => {
  it.each(MATRIX_CASES)("classifies $command as $category", ({ args, category }) => {
    expect(prepared(args).category).toBe(category);
  });

  it("covers every allowlisted command in the policy matrix", () => {
    const covered = new Set(MATRIX_CASES.map((entry) => entry.command));
    const allowlisted = listAllowlistedOppiToolCommands().map(({ command, action }) =>
      [command, action].filter(Boolean).join(" "),
    );
    expect([...covered].sort()).toEqual([...allowlisted].sort());
  });

  it.each(MATRIX_CASES.flatMap((entry) => POLICIES.map((policy) => ({ ...entry, policy }))))(
    "$policy applies the exact policy to $command",
    async ({ args, category, command, policy }) => {
      const approve = vi.fn(async () => true);
      const execute = vi.fn(async () => successResult());

      if (policy === "readOnly" && category !== "read") {
        await expect(
          applyOppiToolPolicy({
            prepared: prepared(args),
            policy,
            identity: "ordinary",
            approve,
            execute,
          }),
        ).rejects.toThrow(OPPI_EXTENSION_READ_ONLY_ERROR);
        expect(approve).not.toHaveBeenCalled();
        expect(execute).not.toHaveBeenCalled();
        return;
      }

      const result = await applyOppiToolPolicy({
        prepared: prepared(args),
        policy,
        identity: "ordinary",
        approve,
        execute,
      });
      expect(result.kind).toBe("executed");
      const shouldApprove =
        category !== "read" &&
        (policy === "confirmAllChanges" ||
          category === "destructiveWrite" ||
          command === "session respond");
      expect(approve).toHaveBeenCalledTimes(shouldApprove ? 1 : 0);
      expect(execute).toHaveBeenCalledTimes(1);
      expect(execute).toHaveBeenCalledWith(expect.objectContaining({ category }));
    },
  );

  it.each(
    [
      [],
      ["workspace"],
      ["workspace", "start"],
      ["session", "start", "--workspace", "ws-1", "--prompt", "x"],
      ["future", "list"],
      ["workspace", "future"],
      ["future", "--help"],
      ["help"],
      ["help", "future"],
      ["workspace", "list", "extra"],
      ["workspace", "list", "--future", "x"],
      ["session", "inspect", "sess-1", "--turn", "2"],
      ["session", "wait", "sess-1", "--until", "idle"],
      ["session", "send", "sess-1", "--text=hidden"],
      ["workspace", "list", "--json", "false"],
      ["session", "respond", "sess-1", "--confirm"],
    ].map((args) => ({ args })),
  )("denies unknown, implicit, alias, malformed, or future input: $args", ({ args }) => {
    expect(prepareOppiCommand(args)).toMatchObject({ ok: false });
  });

  it.each(
    [
      ["help", "session", "create"],
      ["session", "help", "create"],
      ["session", "create", "--help"],
      ["session", "delete", "-h"],
      ["workspace", "--help"],
    ].map((args) => ({ args })),
  )("allows only help paths that resolve to real topics: $args", ({ args }) => {
    expect(prepared(args).category).toBe("read");
  });

  it.each(
    [
      ["config", "--help"],
      ["help", "server"],
      ["init", "--help"],
      ["token", "rotate", "--help"],
      ["doctor", "--help"],
      ["update", "--help"],
      ["pair", "--help"],
      ["version", "--help"],
      ["session", "watch", "--help"],
      ["help", "session", "watch"],
    ].map((args) => ({ args })),
  )("denies help for commands outside the application-state allowlist: $args", ({ args }) => {
    expect(prepareOppiCommand(args)).toMatchObject({ ok: false });
  });
});

describe("Oppi prepared command boundary", () => {
  it.each(
    [
      ["agent", "create", "--definition", "agent.json"],
      ["agent", "update", "agent-1", "--definition", "agent.json"],
      ["schedule", "update", "sch-1", "--definition", "schedule.json"],
      ["skill", "update-file", "skill-1", "--path", "SKILL.md", "--content-json", "@-"],
      ["session", "create", "--workspace", "ws-1", "--prompt", "@-"],
      ["session", "send", "sess-1", "--text", "@-"],
      ["schedule", "create", "--workspace", "ws-1", "--prompt", "@-", "--every", "1d"],
    ].map((args) => ({ args })),
  )("denies file or stdin-backed mutation bodies: $args", ({ args }) => {
    expect(prepareOppiCommand(args)).toMatchObject({
      ok: false,
      reason: expect.stringContaining("inline"),
    });
  });

  it("rejects a malformed Skill base revision", () => {
    expect(
      prepareOppiCommand([
        "skill",
        "update-file",
        "skill-1",
        "--path",
        "SKILL.md",
        "--base-revision",
        "stale",
        "--content-json",
        JSON.stringify("# Updated\n"),
      ]),
    ).toMatchObject({ ok: false, reason: expect.stringContaining("base-revision") });
  });

  it.each(["not json", "[]", "{}", JSON.stringify({ description: "x".repeat(65_536) })])(
    "rejects invalid, empty-update, or oversized inline JSON",
    (definition) => {
      expect(
        prepareOppiCommand(["agent", "update", "agent-1", "--definition-json", definition]),
      ).toMatchObject({ ok: false });
    },
  );

  it("presents the complete Skill replacement body for approval", () => {
    const body = "---\nname: review\ndescription: Review changes\n---\n# Review\n";
    const command = prepared([
      "skill",
      "update-file",
      "skill_abc",
      "--path",
      "SKILL.md",
      "--base-revision",
      SKILL_FILE_REVISION,
      "--content-json",
      JSON.stringify(body),
    ]);

    expect(command.approvalDetails).toMatchObject({
      action: "oppi skill update-file",
      category: "nonDestructiveWrite",
      target: { label: "Skill", value: "skill_abc" },
      context: { label: "Path", value: "SKILL.md" },
      bodies: [{ label: "File content", value: body }],
    });
    expect(command.approvalMessage).toContain("name: review");
    expect(command.displayCommand).not.toContain(body);
  });

  it("preserves complete body whitespace and recursively freezes approved data", () => {
    const body = "  first line\n```\n~~~\nlast line  \n";
    const raw = ["session", "send", "session with spaces", "--text", body];
    const command = prepared(raw);
    raw[2] = "changed-session";
    raw[4] = "changed-body";

    expect(command.normalizedArgs[2]).toBe("session with spaces");
    expect(command.parsed.flags.text).toBe(body);
    expect(command.approvalDetails).toMatchObject({
      target: { label: "Session", value: "session with spaces" },
      bodies: [{ label: "Message", value: body }],
    });
    expect(command.approvalMessage).toContain("      first line");
    expect(command.approvalMessage).toContain("    ```\n    ~~~\n    last line  ");
    expect(Object.isFrozen(command)).toBe(true);
    expect(Object.isFrozen(command.normalizedArgs)).toBe(true);
    expect(Object.isFrozen(command.parsed)).toBe(true);
    expect(Object.isFrozen(command.parsed.flags)).toBe(true);
    expect(Object.isFrozen(command.approvalDetails)).toBe(true);
    expect(Object.isFrozen(command.approvalDetails?.bodies)).toBe(true);
    expect(Object.isFrozen(command.approvalDetails?.bodies[0])).toBe(true);
  });

  it("executes Skill replacement with the decoded approved body", async () => {
    const body = "---\nname: review\ndescription: Review changes\n---\n# Review\n";
    request.mockResolvedValueOnce({ content: body, revision: "b".repeat(64) });
    const command = prepared([
      "skill",
      "update-file",
      "skill_abc",
      "--path",
      "SKILL.md",
      "--base-revision",
      SKILL_FILE_REVISION,
      "--content-json",
      JSON.stringify(body),
    ]);

    const result = await executePreparedOppiCommand({ prepared: command });

    expect(result.ok).toBe(true);
    expect(request).toHaveBeenCalledWith(
      expect.anything(),
      "/server/resources/skills/skill_abc/file?path=SKILL.md",
      { method: "PUT", body: { content: body, baseRevision: SKILL_FILE_REVISION } },
    );
  });

  it("executes the prepared parse without rereading or reclassifying mutable input", async () => {
    const raw = ["status"];
    const command = prepared(raw);
    raw[0] = "workspace";
    raw.push("delete", "ws-1");

    const result = await executePreparedOppiCommand({ prepared: command });

    expect(result).toMatchObject({ ok: true, data: { status: expect.any(Object) } });
  });

  it("captures caller identity immutably in the prepared command", () => {
    const result = prepareOppiCommand(["session", "stop", "caller-a"], {
      callerSessionId: "caller-a",
    });
    expect(result).toMatchObject({ ok: true });
    if (!result.ok) return;

    expect(result.command.callerSessionId).toBe("caller-a");
    expect(Object.isFrozen(result.command)).toBe(true);
  });
});

describe("Oppi approval failure behavior", () => {
  const destructive = () => prepared(["session", "delete", "sess-1"]);

  it("fails closed when approval UI is missing", async () => {
    const execute = vi.fn(async () => successResult());
    await expect(
      applyOppiToolPolicy({
        prepared: destructive(),
        policy: "confirmAllChanges",
        identity: "ordinary",
        execute,
      }),
    ).rejects.toThrow(OPPI_EXTENSION_APPROVAL_REQUIRED_ERROR);
    expect(execute).not.toHaveBeenCalled();
  });

  it("fails closed when approval is cancelled, throws, or is aborted", async () => {
    const cancelledExecute = vi.fn(async () => successResult());
    const cancelled = await applyOppiToolPolicy({
      prepared: destructive(),
      policy: "confirmAllChanges",
      identity: "ordinary",
      approve: async () => false,
      execute: cancelledExecute,
    });
    expect(cancelled).toMatchObject({ kind: "cancelled", reason: "declined" });
    expect(cancelledExecute).not.toHaveBeenCalled();

    const throwingExecute = vi.fn(async () => successResult());
    await expect(
      applyOppiToolPolicy({
        prepared: destructive(),
        policy: "confirmAllChanges",
        identity: "ordinary",
        approve: async () => {
          throw new Error("bridge internals");
        },
        execute: throwingExecute,
      }),
    ).rejects.toThrow(OPPI_EXTENSION_APPROVAL_FAILED_ERROR);
    expect(throwingExecute).not.toHaveBeenCalled();

    const controller = new AbortController();
    const abortedExecute = vi.fn(async () => successResult());
    const aborted = await applyOppiToolPolicy({
      prepared: destructive(),
      policy: "confirmAllChanges",
      identity: "ordinary",
      signal: controller.signal,
      approve: async () => {
        controller.abort();
        return true;
      },
      execute: abortedExecute,
    });
    expect(aborted).toMatchObject({ kind: "cancelled", reason: "aborted" });
    expect(abortedExecute).not.toHaveBeenCalled();
  });

  it("shows category, action, target, context, remaining args, and complete escaped bodies", async () => {
    const body = "  keep whitespace\n```\n~~~\nend  ";
    const approve = vi.fn(async () => false);
    await applyOppiToolPolicy({
      prepared: prepared([
        "session",
        "create",
        "--workspace",
        "ws-1",
        "--model",
        "provider/model",
        "--prompt",
        body,
      ]),
      policy: "confirmAllChanges",
      identity: "ordinary",
      approve,
      execute: async () => successResult(),
    });

    expect(approve).toHaveBeenCalledTimes(1);
    const message = approve.mock.calls[0]?.[0] ?? "";
    expect(message).toContain("## Category\n\nNon-destructive write");
    expect(message).toContain("oppi session create");
    expect(message).toContain("## Workspace");
    expect(message).toContain("ws-1");
    expect(message).toContain("--model provider/model");
    expect(message).toContain("## Prompt");
    expect(message).toContain("      keep whitespace");
    expect(message).toContain("    ```\n    ~~~");
    expect(message).toContain("    end  ");
  });
});

describe("Oppi structured audit boundary", () => {
  it("logs only bounded non-sensitive audit fields", async () => {
    const body = "TOP_SECRET_BODY";
    const write = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    try {
      await applyOppiToolPolicy({
        prepared: prepared(["session", "send", "sess-secret", "--text", body]),
        policy: "confirmDestructiveOnly",
        identity: "ordinary",
        execute: async () => successResult(),
      });

      const line = write.mock.calls.map((call) => String(call[0])).join("");
      expect(line).not.toContain(body);
      expect(line).not.toContain("sess-secret");
      if (!line) {
        expect(process.env.OPPI_LOG_LEVEL).toMatch(/^(error|warn)$/);
        return;
      }
      const entry = JSON.parse(line.trim()) as Record<string, unknown>;
      expect(Object.keys(entry).sort()).toEqual([
        "action",
        "category",
        "duration",
        "event",
        "identity",
        "level",
        "outcome",
        "policy",
        "result",
        "ts",
      ]);
      expect(entry).toMatchObject({
        event: "oppi_tool.audit",
        identity: "ordinary",
        category: "nonDestructiveWrite",
        policy: "confirmDestructiveOnly",
        action: "oppi session send",
        outcome: "not-required",
        result: "success",
        duration: expect.any(Number),
      });
    } finally {
      write.mockRestore();
    }
  });
});

describe("ordinary Oppi extension factory", () => {
  type RegisteredTool = {
    parameters?: { required?: string[]; properties?: Record<string, unknown> };
    prepareArguments?: (raw: unknown) => { args: string[] };
    execute: (...args: unknown[]) => Promise<unknown>;
  };

  function ordinaryTool(callerSessionId: string): RegisteredTool {
    const tools = new Map<string, RegisteredTool>();
    createOppiToolExtensionFactory({
      identity: "ordinary",
      callerSessionId,
      policySnapshot: { approvalPolicy: "confirmDestructiveOnly" },
    })({
      on: () => undefined,
      registerTool: (tool: RegisteredTool & { name: string }) => tools.set(tool.name, tool),
    } as never);
    const tool = tools.get("oppi");
    if (!tool) throw new Error("Oppi tool was not registered");
    return tool;
  }

  it("routes malformed argument shapes through execution for durable error presentation", async () => {
    const tool = ordinaryTool("caller-test");

    expect(tool.parameters?.required ?? []).toContain("args");
    expect(tool.prepareArguments?.({ args: ["workspace", 42] })).toEqual({ args: [] });
    await expect(
      tool.execute("call-malformed", {}, undefined, undefined, { hasUI: false, ui: {} }),
    ).rejects.toThrow("oppi args must be an array of strings");
    await expect(
      tool.execute(
        "call-malformed",
        { args: ["session", 42] },
        undefined,
        undefined,
        { hasUI: false, ui: {} },
      ),
    ).rejects.toThrow("oppi args must be an array of strings");
  });

  it("registers only oppi and applies its captured policy snapshot", async () => {
    const tools = new Map<string, { execute: (...args: unknown[]) => Promise<unknown> }>();
    createOppiToolExtensionFactory({
      identity: "ordinary",
      callerSessionId: "caller-test",
      policySnapshot: { approvalPolicy: "readOnly" },
    })({
      on: () => undefined,
      registerTool: (tool: { name: string; execute: (...args: unknown[]) => Promise<unknown> }) =>
        tools.set(tool.name, tool),
    } as never);

    expect([...tools.keys()]).toEqual(["oppi"]);
    const tool = tools.get("oppi");
    expect(tool).toBeDefined();
    if (!tool) return;
    await expect(
      tool.execute("call-1", { args: ["session", "stop", "sess-1"] }, undefined, undefined, {
        hasUI: true,
        ui: { confirm: vi.fn(async () => true) },
      }),
    ).rejects.toThrow(OPPI_EXTENSION_READ_ONLY_ERROR);
  });

  it("shows the pending dialog semantics before approving session respond", async () => {
    request.mockImplementation(async (_storage, path) => {
      if (path === "/sessions/target-session/dialogs") {
        return {
          dialogs: [
            {
              id: "dialog-1",
              method: "confirm",
              title: "Delete workspace?",
              message: "This permanently removes workspace ws-1.",
            },
          ],
        } as never;
      }
      if (path === "/sessions/target-session/command") return { ok: true } as never;
      throw new Error(`Unexpected request: ${path}`);
    });
    const confirm = vi.fn(async () => true);
    const tool = ordinaryTool("caller-session");

    await tool.execute(
      "call-respond",
      {
        args: [
          "session",
          "respond",
          "target-session",
          "--dialog",
          "dialog-1",
          "--confirm",
        ],
      },
      undefined,
      undefined,
      { hasUI: true, ui: { confirm } },
    );

    expect(confirm).toHaveBeenCalledTimes(1);
    expect(confirm.mock.calls[0]?.[1]).toContain("Delete workspace?");
    expect(confirm.mock.calls[0]?.[1]).toContain("This permanently removes workspace ws-1.");
    expect(request).toHaveBeenCalledWith(
      expect.anything(),
      "/sessions/target-session/dialogs",
    );
  });

  it("rejects a stale dialog id before opening approval", async () => {
    request.mockResolvedValue({ dialogs: [] } as never);
    const confirm = vi.fn(async () => true);
    const tool = ordinaryTool("caller-session");

    await expect(
      tool.execute(
        "call-stale-dialog",
        {
          args: [
            "session",
            "respond",
            "target-session",
            "--dialog",
            "stale-dialog",
            "--confirm",
          ],
        },
        undefined,
        undefined,
        { hasUI: true, ui: { confirm } },
      ),
    ).rejects.toThrow('No pending dialog "stale-dialog"');
    expect(confirm).not.toHaveBeenCalled();
  });

  it.each([
    { action: "stop", args: ["session", "stop", "caller-a"] },
    {
      action: "send",
      args: ["session", "send", "caller-a", "--text", "continue"],
    },
    { action: "resume", args: ["session", "resume", "caller-a"] },
  ])("rejects self $action without process environment identity", async ({ args }) => {
    delete process.env[OPPI_CALLER_SESSION_ID_ENV];
    const tool = ordinaryTool("caller-a");

    await expect(
      tool.execute("call-self", { args }, undefined, undefined, { hasUI: false, ui: {} }),
    ).rejects.toThrow("Cannot target the calling Oppi session (caller-a)");
    expect(request).not.toHaveBeenCalled();
  });

  it("propagates distinct immutable callers into concurrent session create lineage", async () => {
    process.env[OPPI_CALLER_SESSION_ID_ENV] = "wrong-process-global";
    const createBodies: Array<Record<string, unknown>> = [];
    request.mockImplementation(async (_storage, path, options) => {
      if (path === "/workspaces/ws-1") {
        return { workspace: { id: "ws-1", name: "Workspace" } };
      }
      if (path === "/workspaces/ws-1/sessions" && options?.method === "POST") {
        createBodies.push(options.body as Record<string, unknown>);
        const parentSessionId = (options.body as { parentSessionId?: string }).parentSessionId;
        return { session: { id: `child-${parentSessionId}` } };
      }
      throw new Error(`Unexpected request: ${path}`);
    });
    const callerA = ordinaryTool("caller-a");
    const callerB = ordinaryTool("caller-b");

    const [createdA, createdB] = await Promise.all([
      callerA.execute(
        "create-a",
        {
          args: [
            "session",
            "create",
            "--workspace",
            "ws-1",
            "--prompt",
            "child from A",
            "--allow-nested-delegation",
          ],
        },
        undefined,
        undefined,
        { hasUI: false, ui: {} },
      ),
      callerB.execute(
        "create-b",
        { args: ["session", "create", "--workspace", "ws-1", "--prompt", "child from B"] },
        undefined,
        undefined,
        { hasUI: false, ui: {} },
      ),
    ]);

    expect(createdA).toBeDefined();
    expect(createdB).toBeDefined();
    expect(createBodies).toHaveLength(2);
    expect(createBodies).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          prompt: "child from A",
          parentSessionId: "caller-a",
          allowNestedDelegation: true,
        }),
        expect.objectContaining({ prompt: "child from B", parentSessionId: "caller-b" }),
      ]),
    );
    expect(process.env[OPPI_CALLER_SESSION_ID_ENV]).toBe("wrong-process-global");
  });

  it("keeps distinct concurrent caller identities isolated", async () => {
    delete process.env[OPPI_CALLER_SESSION_ID_ENV];
    request.mockResolvedValue({ session: { status: "stopped" } });
    const callerA = ordinaryTool("caller-a");
    const callerB = ordinaryTool("caller-b");

    const [selfA, selfB] = await Promise.allSettled([
      callerA.execute("call-a", { args: ["session", "stop", "caller-a"] }, undefined, undefined, {
        hasUI: false,
        ui: {},
      }),
      callerB.execute("call-b", { args: ["session", "stop", "caller-b"] }, undefined, undefined, {
        hasUI: false,
        ui: {},
      }),
    ]);

    expect(selfA).toMatchObject({
      status: "rejected",
      reason: expect.objectContaining({
        message: "Cannot target the calling Oppi session (caller-a)",
      }),
    });
    expect(selfB).toMatchObject({
      status: "rejected",
      reason: expect.objectContaining({
        message: "Cannot target the calling Oppi session (caller-b)",
      }),
    });
    expect(request).not.toHaveBeenCalled();

    const [crossA, crossB] = await Promise.all([
      callerA.execute(
        "call-cross-a",
        { args: ["session", "stop", "caller-b"] },
        undefined,
        undefined,
        { hasUI: false, ui: {} },
      ),
      callerB.execute(
        "call-cross-b",
        { args: ["session", "stop", "caller-a"] },
        undefined,
        undefined,
        { hasUI: false, ui: {} },
      ),
    ]);

    expect(crossA).toBeDefined();
    expect(crossB).toBeDefined();
    expect(request).toHaveBeenCalledTimes(2);
  });
});
