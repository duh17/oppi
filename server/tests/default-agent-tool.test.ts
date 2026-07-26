import { createServer as createHttpServer } from "node:http";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it, vi } from "vitest";

import {
  buildOppiToolResultDetails,
  classifyOppiToolCommand,
  createDefaultAgentExtensionFactory,
  formatOppiToolExpandedText,
  listAllowlistedOppiToolCommands,
  runOppiToolCommand,
} from "../src/default-agent-tool.js";
import { createOppiToolExtensionFactory } from "../src/oppi-tool-extension.js";
import { Storage } from "../src/storage.js";
import { listenOnLocalApiFixture } from "./harness/local-api-socket.js";

describe("Default Agent Oppi tool command runner", () => {
  it("returns help for write commands without local API dispatch", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-default-agent-tool-help-"));
    try {
      const result = await runOppiToolCommand({
        dataDir,
        args: ["session", "delete", "--help"],
      });

      expect(result.ok).toBe(true);
      expect(result.data).toMatchObject({ help: { title: "Delete session" } });
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("exposes the progressive session inspection workflow in agent-readable help", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-default-agent-tool-inspect-help-"));
    try {
      const result = await runOppiToolCommand({
        dataDir,
        args: ["session", "inspect", "--help"],
      });

      expect(result.ok).toBe(true);
      expect(result.data).toMatchObject({
        help: {
          usage: expect.stringContaining("--view <view>"),
          notes: expect.arrayContaining([
            expect.stringContaining("compact outline"),
            expect.stringContaining("messages/tools"),
          ]),
          examples: expect.arrayContaining([
            expect.objectContaining({
              command: "oppi session inspect sess_123 --view outline --json",
            }),
          ]),
        },
      });
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("dispatches allowed read commands through the JSON CLI modules", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-default-agent-tool-"));
    const requests: string[] = [];
    const api = createHttpServer((req, res) => {
      requests.push(`${req.method ?? "GET"} ${req.url ?? "/"}`);
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(
        JSON.stringify({
          workspaces: [{ id: "ws-1", name: "Oppi" }],
        }),
      );
    });
    await listenOnLocalApiFixture(api, dataDir);

    try {
      const storage = new Storage(dataDir);
      storage.rotateToken();
      storage.updateConfig({ host: "127.0.0.1", port: 0, tls: { mode: "disabled" } });

      const result = await runOppiToolCommand({ dataDir, args: ["workspace", "list"] });

      expect(result.ok).toBe(true);
      expect(JSON.parse(result.stdout)).toMatchObject({
        ok: true,
        data: { workspaces: [{ id: "ws-1", name: "Oppi" }] },
      });
      expect(requests).toEqual(["GET /workspaces"]);
    } finally {
      await new Promise<void>((resolve, reject) =>
        api.close((error) => (error ? reject(error) : resolve())),
      );
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("passes the agent cwd into session search workspace inference", async () => {
    const workspaceRoot = mkdtempSync(join(tmpdir(), "oppi-default-agent-tool-cwd-"));
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-default-agent-tool-cwd-data-"));
    const requests: string[] = [];
    const api = createHttpServer((req, res) => {
      const url = new URL(req.url ?? "/", "http://127.0.0.1");
      requests.push(`${req.method ?? "GET"} ${url.pathname}${url.search}`);
      res.writeHead(200, { "Content-Type": "application/json" });
      if (url.pathname === "/workspaces") {
        res.end(
          JSON.stringify({ workspaces: [{ id: "ws-1", name: "Oppi", hostMount: workspaceRoot }] }),
        );
        return;
      }
      if (url.pathname === "/workspaces/ws-1/worktrees") {
        res.end(
          JSON.stringify({ workspaceId: "ws-1", worktrees: [{ id: "main", path: workspaceRoot }] }),
        );
        return;
      }
      if (url.pathname === "/sessions/search") {
        res.end(JSON.stringify({ query: url.searchParams.get("q"), results: [], totalResults: 0 }));
        return;
      }
      res.end(JSON.stringify({}));
    });
    await listenOnLocalApiFixture(api, dataDir);

    try {
      const storage = new Storage(dataDir);
      storage.rotateToken();
      storage.updateConfig({ host: "127.0.0.1", port: 0, tls: { mode: "disabled" } });

      const result = await runOppiToolCommand({
        dataDir,
        args: ["session", "search", "needle"],
        cwd: workspaceRoot,
      });

      expect(result.ok).toBe(true);
      expect(requests).toContain("GET /workspaces");
      expect(requests).toContain("GET /sessions/search?q=needle&workspaceId=ws-1");
    } finally {
      await new Promise<void>((resolve, reject) =>
        api.close((error) => (error ? reject(error) : resolve())),
      );
      rmSync(dataDir, { recursive: true, force: true });
      rmSync(workspaceRoot, { recursive: true, force: true });
    }
  });
});

describe("Default Agent extension isolation", () => {
  it("registers only oppi and ask and hard-codes confirm-all for control mutations", async () => {
    type RegisteredTool = {
      execute: (
        toolCallId: string,
        params: unknown,
        signal: AbortSignal | undefined,
        onUpdate: undefined,
        context: unknown,
      ) => Promise<{ content: Array<{ type: string; text?: string }>; details?: unknown }>;
    };
    const tools = new Map<string, RegisteredTool>();
    createDefaultAgentExtensionFactory({ callerSessionId: "control-test" })({
      on: () => undefined,
      registerTool: (tool: RegisteredTool & { name: string }) => tools.set(tool.name, tool),
    } as unknown as never);

    expect([...tools.keys()]).toEqual(["oppi", "ask"]);
    const confirm = vi.fn(async () => false);
    const oppi = tools.get("oppi");
    expect(oppi).toBeDefined();
    if (!oppi) return;

    const result = await oppi.execute(
      "oppi-1",
      { args: ["session", "stop", "sess-1"] },
      undefined,
      undefined,
      { hasUI: true, ui: { confirm } },
    );

    expect(confirm).toHaveBeenCalledTimes(1);
    expect(result).toMatchObject({
      details: {
        cancelled: true,
        reason: "declined",
        expandedText: expect.stringContaining("## Cancelled"),
        presentationFormat: "markdown",
      },
    });
    expect((result.details as { expandedText?: string }).expandedText).toContain(
      "# Oppi session stop",
    );
  });
});

describe("Default Agent managed ask tool", () => {
  it("uses native structured UI, resets once-per-turn state, and labels fallbacks", async () => {
    type RegisteredTool = {
      execute: (
        toolCallId: string,
        params: unknown,
        signal: AbortSignal | undefined,
        onUpdate: undefined,
        context: unknown,
      ) => Promise<{ content: Array<{ type: string; text?: string }>; details?: unknown }>;
    };
    const tools = new Map<string, RegisteredTool>();
    let turnStart: (() => Promise<void>) | undefined;
    createDefaultAgentExtensionFactory({ callerSessionId: "control-test" })({
      on: (event: string, handler: () => Promise<void>) => {
        if (event === "turn_start") turnStart = handler;
      },
      registerTool: (tool: RegisteredTool & { name: string }) => tools.set(tool.name, tool),
    } as unknown as never);

    const params = {
      questions: [
        {
          id: "cadence",
          question: "When should this run?",
          options: [
            { value: "weekdays", label: "Weekdays" },
            { value: "daily", label: "Every day" },
          ],
        },
        {
          id: "recipients",
          question: "Who should receive it?",
          options: [
            { value: "team", label: "Team" },
            { value: "owner", label: "Owner" },
          ],
          multiSelect: true,
        },
      ],
      allowCustom: true,
    };
    const ask = vi.fn(async () => ({
      answers: { cadence: "weekdays", recipients: ["team", "owner"] },
      allIgnored: false,
    }));
    const tool = tools.get("ask");
    expect(tool).toBeDefined();
    if (!tool) return;

    const result = await tool.execute("ask-1", params, undefined, undefined, {
      hasUI: true,
      ui: { ask },
    });

    expect(ask).toHaveBeenCalledWith(
      expect.arrayContaining([expect.objectContaining({ id: "cadence" })]),
      true,
      undefined,
    );
    expect(result.details).toMatchObject({
      answers: { cadence: "weekdays", recipients: ["team", "owner"] },
      allIgnored: false,
    });
    await expect(
      tool.execute("ask-2", params, undefined, undefined, { hasUI: false, ui: {} }),
    ).rejects.toThrow(/Only one ask call per turn/);

    await turnStart?.();
    const fallback = await tool.execute("ask-3", params, undefined, undefined, {
      hasUI: false,
      ui: {},
    });
    expect(fallback.content[0]?.text).toContain("No ask UI available. Defaults:");
    expect(fallback.content[0]?.text).not.toContain("User answers:");

    await turnStart?.();
    const controller = new AbortController();
    controller.abort();
    const cancelled = await tool.execute("ask-4", params, controller.signal, undefined, {
      hasUI: true,
      ui: { ask },
    });
    expect(cancelled).toMatchObject({
      content: [{ text: "Ask request cancelled." }],
      details: { allIgnored: true, cancelled: true },
    });
    expect(ask).toHaveBeenCalledTimes(1);
  });
});

describe("Default Agent Oppi tool presentation", () => {
  it("preserves expanded request details on valid and rejected tool errors", async () => {
    type ToolResultHandler = (event: {
      toolName: string;
      input: Record<string, unknown>;
      content: Array<{ type: "text"; text: string }>;
      isError: boolean;
    }) => Promise<{ details?: Record<string, unknown>; isError?: boolean } | undefined>;
    let toolResultHandler: ToolResultHandler | undefined;
    createOppiToolExtensionFactory({
      identity: "control",
      policySnapshot: { approvalPolicy: "confirmAllChanges" },
      callerSessionId: "control-test",
    })({
      on: (event: string, handler: unknown) => {
        if (event === "tool_result") toolResultHandler = handler as ToolResultHandler;
      },
      registerTool: () => undefined,
    } as unknown as never);

    const handler = toolResultHandler;
    expect(handler).toBeDefined();
    if (!handler) return;

    const valid = await handler({
      toolName: "oppi",
      input: { args: ["session", "send", "sess-1", "--text", "complete response"] },
      content: [{ type: "text", text: "Session unavailable" }],
      isError: true,
    });
    const validExpanded = valid?.details?.expandedText;
    expect(typeof validExpanded).toBe("string");
    if (typeof validExpanded !== "string") return;
    expect(validExpanded).toContain("# Oppi session send");
    expect(validExpanded).toContain("## Message\n\n> complete response");
    expect(validExpanded).toContain("## Error");
    expect(validExpanded).toContain("Session unavailable");

    const rejected = await handler({
      toolName: "oppi",
      input: { args: ["session", "send", "sess-1", "--text=private-response"] },
      content: [{ type: "text", text: "Assignment-style flags are not supported" }],
      isError: true,
    });
    const rejectedExpanded = rejected?.details?.expandedText;
    expect(typeof rejectedExpanded).toBe("string");
    if (typeof rejectedExpanded !== "string") return;
    expect(rejectedExpanded).toContain("--text=[16 chars]");
    expect(rejectedExpanded).not.toContain("private-response");
    expect(rejectedExpanded).toContain("## Error");

    const longBody = `secret-${"x".repeat(200)}`;
    const longRejected = await handler({
      toolName: "oppi",
      input: { args: ["session", "send", "sess-1", `--text=${longBody}`] },
      content: [{ type: "text", text: `Assignment-style flags are not supported: --text=${longBody.slice(0, 73)}` }],
      isError: true,
    });
    const longExpanded = longRejected?.details?.expandedText;
    expect(typeof longExpanded).toBe("string");
    if (typeof longExpanded !== "string") return;
    expect(longExpanded).toContain(`--text=[${longBody.length} chars]`);
    expect(longExpanded).not.toContain("secret-");

    const malformedShape = await handler({
      toolName: "oppi",
      input: { args: ["workspace", "list", 42] },
      content: [{ type: "text", text: "oppi args must be an array of strings" }],
      isError: true,
    } as never);
    expect(malformedShape?.details).toMatchObject({ kind: "rejected", outcome: "error" });
  });

  it("formats session search output for people without leaking the JSON envelope", () => {
    const classification = classifyOppiToolCommand([
      "session",
      "search",
      "workspace",
      "search",
      "--workspace",
      "oppi",
    ]);
    expect(classification).toMatchObject({ ok: true });
    if (!classification.ok) return;

    const expanded = formatOppiToolExpandedText(classification, {
      query: "workspace search",
      total_results: 2,
      results: [
        {
          session_id: "sess-alpha",
          workspace_id: "ws-oppi",
          title: "Workspace search polish",
          snippet: "Make Oppi tool rows readable for humans.",
          rank: 0.93,
          updated_at_ms: 1_784_566_552_324,
        },
        {
          session_id: "sess-beta",
          workspace_id: "ws-oppi",
          title: "Default Agent tools",
          snippet: "Avoid opaque args arrays in timeline rows.",
          rank: 0.81,
          updated_at_ms: 1_784_566_500_000,
        },
      ],
    });

    expect(expanded).toContain("# Oppi session search");
    expect(expanded).toContain("`oppi session search workspace search --workspace oppi`");
    expect(expanded).toContain("## Search results (2)");
    expect(expanded).toContain("### Workspace search polish");
    expect(expanded).toContain("Make Oppi tool rows readable for humans.");
    expect(expanded).toContain("`sess-alpha`");
    expect(expanded).not.toContain('"ok"');
    expect(expanded).not.toContain('"results"');
  });

  it.each([
    { args: ["status", "--help"], heading: "# Oppi status" },
    { args: ["session", "help"], heading: "# Oppi session" },
    { args: ["session", "help", "send"], heading: "# Oppi session send" },
    { args: ["help", "session", "inspect"], heading: "# Oppi session inspect" },
    { args: ["session", "inspect", "--help"], heading: "# Oppi session inspect" },
  ])("uses the semantic command path for help form $args", ({ args, heading }) => {
    const classification = classifyOppiToolCommand(args);
    expect(classification).toMatchObject({ ok: true });
    if (!classification.ok) return;

    const expanded = formatOppiToolExpandedText(classification, { help: true });
    expect(expanded.split("\n")[0]).toBe(heading);
    expect(expanded).not.toContain("## Request");
  });

  it("keeps malformed JSON bodies observable in expanded help without throwing", () => {
    const classification = classifyOppiToolCommand([
      "skill",
      "update-file",
      "--help",
      "--content-json",
      "not-json",
    ]);
    expect(classification).toMatchObject({ ok: true });
    if (!classification.ok) return;

    expect(() => formatOppiToolExpandedText(classification, { help: true })).not.toThrow();
    const expanded = formatOppiToolExpandedText(classification, { help: true });
    expect(expanded).toContain("--content-json [8 chars]");
    expect(expanded).not.toContain("not-json");
  });

  it("shows the complete sent message and delivery details as readable Markdown", () => {
    const message = "Please review **all changes**.\n\n- Run focused tests\n- Report blockers";
    const classification = classifyOppiToolCommand([
      "session",
      "send",
      "sess-123",
      "--text",
      message,
      "--follow-up",
    ]);
    expect(classification).toMatchObject({ ok: true });
    if (!classification.ok) return;

    const details = buildOppiToolResultDetails(classification, {
      session_id: "sess-123",
      command: "follow_up",
    });
    const expanded = details.expandedText;
    expect(typeof expanded).toBe("string");
    if (typeof expanded !== "string") return;

    expect(expanded).toContain("# Oppi session send");
    expect(expanded).toContain(
      `\`oppi session send sess-123 --text [${message.length} chars] --follow-up\``,
    );
    expect(expanded).toContain("## Request");
    expect(expanded).toContain("- **Session:** `sess-123`");
    expect(expanded).toContain("- **Arguments:** `--follow-up`");
    expect(expanded).toContain(
      `## Message\n\n${message
        .split("\n")
        .map((line) => `> ${line}`)
        .join("\n")}`,
    );
    expect(expanded).toContain("## Delivery");
    expect(expanded).toContain("- **Status:** Queued");
    expect(expanded).toContain("- **Handling:** After the current turn");
    expect(expanded).toContain("- **Session:** [Open `sess-123`](oppi://session/sess-123)");
    expect(expanded).not.toContain("- **Command:**");
    expect(expanded).not.toContain("follow\\_up");
  });

  it.each([
    {
      args: ["session", "send", "sess-now", "--text", "Continue"],
      data: { session_id: "sess-now", command: "prompt" },
      status: "Sent",
      handling: "Starts an idle session or redirects the active turn",
    },
    {
      args: ["session", "send", "sess-steer", "--text", "Change course", "--steer"],
      data: { session_id: "sess-steer", command: "steer" },
      status: "Sent",
      handling: "Redirects the active turn",
    },
  ])("explains $data.command delivery behavior", ({ args, data, status, handling }) => {
    const classification = classifyOppiToolCommand(args);
    expect(classification).toMatchObject({ ok: true });
    if (!classification.ok) return;

    const expanded = formatOppiToolExpandedText(classification, data);

    expect(expanded).toContain("## Delivery");
    expect(expanded).toContain(`- **Status:** ${status}`);
    expect(expanded).toContain(`- **Handling:** ${handling}`);
    expect(expanded).toContain(
      `- **Session:** [Open \`${data.session_id}\`](oppi://session/${data.session_id})`,
    );
  });

  it("shows complete dialog response parameters in expanded history", () => {
    const answers = '{"scope":["server","apple"]}';
    const classification = classifyOppiToolCommand([
      "session",
      "respond",
      "sess-1",
      "--dialog",
      "dialog-1",
      "--answers",
      answers,
    ]);
    expect(classification).toMatchObject({ ok: true });
    if (!classification.ok) return;

    const expanded = formatOppiToolExpandedText(classification, { accepted: true });

    expect(expanded).toContain("# Oppi session respond");
    expect(expanded).toContain("- **Session:** `sess-1`");
    expect(expanded).toContain("- **Dialog:** `dialog-1`");
    expect(expanded).toContain(`## Answers\n\n> ${answers}`);
    const commandSection = expanded.split("\n\n## Request", 1)[0] ?? "";
    expect(commandSection).not.toContain(answers);
  });

  it("falls back to readable result data when session delivery fields are missing", () => {
    const classification = classifyOppiToolCommand([
      "session",
      "send",
      "sess-unknown",
      "--text",
      "Continue",
    ]);
    expect(classification).toMatchObject({ ok: true });
    if (!classification.ok) return;

    const expanded = formatOppiToolExpandedText(classification, { accepted: true });

    expect(expanded).toContain("## Result");
    expect(expanded).toContain("- **Accepted:** true");
    expect(expanded).not.toContain("## Delivery");
  });

  it("shows complete prompts alongside targets and non-body options", () => {
    const prompt = "# Review brief\n\nCheck the timeline renderer.";
    const classification = classifyOppiToolCommand([
      "session",
      "create",
      "--workspace",
      "oppi",
      "--model",
      "provider/model",
      "--prompt",
      prompt,
    ]);
    expect(classification).toMatchObject({ ok: true });
    if (!classification.ok) return;

    const expanded = formatOppiToolExpandedText(classification, { session: { id: "new-session" } });

    expect(expanded).toContain("- **Workspace:** `oppi`");
    expect(expanded).toContain("- **Arguments:** `--model provider/model`");
    expect(expanded).toContain(
      `## Prompt\n\n${prompt
        .split("\n")
        .map((line) => `> ${line}`)
        .join("\n")}`,
    );
  });

  it("contains Markdown bodies and unusual request values inside generated sections", () => {
    const message = "## Result\n\n[Open another session](oppi://session/unsafe)";
    const classification = classifyOppiToolCommand([
      "session",
      "send",
      "sess`unsafe\n## Forged",
      "--text",
      message,
    ]);
    expect(classification).toMatchObject({ ok: true });
    if (!classification.ok) return;

    const expanded = formatOppiToolExpandedText(classification, { delivered: true });

    expect(expanded).toContain("- **Session:** sess\\`unsafe ## Forged");
    expect(expanded).toContain("> ## Result\n> \n> [Open another session](oppi://session/unsafe)");
    expect(expanded.match(/^## Result$/gm)).toHaveLength(1);
  });

  it("keeps untrusted result text literal instead of allowing forged Markdown sections", () => {
    const classification = classifyOppiToolCommand(["session", "search", "needle"]);
    expect(classification).toMatchObject({ ok: true });
    if (!classification.ok) return;

    const expanded = formatOppiToolExpandedText(classification, {
      results: [
        {
          title: "Normal title\n\n## Forged command",
          snippet:
            "Safe result\n=\n~~~text\nforged fence content\n~~~\n>forged quote\n    forged code\n\tforged tab code\n- forged list\n[forged](oppi://session/unsafe)\u0007",
        },
      ],
    });

    expect(expanded).toContain("### Normal title ## Forged command");
    expect(expanded).toContain("\u2060=");
    expect(expanded).toContain("\u2060~~~text");
    expect(expanded).toContain("\u2060~~~\n");
    expect(expanded).toContain("\u2060\\>forged quote");
    expect(expanded).toContain("\u2060    forged code");
    expect(expanded).toContain("\u2060\tforged tab code");
    expect(expanded).toContain("\u2060- forged list");
    expect(expanded).toContain("\\[forged\\](oppi://session/unsafe)");
    expect(expanded).not.toContain("\n\n## Forged command");
    expect(expanded).not.toContain("\u0007");
  });

  it("flattens untrusted result keys so they cannot forge Markdown blocks", () => {
    const classification = classifyOppiToolCommand(["workspace", "list"]);
    expect(classification).toMatchObject({ ok: true });
    if (!classification.ok) return;

    const expanded = formatOppiToolExpandedText(classification, {
      "safe\n\n## forged\n~~~text\n>quote\n- list\n    code": "value",
    });

    expect(expanded).toContain("Safe ## forged ~~~text \\>quote - list code");
    expect(expanded).not.toContain("\n\n## forged");
    expect(expanded).not.toContain("\n~~~text");
  });

  it("builds the producer details consumed by generic expanded rendering", () => {
    const classification = classifyOppiToolCommand(["workspace", "list"]);
    expect(classification).toMatchObject({ ok: true });
    if (!classification.ok) return;

    expect(buildOppiToolResultDetails(classification, { workspaces: [] })).toMatchObject({
      args: ["workspace", "list"],
      kind: "read",
      data: { workspaces: [] },
      expandedText: expect.stringContaining("# Oppi workspace list"),
      presentationFormat: "markdown",
    });
  });

  it("rejects assignment-style body flags", () => {
    expect(
      classifyOppiToolCommand(["session", "send", "sess-1", "--text=private-message"]),
    ).toMatchObject({ ok: false, reason: expect.stringContaining("Assignment-style") });
  });

  it.each([
    {
      flag: "--prompt",
      body: "private prompt",
      expandedBody: "private prompt",
      args: ["session", "create", "--workspace", "oppi", "--prompt", "private prompt"],
    },
    {
      flag: "--text",
      body: "private message",
      expandedBody: "private message",
      args: ["session", "send", "sess-1", "--text", "private message"],
    },
    {
      flag: "--definition-json",
      body: '{"description":"secret"}',
      expandedBody: '"description": "secret"',
      args: ["agent", "update", "default", "--definition-json", '{"description":"secret"}'],
    },
    {
      flag: "--system-prompt",
      body: "private system prompt",
      expandedBody: "private system prompt",
      args: ["workspace", "update", "oppi", "--system-prompt", "private system prompt"],
    },
  ])(
    "redacts $flag bodies from the displayed command regardless of length",
    ({ flag, body, expandedBody, args }) => {
      const classification = classifyOppiToolCommand(args);
      expect(classification).toMatchObject({ ok: true });
      if (!classification.ok) return;

      const expanded = formatOppiToolExpandedText(classification, { updated: true });
      const commandSection = expanded.split("\n\n## Request", 1)[0] ?? "";

      expect(commandSection).toContain(`${flag} [${body.length} chars]`);
      expect(commandSection).not.toContain(body);
      expect(expanded).toContain(expandedBody);
    },
  );
});

describe("Default Agent Oppi tool command policy", () => {
  it("keeps the audited allowlist explicit", () => {
    expect(
      listAllowlistedOppiToolCommands().map(({ command, action }) =>
        [command, action].filter(Boolean).join(" "),
      ),
    ).toEqual([
      "status",
      "workspace list",
      "workspace get",
      "workspace create",
      "workspace update",
      "workspace delete",
      "workspace remove",
      "worktree list",
      "worktree get",
      "worktree status",
      "worktree preview",
      "worktree create",
      "worktree open",
      "worktree remove",
      "agent list",
      "agent get",
      "agent create",
      "agent update",
      "agent archive",
      "skill list",
      "skill get",
      "skill file",
      "skill update-file",
      "session list",
      "session get",
      "session changes",
      "session trace-outline",
      "session read",
      "session events",
      "session trace",
      "session search",
      "session inspect",
      "session diff",
      "session tool-output",
      "session trace-page",
      "session wait",
      "session create",
      "session send",
      "session abort",
      "session dialogs",
      "session respond",
      "session stop",
      "session resume",
      "session fork",
      "session delete",
      "schedule list",
      "schedule get",
      "schedule runs",
      "schedule create",
      "schedule update",
      "schedule run",
      "schedule pause",
      "schedule resume",
      "schedule archive",
      "schedule restore",
    ]);
  });

  it("allows read-only app inspection commands", () => {
    for (const args of [
      ["status"],
      ["workspace", "list"],
      ["workspace", "get", "oppi"],
      ["worktree", "list", "--workspace", "oppi"],
      ["worktree", "get", "main", "--workspace", "oppi"],
      ["worktree", "status", "wt_feature", "--workspace", "oppi"],
      ["worktree", "preview", "wt_feature", "--workspace", "oppi", "--into", "main"],
      ["agent", "list"],
      ["agent", "get", "default"],
      ["session", "list"],
      ["session", "get", "sess-1"],
      ["session", "search", "regression", "--workspace", "oppi"],
      ["session", "wait", "sess-1", "--for", "either", "--timeout", "30s", "--poll", "1s"],
      ["session", "inspect", "sess-1", "--turns", "1-3", "--view", "messages"],
      ["session", "read", "sess-1", "--tail", "10"],
      ["session", "inspect", "sess-1", "--view", "response"],
      ["session", "events", "sess-1"],
      ["session", "trace", "sess-1"],
      ["session", "changes", "sess-1"],
      ["session", "diff", "sess-1", "--path", "README.md"],
      ["session", "tool-output", "sess-1", "tool-1"],
      ["session", "trace-page", "sess-1"],
      ["session", "trace-outline", "sess-1"],
      ["schedule", "list"],
      ["schedule", "get", "sch-1"],
      ["schedule", "runs", "sch-1"],
    ]) {
      expect(classifyOppiToolCommand(args), args.join(" ")).toMatchObject({
        ok: true,
        kind: "read",
      });
    }
  });

  it("renders every documented allowlisted subcommand help form semantically", () => {
    for (const { command, action } of listAllowlistedOppiToolCommands()) {
      const args = [command, ...(action ? [action] : []), "--help"];
      const classification = classifyOppiToolCommand(args);
      expect(classification, args.join(" ")).toMatchObject({ ok: true, kind: "read" });
      if (!classification.ok) continue;
      const expectedHeading = `# Oppi ${[command, action].filter(Boolean).join(" ")}`;
      expect(formatOppiToolExpandedText(classification, { help: true }).split("\n")[0]).toBe(
        expectedHeading,
      );
    }
  });

  it("allows help for write and destructive commands", () => {
    for (const args of [
      ["session", "create", "--help"],
      ["session", "delete", "--help"],
      ["workspace", "delete", "--help"],
      ["agent", "archive", "--help"],
      ["worktree", "remove", "--help"],
    ]) {
      expect(classifyOppiToolCommand(args), args.join(" ")).toMatchObject({
        ok: true,
        kind: "read",
      });
    }
  });

  it("covers safe deterministic CLI subcommands that were missing from the allowlist", () => {
    for (const args of [
      ["session", "dialogs", "sess-1"],
      ["session", "abort", "sess-1"],
      ["session", "respond", "sess-1", "--dialog", "dialog-1", "--confirm"],
      ["schedule", "restore", "sch-1"],
    ]) {
      expect(classifyOppiToolCommand(args), args.join(" ")).toMatchObject({ ok: true });
    }

    expect(classifyOppiToolCommand(["session", "dialogs", "sess-1"])).toMatchObject({
      kind: "read",
    });
    for (const args of [
      ["session", "abort", "sess-1"],
      ["session", "respond", "sess-1", "--dialog", "dialog-1", "--confirm"],
      ["schedule", "restore", "sch-1"],
    ]) {
      expect(classifyOppiToolCommand(args), args.join(" ")).toMatchObject({
        kind: "approved-write",
      });
    }
  });

  it("requires approval for mutating app commands", () => {
    for (const args of [
      ["workspace", "create", "--name", "Scratch", "--host-mount", "/tmp/scratch"],
      ["workspace", "update", "oppi", "--name", "Oppi"],
      ["agent", "create", "--name", "Reviewer"],
      ["agent", "update", "default", "--definition-json", '{"description":"Short"}'],
      ["session", "create", "--workspace", "oppi", "--prompt", "Review this"],
      ["session", "send", "sess-1", "--text", "hello"],
      ["session", "stop", "sess-1"],
      ["session", "resume", "sess-1"],
      ["session", "fork", "sess-1", "--entry", "entry-1"],
      ["worktree", "create", "--workspace", "oppi", "--branch", "feature/review"],
      ["worktree", "open", "--workspace", "oppi", "--branch", "feature/review"],
      ["worktree", "remove", "wt_feature-review-12345678", "--workspace", "oppi"],
      ["schedule", "create", "--workspace", "oppi", "--prompt", "daily", "--every", "1d"],
      ["schedule", "update", "sch-1", "--definition-json", '{"name":"Daily"}'],
      ["schedule", "run", "sch-1"],
      ["schedule", "pause", "sch-1"],
      ["schedule", "resume", "sch-1"],
    ]) {
      expect(classifyOppiToolCommand(args), args.join(" ")).toMatchObject({
        ok: true,
        kind: "approved-write",
      });
    }
  });

  it("keeps compact tool output while exposing complete structured approval details", () => {
    const prompt = "Review **all** changes.\n\n```sh\nrm -rf /not-executed\n```" + "x".repeat(770);
    const classification = classifyOppiToolCommand([
      "session",
      "create",
      "--workspace",
      "zs1JP9sA",
      "--model",
      "gpt-5.5",
      "--prompt",
      prompt,
    ]);

    expect(classification).toMatchObject({
      ok: true,
      kind: "approved-write",
      approvalDetails: {
        action: "oppi session create",
        target: { label: "Workspace", value: "zs1JP9sA" },
        arguments: ["--model", "gpt-5.5"],
        bodies: [{ label: "Prompt", value: prompt }],
      },
    });
    if (!classification.ok) return;
    expect(classification.displayCommand).toContain(`--prompt [${prompt.length} chars]`);
    expect(classification.displayCommand).not.toContain("rm -rf");
    expect(classification.approvalMessage).toContain("## Command");
    expect(classification.approvalMessage).toContain("## Workspace");
    expect(classification.approvalMessage).toContain("## Arguments");
    expect(classification.approvalMessage).toContain("## Prompt");
    expect(classification.approvalMessage).toContain(prompt);
    expect(classification.approvalMessage).toContain("~~~text");
  });

  it("shell-quotes approval arguments and keeps markdown-like values inert", () => {
    const classification = classifyOppiToolCommand([
      "session",
      "send",
      "session with spaces",
      "--text",
      "# Not a heading\n[link](oppi://session/unsafe)\n~~~",
    ]);

    expect(classification).toMatchObject({
      ok: true,
      approvalDetails: {
        action: "oppi session send",
        target: { label: "Session", value: "session with spaces" },
        bodies: [
          {
            label: "Message",
            value: "# Not a heading\n[link](oppi://session/unsafe)\n~~~",
          },
        ],
      },
    });
    if (!classification.ok) return;
    expect(classification.approvalMessage).toContain("session with spaces");
    expect(classification.approvalMessage).toContain("```text\n# Not a heading");
  });

  it("uses indented code when a body contains both Markdown fence styles", () => {
    const prompt = "```\n~~~";
    const classification = classifyOppiToolCommand([
      "session",
      "create",
      "--workspace",
      "oppi",
      "--prompt",
      prompt,
    ]);

    expect(classification).toMatchObject({ ok: true });
    if (!classification.ok) return;
    expect(classification.approvalMessage).toContain("## Prompt\n\n    ```\n    ~~~");
    expect(classification.approvalMessage).not.toContain("````text");
    expect(classification.approvalMessage).not.toContain("~~~~text");
  });

  it("rejects indirect bodies that cannot be inspected and executed as the same snapshot", () => {
    for (const args of [
      ["agent", "update", "default", "--definition", "agent.json"],
      ["schedule", "update", "sch-1", "--definition", "schedule.json"],
      ["session", "create", "--workspace", "oppi", "--prompt", "@-"],
      ["session", "send", "sess-1", "--text", "@-"],
    ]) {
      expect(classifyOppiToolCommand(args), args.join(" ")).toEqual({
        ok: false,
        reason: expect.stringContaining("inline"),
      });
    }
  });

  it("separates a positional target from its workspace context", () => {
    const classification = classifyOppiToolCommand([
      "worktree",
      "remove",
      "wt_feature-review-12345678",
      "--workspace",
      "oppi",
      "--force",
    ]);

    expect(classification).toMatchObject({
      ok: true,
      approvalDetails: {
        target: { label: "Worktree", value: "wt_feature-review-12345678" },
        context: { label: "Workspace", value: "oppi" },
        arguments: ["--force"],
      },
    });
  });

  it("treats a long system prompt as a labeled body", () => {
    const systemPrompt = "Act safely.\n" + "x".repeat(500);
    const classification = classifyOppiToolCommand([
      "workspace",
      "update",
      "oppi",
      "--system-prompt",
      systemPrompt,
    ]);

    expect(classification).toMatchObject({
      ok: true,
      approvalDetails: {
        target: { label: "Workspace", value: "oppi" },
        bodies: [{ label: "System prompt", value: systemPrompt }],
      },
    });
  });

  it("rejects body fields that are unsupported for the selected action", () => {
    const classification = classifyOppiToolCommand([
      "agent",
      "update",
      "default",
      "--prompt",
      "decoy prompt",
      "--definition-json",
      '{"description":"effective definition"}',
    ]);

    expect(classification).toMatchObject({
      ok: false,
      reason: expect.stringContaining("Unsupported flag"),
    });
  });

  it("rejects oversized inline definitions before approval", () => {
    const classification = classifyOppiToolCommand([
      "agent",
      "update",
      "default",
      "--definition-json",
      JSON.stringify({ description: "x".repeat(65_536) }),
    ]);

    expect(classification).toEqual({
      ok: false,
      reason: "--definition-json exceeds maximum size of 65536 bytes",
    });
  });

  it("requires approval for destructive non-reversible commands", () => {
    for (const args of [
      ["workspace", "delete", "oppi"],
      ["agent", "archive", "default"],
      ["session", "delete", "sess-1"],
      ["worktree", "remove", "wt_feature-review-12345678", "--workspace", "oppi", "--force"],
      ["schedule", "archive", "sch-1"],
    ]) {
      expect(classifyOppiToolCommand(args), args.join(" ")).toMatchObject({
        ok: true,
        kind: "approved-write",
      });
    }
  });
});
