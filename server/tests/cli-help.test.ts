/**
 * CLI integration tests: `oppi help` output for every command.
 * Each test uses a temp data dir via OPPI_DATA_DIR to avoid touching real config.
 */
import { describe, expect, it } from "vitest";
import { run, runBin, stripAnsi, useCliDataDir } from "./harness/cli-test-env.js";

useCliDataDir();

// ── Help ──

describe("oppi help", () => {
  it("prints usage with 'help'", () => {
    const { stdout, exitCode } = run(["help"]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("oppi");
    expect(stdout).toContain("serve");
    expect(stdout).toContain("pair");
    expect(stdout).toContain("config");
  });

  it("prints usage with '--help'", () => {
    const { stdout, exitCode } = run(["--help"]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("serve");
  });

  it("prints usage with '-h'", () => {
    const { stdout, exitCode } = run(["-h"]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("serve");
  });

  it("prints usage with no args", () => {
    const { stdout, exitCode } = run([]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("serve");
  });

  it("executes the built bin target directly", () => {
    const { stdout, exitCode } = runBin(["--help"]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("serve");
  });

  it("keeps top-level help focused on nouns and common flows", () => {
    const { stdout, exitCode } = run(["help"]);
    const text = stripAnsi(stdout);

    expect(exitCode).toBe(0);
    expect(text).toContain("Common flows");
    expect(text).toContain("serve/start");
    expect(text).toContain("workspace");
    expect(text).toContain("worktree");
    expect(text).toContain("agent");
    expect(text).toContain("wait");
    expect(text).toContain("schedule help");
    expect(text).toContain("session create --help");
    expect(text).not.toContain("--workspace <id>");
    expect(text).not.toContain("--prompt <text>");
  });

  it("prints schedule concept, subcommands, and examples with 'schedule help'", () => {
    const { stdout, exitCode } = run(["schedule", "help"]);
    const text = stripAnsi(stdout);

    expect(exitCode).toBe(0);
    expect(text).toContain("Schedules run Oppi actions");
    expect(text).toContain("Subcommands");
    expect(text).toContain("create");
    expect(text).toContain("runs");
    expect(text).toContain("oppi schedule create");
  });

  it("prints exact schedule create flags, run-history notes, and examples", () => {
    const { stdout, exitCode } = run(["schedule", "create", "--help"]);
    const text = stripAnsi(stdout);

    expect(exitCode).toBe(0);
    expect(text).toContain("Usage: oppi schedule create");
    expect(text).toContain("--workspace <workspace>");
    expect(text).toContain("--prompt <text>");
    expect(text).toContain("--at <iso>");
    expect(text).toContain("--every <duration>");
    expect(text).toContain("--cron <expr>");
    expect(text).toContain("--agent <agent>");
    expect(text).not.toContain("--approval-ref");
    expect(text).not.toContain("Automatic runs fail closed");
    expect(text).toContain("Run history");
    expect(text).toContain("idempotent");
  });

  it("prints exact session create flags and launch idempotency behavior", () => {
    const { stdout, exitCode } = run(["session", "create", "--help"]);
    const text = stripAnsi(stdout);

    expect(exitCode).toBe(0);
    expect(text).toContain("Usage: oppi session create");
    expect(text).toContain("--workspace <workspace>");
    expect(text).toContain("--prompt <text>");
    expect(text).toContain("--tools");
    expect(text).toContain("--exclude-tools");
    expect(text).toContain("--no-tools");
    expect(text).toContain("--no-builtin-tools");
    expect(text).toContain(":thinking");
    expect(text).toContain("11111111-1111-4111-8111-111111111111");
    expect(text).not.toContain("sess_123");
    expect(text).toContain("--allow-nested-delegation");
    expect(text).toContain("grant then propagates down the subtree");
    expect(text).toContain("--auto-stop");
    expect(text).toContain("--idempotency-key <key>");
    expect(text).toContain("reuses the existing launch");
  });

  it("documents the implemented session app-control commands", () => {
    const { stdout, exitCode } = run(["session", "help"]);
    const text = stripAnsi(stdout);

    expect(exitCode).toBe(0);
    expect(text).toContain("Subcommands");
    for (const implemented of [
      "list",
      "get",
      "create",
      "send",
      "read",
      "events",
      "trace",
      "search",
      "inspect",
      "stop",
      "resume",
      "fork",
      "delete",
      "tool-output",
      "trace-page",
      "trace-outline",
    ]) {
      expect(text).toContain(implemented);
    }
    expect(text).toContain("Inspect history progressively");
    expect(text).toContain("--view outline");
    expect(text).not.toContain("messages <id>");
    expect(text).not.toContain("changes <id>");
    expect(text).not.toContain("diff <id>");
    expect(text).not.toContain("Not implemented in the CLI yet");
  });

  it.each(["changes", "diff"] as const)(
    "does not advertise or execute removed session %s command",
    (command) => {
      const nestedHelp = run(["session", command, "--help"]);
      expect(nestedHelp.exitCode).toBe(1);
      expect(nestedHelp.stdout).toContain(`No help topic for session ${command}`);

      const execution = run(["session", command, "sess-1", "--json"]);
      expect(execution.exitCode).toBe(1);
      expect(JSON.parse(execution.stdout)).toMatchObject({
        ok: false,
        error: { message: expect.stringMatching(/^Usage: oppi session /) },
      });
    },
  );

  it("documents the implemented saved Agent commands", () => {
    const { stdout, exitCode } = run(["agent", "help"]);
    const text = stripAnsi(stdout);

    expect(exitCode).toBe(0);
    expect(text).toContain("Saved Agents");
    for (const implemented of ["list", "get", "create", "update", "archive"]) {
      expect(text).toContain(implemented);
    }
    expect(text).toContain("session create --agent");
    expect(text).toContain(
      "name, icon, description, instructions, resources, sessionDefaults, launchConstraints",
    );
    expect(text).toContain("target, workspaceId, worktreeId, cwd, schedule, attachments, images");
  });

  it("prints agent-readable help with '--json'", () => {
    const { stdout, exitCode } = run(["help", "--json"]);

    expect(exitCode).toBe(0);
    expect(JSON.parse(stdout)).toMatchObject({
      ok: true,
      data: {
        help: {
          path: [],
          subcommands: expect.arrayContaining([
            expect.objectContaining({ name: "schedule" }),
            expect.objectContaining({ name: "session" }),
            expect.objectContaining({ name: "agent" }),
          ]),
        },
      },
    });
  });

  it("prints command-specific help for every top-level command noun", () => {
    const cases: Array<{ args: string[]; expected: string[] }> = [
      { args: ["init", "--help"], expected: ["Usage: oppi init", "--data-dir <path>"] },
      { args: ["serve", "--help"], expected: ["Usage: oppi serve", "--host <host>"] },
      { args: ["pair", "--help"], expected: ["Usage: oppi pair", "--show-token"] },
      { args: ["status", "--help"], expected: ["Usage: oppi status", "Local Network"] },
      { args: ["doctor", "--help"], expected: ["Usage: oppi doctor", "diagnostics"] },
      { args: ["update", "--help"], expected: ["Usage: oppi update", "npm-installed"] },
      { args: ["token", "help"], expected: ["Usage: oppi token rotate", "Existing clients"] },
      { args: ["config", "help"], expected: ["Usage: oppi config", "Subcommands"] },
      { args: ["server", "help"], expected: ["Usage: oppi server", "LaunchAgent"] },
      {
        args: ["workspace", "help"],
        expected: ["Usage: oppi workspace", "list", "get", "create", "update", "delete"],
      },
      { args: ["worktree", "help"], expected: ["Usage: oppi worktree", "--workspace <workspace>"] },
      { args: ["wait", "help"], expected: ["Usage: oppi wait", "session"] },
      { args: ["version", "--help"], expected: ["Usage: oppi version", "package version"] },
    ];

    for (const testCase of cases) {
      const { stdout, exitCode } = run(testCase.args);
      const text = stripAnsi(stdout);

      expect(exitCode).toBe(0);
      for (const expected of testCase.expected) {
        expect(text).toContain(expected);
      }
    }
  }, 45_000);

  it("prints useful help for nested utility subcommands", () => {
    const cases: Array<{ args: string[]; expected: string[] }> = [
      {
        args: ["config", "set", "--help"],
        expected: [
          "Usage: oppi config set <key> <value>",
          "runtimeEnv.<NAME>",
          "tls.mode",
          "asr.sttEndpoint",
        ],
      },
      {
        args: ["config", "validate", "--help"],
        expected: ["Usage: oppi config validate", "--config-file <path>"],
      },
      {
        args: ["server", "install", "--help"],
        expected: ["Usage: oppi server install", "--data-dir <path>"],
      },
      {
        args: ["server", "restart", "--help"],
        expected: ["Usage: oppi server restart", "background server"],
      },
      {
        args: ["schedule", "list", "--help"],
        expected: ["Usage: oppi schedule list", "--agent <agent>", "--json"],
      },
      {
        args: ["schedule", "get", "--help"],
        expected: ["Usage: oppi schedule get <id>", "schedule id", "--json"],
      },
      {
        args: ["schedule", "run", "--help"],
        expected: ["Usage: oppi schedule run <id>", "--request-id <key>", "idempotent"],
      },
      {
        args: ["schedule", "runs", "--help"],
        expected: ["Usage: oppi schedule runs <id>", "run history", "--json"],
      },
      {
        args: ["schedule", "pause", "--help"],
        expected: ["Usage: oppi schedule pause <id>", "automatic runs", "--json"],
      },
      {
        args: ["schedule", "resume", "--help"],
        expected: ["Usage: oppi schedule resume <id>", "automatic runs", "--json"],
      },
      {
        args: ["schedule", "archive", "--help"],
        expected: ["Usage: oppi schedule archive <id>", "no longer runs automatically", "--json"],
      },
      {
        args: ["schedule", "update", "--help"],
        expected: [
          "Usage: oppi schedule update <id>",
          "--definition <file>",
          "--definition-json <json-object>",
          "--json",
        ],
      },
      {
        args: ["workspace", "list", "--help"],
        expected: ["Usage: oppi workspace list", "--json"],
      },
      {
        args: ["workspace", "get", "--help"],
        expected: ["Usage: oppi workspace get <workspace>", "workspace id or unique name"],
      },
      {
        args: ["workspace", "create", "--help"],
        expected: ["Usage: oppi workspace create", "--host-mount <path>", "--definition <file>"],
      },
      {
        args: ["workspace", "update", "--help"],
        expected: ["Usage: oppi workspace update <workspace>", "--runtime <host|sandbox>"],
      },
      {
        args: ["workspace", "delete", "--help"],
        expected: ["Usage: oppi workspace delete <workspace>", "--json"],
      },
      {
        args: ["worktree", "list", "--help"],
        expected: ["Usage: oppi worktree list", "--workspace <workspace>"],
      },
      {
        args: ["worktree", "get", "--help"],
        expected: ["Usage: oppi worktree get <worktree>", "main"],
      },
      {
        args: ["worktree", "create", "--help"],
        expected: [
          "Usage: oppi worktree create",
          "--branch <branch>",
          "OPPI_DATA_DIR",
          "The worktree id stays reserved only while sessions are still bound to it",
        ],
      },
      {
        args: ["worktree", "open", "--help"],
        expected: ["Usage: oppi worktree open", "--branch <branch>", "--path <path>"],
      },
      {
        args: ["worktree", "status", "--help"],
        expected: ["Usage: oppi worktree status <worktree>", "git status"],
      },
      {
        args: ["worktree", "preview", "--help"],
        expected: ["Usage: oppi worktree preview <worktree>", "--into <branch>", "read-only"],
      },
      {
        args: ["worktree", "remove", "--help"],
        expected: [
          "Usage: oppi worktree remove <worktree>",
          "--force",
          "active sessions",
          "A worktree id stays reserved only while sessions are still bound to it",
        ],
      },
      {
        args: ["session", "list", "--help"],
        expected: ["Usage: oppi session list", "--workspace <workspace>", "--json"],
      },
      {
        args: ["session", "get", "--help"],
        expected: ["Usage: oppi session get <id>", "metadata"],
      },
      {
        args: ["session", "send", "--help"],
        expected: ["Usage: oppi session send <id>", "--text <text>"],
      },
      {
        args: ["session", "read", "--help"],
        expected: ["Usage: oppi session read <id>", "--tail <count>"],
      },
      {
        args: ["session", "events", "--help"],
        expected: ["Usage: oppi session events <id>", "--since <cursor>"],
      },
      {
        args: ["session", "trace", "--help"],
        expected: ["Usage: oppi session trace <id>", "--include <parts>"],
      },
      {
        args: ["session", "stop", "--help"],
        expected: ["Usage: oppi session stop <id>", "--json"],
      },
      {
        args: ["session", "search", "--help"],
        expected: ["Usage: oppi session search", "--query <text>", "--limit <count>"],
      },
      {
        args: ["session", "inspect", "--help"],
        expected: [
          "Usage: oppi session inspect <id>",
          "--turns <spec>",
          "--view <view>",
          "compact outline",
          "messages/tools",
        ],
      },
      {
        args: ["session", "resume", "--help"],
        expected: ["Usage: oppi session resume <id>", "--json"],
      },
      {
        args: ["session", "fork", "--help"],
        expected: ["Usage: oppi session fork <id>", "--entry <entry-id>"],
      },
      {
        args: ["session", "delete", "--help"],
        expected: ["Usage: oppi session delete <id>", "--json"],
      },
      {
        args: ["session", "tool-output", "--help"],
        expected: ["Usage: oppi session tool-output <id>", "tool call id"],
      },
      {
        args: ["session", "trace-page", "--help"],
        expected: ["Usage: oppi session trace-page <id>", "--target-events <count>"],
      },
      {
        args: ["session", "trace-outline", "--help"],
        expected: ["Usage: oppi session trace-outline <id>", "compact, jumpable event index"],
      },
      {
        args: ["agent", "list", "--help"],
        expected: ["Usage: oppi agent list", "--json"],
      },
      {
        args: ["agent", "get", "--help"],
        expected: ["Usage: oppi agent get <agent>", "agent id or unique name"],
      },
      {
        args: ["agent", "create", "--help"],
        expected: [
          "Usage: oppi agent create",
          "--definition <file>",
          "--definition-json <json-object>",
          "--name <name>",
          "--model",
          "--thinking",
          "--tools",
          "--exclude-tools",
          "--no-tools",
          "--no-builtin-tools",
          "Allowed AgentDefinition keys: name, icon, description, instructions, resources, sessionDefaults, launchConstraints",
          "Forbidden launch-only keys: target, workspaceId, worktreeId, cwd, schedule, attachments, images",
          "unavailable names are dropped with a session warning, not a launch failure",
        ],
      },
      {
        args: ["agent", "update", "--help"],
        expected: [
          "Usage: oppi agent update <agent>",
          "--definition <file>",
          "--definition-json <json-object>",
          "--model",
          "--thinking",
          "--tools",
          "--exclude-tools",
          "--no-tools",
          "--no-builtin-tools",
          "Update is a PATCH: omitted fields keep their stored values",
          "JSON null clears a field or nested key",
          "Run 'oppi agent get <agent>' first, then patch only the changed fields",
          "--expected-version",
          "sessionDefaults.tools",
        ],
      },
      {
        args: ["agent", "archive", "--help"],
        expected: ["Usage: oppi agent archive <agent>", "--json"],
      },
      {
        args: ["wait", "session", "--help"],
        expected: ["Usage: oppi wait session <id>", "--status <status>"],
      },
    ];

    for (const testCase of cases) {
      const { stdout, exitCode } = run(testCase.args);
      const text = stripAnsi(stdout);

      expect(exitCode).toBe(0);
      for (const expected of testCase.expected) {
        expect(text).toContain(expected);
      }
    }
  }, 120_000);

  it("prints agent-readable JSON help for agent namespace", () => {
    const { stdout, exitCode } = run(["agent", "help", "--json"]);

    expect(exitCode).toBe(0);
    expect(JSON.parse(stdout)).toMatchObject({
      ok: true,
      data: {
        help: {
          path: ["agent"],
          subcommands: expect.arrayContaining([expect.objectContaining({ name: "create" })]),
        },
      },
    });
  });

  it("prints agent-readable JSON help for nested utility subcommands", () => {
    const { stdout, exitCode } = run(["config", "set", "--help", "--json"]);

    expect(exitCode).toBe(0);
    expect(JSON.parse(stdout)).toMatchObject({
      ok: true,
      data: {
        help: {
          path: ["config", "set"],
          keys: expect.arrayContaining([expect.objectContaining({ name: "runtimeEnv.<NAME>" })]),
        },
      },
    });
  });
});
