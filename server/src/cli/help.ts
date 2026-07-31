import * as c from "../ansi.js";

export type CliHelpPath = readonly string[];

type HelpItem = {
  name: string;
  summary: string;
};

type HelpFlag = {
  name: string;
  value?: string;
  summary: string;
  required?: boolean;
};

type HelpExample = {
  command: string;
  summary?: string;
};

export type HelpTopic = {
  path: string[];
  title: string;
  summary: string;
  usage?: string;
  description?: string[];
  commonFlows?: HelpExample[];
  subcommands?: HelpItem[];
  arguments?: HelpItem[];
  keys?: HelpItem[];
  flags?: HelpFlag[];
  notes?: string[];
  examples?: HelpExample[];
};

type HelpJsonTopic = Omit<HelpTopic, "path"> & { path: string[] };

const HELP_TOPICS: HelpTopic[] = [
  {
    path: [],
    title: "Oppi CLI",
    summary: "Run and manage a local Oppi server.",
    commonFlows: [
      {
        command: "oppi init → oppi serve → oppi pair",
        summary: "first run, local server, iPhone pairing",
      },
      {
        command: "oppi server install → oppi server status",
        summary: "run the server in the background with launchd",
      },
      {
        command: "oppi schedule help",
        summary: "schedule future or repeated agent work",
      },
      {
        command: "oppi session create --help",
        summary: "launch a session from scripts or automation",
      },
    ],
    subcommands: [
      { name: "init", summary: "write first-time config and owner credentials" },
      { name: "serve/start", summary: "start the local server in this terminal" },
      { name: "pair", summary: "show a signed pairing QR/link for the iOS app" },
      { name: "status", summary: "show server, network, and pairing status" },
      { name: "doctor", summary: "run security and environment diagnostics" },
      { name: "server", summary: "install, restart, stop, or inspect the launchd service" },
      { name: "config", summary: "show, get, set, or validate server config" },
      { name: "workspace", summary: "list, inspect, create, update, and delete workspaces" },
      { name: "worktree", summary: "list, create, open, and remove workspace worktrees" },
      {
        name: "session",
        summary: "list, launch, inspect, message, resume, fork, and stop sessions",
      },
      { name: "schedule", summary: "create and run scheduled agent work" },
      { name: "agent", summary: "create, inspect, update, archive, and launch saved Agents" },
      { name: "skill", summary: "inspect and update editable server Skill files" },
      { name: "wait", summary: "poll session state until a condition is true" },
      { name: "token", summary: "rotate the owner bearer token" },
      { name: "update", summary: "check or update the npm-installed server and CLI" },
      { name: "version", summary: "print the installed package version" },
    ],
    notes: [
      "Default output is terminal-friendly for humans and agents; use '--json' for strict machine parsing.",
      "Help, version, init, serve, pair, status, doctor, config, server, and update are available during setup; workspace, worktree, session, Agent, schedule, and wait commands require local owner credentials and a running server.",
      "Use '<noun> help' or '<command> --help' for flags and deeper examples.",
      "Use '--json' with help for an agent-readable description of the same topic.",
    ],
    examples: [
      { command: "oppi config set port 8080" },
      { command: "oppi config set asr.sttEndpoint http://127.0.0.1:7936" },
      { command: 'oppi config set tls \'{"mode":"self-signed"}\'' },
    ],
  },
  {
    path: ["init"],
    title: "Initialize Oppi",
    summary: "Write first-time config, generate owner credentials, and set TLS defaults.",
    usage: "oppi init [flags]",
    flags: [
      { name: "--data-dir", value: "<path>", summary: "config/data directory to initialize" },
      { name: "--port", value: "<number>", summary: "server port; defaults to 7749" },
      {
        name: "--max-sessions",
        value: "<count>",
        summary: "global concurrent session limit; defaults to 200",
      },
      { name: "--yes", summary: "non-interactive setup with defaults" },
      { name: "--force", summary: "continue when config already exists" },
    ],
    notes: [
      "Without --yes, init prompts when stdin is interactive.",
      "Init writes config.json, rotates the owner token, and generates identity keys.",
    ],
    examples: [{ command: "oppi init" }, { command: "oppi init --yes --data-dir ~/.config/oppi" }],
  },
  {
    path: ["serve"],
    title: "Serve",
    summary: "Start the Oppi server in the foreground.",
    usage: "oppi serve [--host <host>]",
    flags: [
      { name: "--host", value: "<host>", summary: "hostname/IP encoded in first-run pairing QR" },
    ],
    notes: [
      "On first run, serve creates owner credentials, enables self-signed TLS, and prints a pairing QR.",
      "Press Ctrl+C to stop the foreground server.",
    ],
    examples: [{ command: "oppi serve" }, { command: "oppi serve --host mac-studio.local" }],
  },
  {
    path: ["start"],
    title: "Start",
    summary: "Alias for 'oppi serve'.",
    usage: "oppi start [--host <host>]",
    flags: [
      { name: "--host", value: "<host>", summary: "hostname/IP encoded in first-run pairing QR" },
    ],
    examples: [{ command: "oppi start" }],
  },
  {
    path: ["pair"],
    title: "Pair",
    summary: "Generate a signed pairing QR/link for the Oppi iOS app.",
    usage: "oppi pair [name] [flags]",
    arguments: [{ name: "name", summary: "optional display name for the pairing invite" }],
    flags: [
      { name: "--host", value: "<host>", summary: "hostname/IP encoded in the invite" },
      { name: "--json", summary: "write the invite payload as JSON" },
      { name: "--show-token", summary: "print the owner bearer token in human output; unsafe" },
    ],
    notes: [
      "The QR and link carry the same signed invite.",
      "Use --show-token only for manual recovery; it exposes the owner token in the terminal.",
    ],
    examples: [
      { command: 'oppi pair "Chen"' },
      { command: "oppi pair --host mac-studio.local" },
      { command: "oppi pair --json" },
    ],
  },
  {
    path: ["status"],
    title: "Status",
    summary: "Show server config, Local Network addresses, Tailscale status, and pairing state.",
    usage: "oppi status",
    notes: ["This reads local config and host network state; it does not contact the server API."],
    examples: [{ command: "oppi status" }],
  },
  {
    path: ["doctor"],
    title: "Doctor",
    summary: "Run security, TLS, launchd, runtime, and environment diagnostics.",
    usage: "oppi doctor",
    notes: [
      "Doctor exits non-zero for critical failures.",
      "It inspects TLS files but does not generate missing certificate material.",
    ],
    examples: [{ command: "oppi doctor" }],
  },
  {
    path: ["update"],
    title: "Update",
    summary: "Check or update the npm-installed Oppi server and CLI.",
    usage: "oppi update [flags]",
    flags: [
      { name: "--check", summary: "check update status without installing" },
      { name: "--dry", summary: "show the npm update command without installing" },
    ],
    notes: [
      "Oppi server and CLI versions are installed together as the oppi-server npm package.",
      "Restart the running server after an update.",
    ],
    examples: [{ command: "oppi update --check" }, { command: "oppi update" }],
  },
  {
    path: ["token"],
    title: "Token",
    summary: "Rotate the owner bearer token.",
    usage: "oppi token rotate",
    subcommands: [{ name: "rotate", summary: "generate a new owner token" }],
    notes: [
      "Existing clients become unauthorized after rotation and must be paired again.",
      "The server must already be paired before token rotation can run.",
    ],
    examples: [{ command: "oppi token rotate" }],
  },
  {
    path: ["token", "rotate"],
    title: "Rotate owner token",
    summary: "Generate a new owner bearer token and invalidate existing clients.",
    usage: "oppi token rotate",
    notes: ["Existing clients must be re-paired with 'oppi pair' after rotation."],
    examples: [{ command: "oppi token rotate" }],
  },
  {
    path: ["config"],
    title: "Config",
    summary: "Show, read, update, or validate local Oppi server config.",
    usage: "oppi config <subcommand> [args] [flags]",
    subcommands: [
      { name: "show", summary: "print current config as formatted JSON" },
      { name: "get <key>", summary: "print one config value" },
      { name: "set <key> <value>", summary: "update one supported config value" },
      { name: "validate", summary: "validate a config file" },
    ],
    notes: [
      "Config paths use dot notation, for example tls.mode or runtimeEnv.TTS_BASE_URL.",
      "Run 'oppi config set --help' for common keys and value formats.",
    ],
    examples: [
      { command: "oppi config show" },
      { command: "oppi config get port" },
      { command: "oppi config set asr.sttEndpoint http://127.0.0.1:7936" },
    ],
  },
  {
    path: ["config", "show"],
    title: "Show config",
    summary: "Print current or default config as formatted JSON.",
    usage: "oppi config show [--default]",
    flags: [{ name: "--default", summary: "show built-in defaults instead of current config" }],
    examples: [{ command: "oppi config show" }, { command: "oppi config show --default" }],
  },
  {
    path: ["config", "get"],
    title: "Get config",
    summary: "Print one config value.",
    usage: "oppi config get <key>",
    arguments: [
      { name: "<key>", summary: "config path such as port, tls.mode, or runtimeEnv.NAME" },
    ],
    notes: ["The output is intentionally plain so scripts can read it."],
    examples: [{ command: "oppi config get port" }, { command: "oppi config get tls.mode" }],
  },
  {
    path: ["config", "set"],
    title: "Set config",
    summary: "Update one supported config value.",
    usage: "oppi config set <key> <value>",
    arguments: [
      { name: "<key>", summary: "supported config key or runtimeEnv.<NAME>" },
      { name: "<value>", summary: "string, number, boolean, or JSON depending on the key" },
    ],
    keys: [
      { name: "port", summary: "number; server port" },
      { name: "host", summary: "string; bind address" },
      { name: "maxSessionsGlobal", summary: "number; global concurrent session limit" },
      { name: "runtimePathEntries", summary: "JSON array; runtime PATH entries" },
      { name: "runtimeEnv.<NAME>", summary: "string; one runtime environment variable" },
      { name: "tls.mode", summary: "string; disabled, self-signed, tailscale, or manual" },
      { name: "tls.certPath", summary: "string; manual TLS certificate path" },
      { name: "asr.sttEndpoint", summary: "string; STT backend base URL" },
      { name: "images.autoResize", summary: "boolean; resize large image uploads" },
      { name: "extensions.voice.defaultVoiceId", summary: "string; saved voice id" },
    ],
    notes: [
      'JSON-valued keys must receive valid JSON, for example \'{"mode":"self-signed"}\'.',
      "Run 'oppi config set' without enough arguments to print the complete supported-key list with current values.",
    ],
    examples: [
      { command: "oppi config set port 8080" },
      { command: "oppi config set runtimeEnv.TTS_BASE_URL http://127.0.0.1:7937" },
      { command: "oppi config set tls.mode self-signed" },
    ],
  },
  {
    path: ["config", "validate"],
    title: "Validate config",
    summary: "Validate a config file and report errors or warnings.",
    usage: "oppi config validate [--config-file <path>]",
    flags: [
      {
        name: "--config-file",
        value: "<path>",
        summary: "config file to validate; defaults to current config",
      },
    ],
    examples: [
      { command: "oppi config validate" },
      { command: "oppi config validate --config-file /tmp/config.json" },
    ],
  },
  {
    path: ["server"],
    title: "Background server",
    summary: "Manage the macOS LaunchAgent background server.",
    usage: "oppi server <subcommand> [flags]",
    subcommands: [
      { name: "install", summary: "install the LaunchAgent" },
      { name: "uninstall", summary: "remove the LaunchAgent" },
      { name: "status", summary: "show LaunchAgent status" },
      { name: "restart", summary: "restart the background server" },
      { name: "stop", summary: "stop the background server" },
    ],
    notes: ["The LaunchAgent starts Oppi automatically on login and restarts it after crashes."],
    examples: [
      { command: "oppi server install" },
      { command: "oppi server status" },
      { command: "oppi server restart" },
    ],
  },
  {
    path: ["server", "install"],
    title: "Install background server",
    summary: "Install the LaunchAgent that starts Oppi on login.",
    usage: "oppi server install [--data-dir <path>]",
    flags: [
      { name: "--data-dir", value: "<path>", summary: "data directory for the installed service" },
    ],
    examples: [
      { command: "oppi server install" },
      { command: "oppi server install --data-dir ~/.config/oppi" },
    ],
  },
  {
    path: ["server", "uninstall"],
    title: "Uninstall background server",
    summary: "Remove the Oppi LaunchAgent.",
    usage: "oppi server uninstall",
    examples: [{ command: "oppi server uninstall" }],
  },
  {
    path: ["server", "status"],
    title: "Background server status",
    summary: "Show LaunchAgent installation, PID, runtime path, CLI path, and data dir.",
    usage: "oppi server status",
    examples: [{ command: "oppi server status" }],
  },
  {
    path: ["server", "restart"],
    title: "Restart background server",
    summary: "Restart the background server through launchd.",
    usage: "oppi server restart",
    notes: ["Use this after config or runtime changes when Oppi is running as a LaunchAgent."],
    examples: [{ command: "oppi server restart" }],
  },
  {
    path: ["server", "stop"],
    title: "Stop background server",
    summary: "Stop the background server through launchd.",
    usage: "oppi server stop",
    examples: [{ command: "oppi server stop" }],
  },
  {
    path: ["version"],
    title: "Version",
    summary: "Print the installed oppi-server package version.",
    usage: "oppi version",
    notes: ["Aliases: oppi --version, oppi -v."],
    examples: [{ command: "oppi version" }],
  },
  {
    path: ["workspace"],
    title: "Workspaces",
    summary:
      "List, inspect, create, update, and delete configured Oppi workspaces through the local API.",
    usage: "oppi workspace <subcommand> [flags]",
    subcommands: [
      { name: "list", summary: "list configured workspaces" },
      { name: "get <workspace>", summary: "show one workspace by id or unique name" },
      { name: "create", summary: "create a workspace from flags and an optional JSON definition" },
      { name: "update <workspace>", summary: "update a workspace from flags or JSON" },
      { name: "delete <workspace>", summary: "delete a workspace from the server catalog" },
    ],
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    examples: [
      { command: "oppi workspace list" },
      { command: "oppi workspace create --name Oppi --host-mount ~/workspace/oppi --json" },
      { command: "oppi workspace get oppi --json" },
    ],
  },
  {
    path: ["workspace", "list"],
    title: "List workspaces",
    summary: "List configured workspaces.",
    usage: "oppi workspace list [--json]",
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    examples: [{ command: "oppi workspace list" }, { command: "oppi workspace list --json" }],
  },
  {
    path: ["workspace", "get"],
    title: "Get workspace",
    summary: "Show one workspace by workspace id or unique name.",
    usage: "oppi workspace get <workspace> [--json]",
    arguments: [{ name: "<workspace>", summary: "workspace id or unique name" }],
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    examples: [
      { command: "oppi workspace get ws_123" },
      { command: "oppi workspace get oppi --json" },
    ],
  },
  {
    path: ["workspace", "create"],
    title: "Create workspace",
    summary:
      "Create a workspace from --name, optional field flags, and an optional JSON definition file.",
    usage:
      "oppi workspace create --name <name> [--host-mount <path>] [--definition <file>] [--json]",
    flags: [
      { name: "--name", value: "<name>", summary: "workspace display name", required: true },
      {
        name: "--host-mount",
        value: "<path>",
        summary: "host directory mounted as the workspace root",
      },
      { name: "--description", value: "<text>", summary: "workspace description" },
      { name: "--icon", value: "<text>", summary: "SF Symbol name or emoji" },
      { name: "--system-prompt", value: "<text>", summary: "workspace system prompt text" },
      { name: "--default-model", value: "<model>", summary: "default model for new sessions" },
      { name: "--runtime", value: "<host|sandbox>", summary: "workspace runtime mode" },
      { name: "--definition", value: "<file>", summary: "JSON CreateWorkspaceRequest fields" },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    examples: [
      { command: "oppi workspace create --name Oppi --host-mount ~/workspace/oppi --json" },
    ],
  },
  {
    path: ["workspace", "update"],
    title: "Update workspace",
    summary: "Update a workspace by id or unique name from field flags or a JSON definition file.",
    usage: "oppi workspace update <workspace> [--name <name>] [--definition <file>] [--json]",
    arguments: [{ name: "<workspace>", summary: "workspace id or unique name" }],
    flags: [
      { name: "--name", value: "<name>", summary: "workspace display name" },
      {
        name: "--host-mount",
        value: "<path>",
        summary: "host directory mounted as the workspace root",
      },
      { name: "--description", value: "<text>", summary: "workspace description" },
      { name: "--icon", value: "<text>", summary: "SF Symbol name or emoji" },
      { name: "--system-prompt", value: "<text>", summary: "workspace system prompt text" },
      { name: "--default-model", value: "<model>", summary: "default model for new sessions" },
      { name: "--runtime", value: "<host|sandbox>", summary: "workspace runtime mode" },
      { name: "--definition", value: "<file>", summary: "JSON UpdateWorkspaceRequest fields" },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    examples: [{ command: "oppi workspace update ws_123 --default-model openai/gpt-5.5 --json" }],
  },
  {
    path: ["workspace", "delete"],
    title: "Delete workspace",
    summary: "Delete a workspace from the server catalog.",
    usage: "oppi workspace delete <workspace> [--json]",
    arguments: [{ name: "<workspace>", summary: "workspace id or unique name" }],
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    examples: [{ command: "oppi workspace delete ws_123 --json" }],
  },
  {
    path: ["worktree"],
    title: "Worktrees",
    summary: "List, create, open, and remove workspace git worktrees.",
    usage: "oppi worktree <subcommand> --workspace <workspace> [flags]",
    subcommands: [
      { name: "list", summary: "list discovered and Oppi-managed worktrees" },
      {
        name: "get <worktree>",
        summary: "show one worktree by id or name; main is the default checkout",
      },
      { name: "create", summary: "create an Oppi-managed worktree under OPPI_DATA_DIR" },
      { name: "open", summary: "resolve an existing worktree by branch or path" },
      { name: "status <worktree>", summary: "show worktree metadata and git status" },
      { name: "preview <worktree>", summary: "preview integration into a target branch" },
      { name: "remove <worktree>", summary: "remove an Oppi-managed worktree" },
    ],
    flags: [
      {
        name: "--workspace",
        value: "<workspace>",
        summary: "workspace id or unique name",
        required: true,
      },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    notes: [
      "New worktrees are created under OPPI_DATA_DIR/worktrees/<workspaceId>/.",
      "Project-local .pi/worktrees entries remain discoverable, but remove only touches Oppi-managed data-dir worktrees.",
    ],
    examples: [
      { command: "oppi worktree list --workspace ws_123" },
      { command: "oppi worktree create --workspace ws_123 --branch feature/foo --json" },
      {
        command:
          "oppi worktree preview wt_feature-foo-abc12345 --workspace ws_123 --into main --json",
      },
      { command: "oppi worktree remove wt_feature-foo-abc12345 --workspace ws_123 --json" },
    ],
  },
  {
    path: ["worktree", "list"],
    title: "List worktrees",
    summary: "List discovered worktrees for one workspace.",
    usage: "oppi worktree list --workspace <workspace> [--json]",
    flags: [
      {
        name: "--workspace",
        value: "<workspace>",
        summary: "workspace id or unique name",
        required: true,
      },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    examples: [{ command: "oppi worktree list --workspace ws_123" }],
  },
  {
    path: ["worktree", "get"],
    title: "Get worktree",
    summary: "Show one discovered worktree by id or name.",
    usage: "oppi worktree get <worktree> --workspace <workspace> [--json]",
    arguments: [
      { name: "<worktree>", summary: "worktree id or name; main is the primary checkout" },
    ],
    flags: [
      {
        name: "--workspace",
        value: "<workspace>",
        summary: "workspace id or unique name",
        required: true,
      },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    examples: [{ command: "oppi worktree get main --workspace ws_123 --json" }],
  },
  {
    path: ["worktree", "create"],
    title: "Create worktree",
    summary: "Create an Oppi-managed git worktree under OPPI_DATA_DIR.",
    usage: "oppi worktree create --workspace <workspace> --branch <branch> [--base <ref>] [--json]",
    flags: [
      {
        name: "--workspace",
        value: "<workspace>",
        summary: "workspace id or unique name",
        required: true,
      },
      {
        name: "--branch",
        value: "<branch>",
        summary: "branch to create or check out",
        required: true,
      },
      { name: "--base", value: "<ref>", summary: "base ref for a new branch; defaults to HEAD" },
      {
        name: "--path",
        value: "<path>",
        summary: "optional direct child path under OPPI_DATA_DIR/worktrees/<workspaceId>",
      },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    notes: [
      "If the branch already exists, Oppi checks out that branch in a new worktree.",
      "Retained session history reserves its worktree id, so the same branch or custom path cannot be recreated until that history is deleted.",
      "Custom paths are rejected unless they stay inside the Oppi-managed data-dir root.",
    ],
    examples: [
      { command: "oppi worktree create --workspace ws_123 --branch feature/foo --json" },
      { command: "oppi worktree create --workspace oppi --branch fix/crash --base main" },
    ],
  },
  {
    path: ["worktree", "open"],
    title: "Open worktree",
    summary: "Resolve an existing worktree by branch or path.",
    usage:
      "oppi worktree open --workspace <workspace> (--branch <branch> | --path <path>) [--json]",
    flags: [
      {
        name: "--workspace",
        value: "<workspace>",
        summary: "workspace id or unique name",
        required: true,
      },
      { name: "--branch", value: "<branch>", summary: "existing branch name" },
      { name: "--path", value: "<path>", summary: "existing worktree path" },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    examples: [{ command: "oppi worktree open --workspace ws_123 --branch feature/foo --json" }],
  },
  {
    path: ["worktree", "status"],
    title: "Worktree status",
    summary: "Show worktree metadata and git status without changing files.",
    usage: "oppi worktree status <worktree> --workspace <workspace> [--json]",
    arguments: [{ name: "<worktree>", summary: "worktree id" }],
    flags: [
      {
        name: "--workspace",
        value: "<workspace>",
        summary: "workspace id or unique name",
        required: true,
      },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    examples: [{ command: "oppi worktree status wt_feature-foo-abc12345 --workspace ws_123" }],
  },
  {
    path: ["worktree", "preview"],
    title: "Preview worktree integration",
    summary: "Preview commits, changed files, fast-forward status, and conflicts before merging.",
    usage:
      "oppi worktree preview <worktree> --workspace <workspace> --into <branch> [--mode <mode>] [--json]",
    arguments: [{ name: "<worktree>", summary: "source worktree id" }],
    flags: [
      {
        name: "--workspace",
        value: "<workspace>",
        summary: "workspace id or unique name",
        required: true,
      },
      { name: "--into", value: "<branch>", summary: "target branch or ref", required: true },
      {
        name: "--mode",
        value: "<merge|squash|ff-only>",
        summary: "intended completion mode; defaults to merge",
      },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    notes: [
      "Preview is read-only and is the command agents should run before asking to complete or remove a worktree.",
    ],
    examples: [
      {
        command:
          "oppi worktree preview wt_feature-foo-abc12345 --workspace ws_123 --into main --json",
      },
    ],
  },
  {
    path: ["worktree", "remove"],
    title: "Remove worktree",
    summary: "Remove an Oppi-managed data-dir worktree.",
    usage: "oppi worktree remove <worktree> --workspace <workspace> [--force] [--json]",
    arguments: [{ name: "<worktree>", summary: "Oppi-managed worktree id" }],
    flags: [
      {
        name: "--workspace",
        value: "<workspace>",
        summary: "workspace id or unique name",
        required: true,
      },
      { name: "--force", summary: "allow removing dirty worktrees" },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    notes: [
      "Remove keeps stopped session history, but refuses the main checkout, project-local .pi/worktrees entries, and worktrees with active sessions.",
      "Retained history reserves the removed worktree id until that history is deleted.",
    ],
    examples: [{ command: "oppi worktree remove wt_feature-foo-abc12345 --workspace ws_123" }],
  },
  {
    path: ["wait"],
    title: "Wait",
    summary: "Poll session state until a condition is true.",
    usage: "oppi wait session <id> --status <status> [flags]",
    subcommands: [{ name: "session <id>", summary: "wait for a session status" }],
    flags: [
      { name: "--status", value: "<status>", summary: "target status; defaults to stopped" },
      {
        name: "--timeout",
        value: "<duration>",
        summary: "maximum wait such as 900, 30s, or 5m; bare numbers are seconds",
      },
      {
        name: "--poll",
        value: "<duration>",
        summary: "poll interval such as 1 or 500ms; bare numbers are seconds (default 1s)",
      },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    examples: [{ command: "oppi wait session sess_123 --status stopped --json" }],
  },
  {
    path: ["wait", "session"],
    title: "Wait for a session",
    summary: "Poll one session until its status matches.",
    usage: "oppi wait session <id> --status <status> [--timeout <duration>] [--json]",
    arguments: [{ name: "<id>", summary: "session id" }],
    flags: [
      { name: "--status", value: "<status>", summary: "target status; defaults to stopped" },
      {
        name: "--timeout",
        value: "<duration>",
        summary: "maximum wait such as 900, 30s, or 10m; bare numbers are seconds",
      },
      {
        name: "--poll",
        value: "<duration>",
        summary: "poll interval such as 1 or 500ms; bare numbers are seconds (default 1s)",
      },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    examples: [{ command: "oppi wait session sess_123 --status stopped --timeout 10m --json" }],
  },
  {
    path: ["schedule"],
    title: "Schedules",
    summary: "Schedules run Oppi actions later, repeatedly, or from a cron expression.",
    usage: "oppi schedule <subcommand> [flags]",
    description: [
      "A schedule stores a trigger plus a new-session or existing-session action.",
      "New-session schedules can use workspace defaults or a saved Agent; manual and automatic runs keep history for inspection.",
    ],
    subcommands: [
      { name: "list", summary: "list schedules" },
      { name: "get <id>", summary: "show one schedule" },
      { name: "create", summary: "create a new-session or existing-session schedule" },
      { name: "update <id>", summary: "patch a schedule from a JSON definition" },
      { name: "run <id>", summary: "run a schedule now" },
      { name: "runs <id>", summary: "show run history for a schedule" },
      { name: "pause <id>", summary: "pause future automatic runs" },
      { name: "resume <id>", summary: "resume automatic runs" },
      { name: "archive <id>", summary: "archive a schedule" },
      { name: "restore <id>", summary: "restore an archived schedule as active" },
    ],
    notes: ["Run 'oppi schedule create --help' for exact creation flags."],
    examples: [
      {
        command: 'oppi schedule create --workspace ws_123 --prompt "Check tests" --every 1h',
      },
      { command: "oppi schedule run sch_123 --request-id retry-001" },
      { command: "oppi schedule runs sch_123 --json" },
    ],
  },
  {
    path: ["schedule", "create"],
    title: "Create a schedule",
    summary: "Create a schedule that launches a new workspace session when its trigger fires.",
    usage:
      "oppi schedule create (--workspace <workspace> | --session <session>) --prompt <text> (--at <iso> | --every <duration> | --cron <expr>) [flags]",
    flags: [
      {
        name: "--workspace",
        value: "<workspace>",
        summary: "workspace id or unique name to launch in",
      },
      {
        name: "--session",
        value: "<session>",
        summary: "existing session id to send future prompts to",
      },
      {
        name: "--prompt",
        value: "<text>",
        summary: "prompt sent when the schedule runs",
        required: true,
      },
      { name: "--at", value: "<iso>", summary: "run once at an ISO timestamp" },
      { name: "--every", value: "<duration>", summary: "repeat interval such as 15m, 1h, or 1d" },
      { name: "--cron", value: "<expr>", summary: "cron expression for repeated runs" },
      { name: "--tz", value: "<zone>", summary: "IANA time zone; defaults to the local zone" },
      { name: "--name", value: "<text>", summary: "schedule and launched-session name" },
      {
        name: "--model",
        value: "<model>",
        summary: "model override; fuzzy-matched against enabled Pi models",
      },
      {
        name: "--agent",
        value: "<agent>",
        summary: "saved Agent id/name for new-session schedules",
      },
      { name: "--worktree", value: "<id>", summary: "workspace worktree id" },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    notes: [
      "Choose exactly one trigger flag: --at, --every, or --cron.",
      "Choose exactly one target flag: --workspace or --session.",
      "Use --agent only with --workspace; existing-session schedules send prompts to the selected session.",
      "Run history is available with 'oppi schedule runs <id>'.",
      "Manual runs are idempotent when you reuse 'oppi schedule run <id> --request-id <key>'; automatic runs use their schedule slot as the idempotency key.",
      "--model accepts exact provider/model IDs or fuzzy text like sonnet; it resolves against /models, which is filtered by Pi enabledModels.",
    ],
    examples: [
      {
        command:
          'oppi schedule create --workspace ws_123 --prompt "Summarize overnight failures" --at 2026-06-29T09:00:00Z',
      },
      {
        command:
          'oppi schedule create --workspace ws_123 --prompt "Run npm test" --every 1h --name "Hourly test check"',
      },
      {
        command:
          'oppi schedule create --workspace ws_123 --prompt "Prepare Monday status" --cron "0 9 * * 1" --tz America/Los_Angeles',
      },
    ],
  },
  {
    path: ["schedule", "list"],
    title: "List schedules",
    summary: "List configured schedules.",
    usage:
      "oppi schedule list [--workspace <workspace>] [--session <session>] [--agent <agent>] [--json]",
    flags: [
      { name: "--workspace", value: "<workspace>", summary: "filter by workspace id or name" },
      { name: "--session", value: "<session>", summary: "filter by existing-session target" },
      { name: "--agent", value: "<agent>", summary: "filter by saved Agent id" },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    examples: [
      { command: "oppi schedule list" },
      { command: "oppi schedule list --agent Reviewer --json" },
    ],
  },
  {
    path: ["schedule", "get"],
    title: "Get schedule",
    summary: "Show one schedule by id.",
    usage: "oppi schedule get <id> [--json]",
    arguments: [{ name: "<id>", summary: "schedule id" }],
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    examples: [{ command: "oppi schedule get sch_123" }],
  },
  {
    path: ["schedule", "update"],
    title: "Update schedule",
    summary: "Patch a schedule from a definition or a focused model update.",
    usage:
      "oppi schedule update <id> (--definition <file> | --definition-json <json-object> | --model <model> | --clear-model) [--json]",
    arguments: [{ name: "<id>", summary: "schedule id" }],
    flags: [
      {
        name: "--definition",
        value: "<file>",
        summary: "JSON object with schedule fields to patch",
      },
      {
        name: "--definition-json",
        value: "<json-object>",
        summary: "inline JSON Merge Patch object; maximum 65536 bytes",
      },
      { name: "--model", value: "<model>", summary: "update a new-session schedule model" },
      {
        name: "--clear-model",
        summary: "remove the explicit new-session model so the Agent or workspace default applies",
      },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    notes: [
      "Choose one update input. Omitted fields are unchanged; in definition JSON, null clears optional action fields.",
      "Action type changes require a complete action definition.",
    ],
    examples: [
      { command: "oppi schedule update sch_123 --model ds4/deepseek-v4-flash --json" },
      { command: "oppi schedule update sch_123 --clear-model --json" },
      {
        command: `oppi schedule update sch_123 --definition-json '{"action":{"model":"ds4/deepseek-v4-flash"}}' --json`,
      },
    ],
  },
  {
    path: ["schedule", "run"],
    title: "Run schedule",
    summary: "Create or reuse a manual run for a schedule and dispatch it now.",
    usage: "oppi schedule run <id> [--request-id <key>] [--json]",
    arguments: [{ name: "<id>", summary: "schedule id" }],
    flags: [
      {
        name: "--request-id",
        value: "<key>",
        summary: "manual-run idempotency key; defaults to the current timestamp",
      },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    notes: [
      "Manual runs are idempotent by schedule id plus --request-id.",
      "Reuse the same --request-id when retrying after a timeout or network failure.",
    ],
    examples: [
      { command: "oppi schedule run sch_123" },
      { command: "oppi schedule run sch_123 --request-id deploy-check-001 --json" },
    ],
  },
  {
    path: ["schedule", "runs"],
    title: "Schedule run history",
    summary: "Show run history for a schedule.",
    usage: "oppi schedule runs <id> [--json]",
    arguments: [{ name: "<id>", summary: "schedule id" }],
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    examples: [{ command: "oppi schedule runs sch_123" }],
  },
  {
    path: ["schedule", "pause"],
    title: "Pause schedule",
    summary: "Pause future automatic runs for a schedule.",
    usage: "oppi schedule pause <id> [--json]",
    arguments: [{ name: "<id>", summary: "schedule id" }],
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    examples: [{ command: "oppi schedule pause sch_123" }],
  },
  {
    path: ["schedule", "resume"],
    title: "Resume schedule",
    summary: "Resume automatic runs for a paused schedule.",
    usage: "oppi schedule resume <id> [--json]",
    arguments: [{ name: "<id>", summary: "schedule id" }],
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    examples: [{ command: "oppi schedule resume sch_123" }],
  },
  {
    path: ["schedule", "archive"],
    title: "Archive schedule",
    summary: "Archive a schedule so it no longer runs automatically.",
    usage: "oppi schedule archive <id> [--json]",
    arguments: [{ name: "<id>", summary: "schedule id" }],
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    examples: [{ command: "oppi schedule archive sch_123" }],
  },
  {
    path: ["schedule", "restore"],
    title: "Restore schedule",
    summary: "Restore an archived schedule and activate future automatic runs.",
    usage: "oppi schedule restore <id> [--json]",
    arguments: [{ name: "<id>", summary: "schedule id" }],
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    examples: [{ command: "oppi schedule restore sch_123" }],
  },
  {
    path: ["session"],
    title: "Sessions",
    summary:
      "List, launch, inspect, steer, watch, resume, fork, and stop Oppi sessions through the local server API.",
    usage: "oppi session <subcommand> [flags]",
    subcommands: [
      { name: "list", summary: "list sessions" },
      { name: "get <id>", summary: "show session metadata" },
      { name: "create", summary: "launch a workspace session" },
      { name: "send <id>", summary: "send text; steer a busy turn or queue a follow-up" },
      { name: "abort <id>", summary: "abort the current turn" },
      { name: "dialogs <id>", summary: "list pending ask/extension-UI dialogs" },
      { name: "respond <id>", summary: "answer a pending dialog" },
      { name: "watch <id...>", summary: "stream state transitions for sessions" },
      { name: "wait <id>", summary: "block until idle or attention" },
      { name: "read <id>", summary: "show transcript-style trace entries" },
      { name: "events <id>", summary: "read live catch-up events" },
      { name: "trace <id>", summary: "show raw trace entries" },
      { name: "search <query>", summary: "search session content" },
      { name: "inspect <id>", summary: "inspect selected turns from a session trace" },
      { name: "stop <id>", summary: "stop a session" },
      { name: "resume <id>", summary: "resume a stopped session" },
      { name: "fork <id>", summary: "fork a session from a trace entry" },
      { name: "delete <id>", summary: "delete a session" },
      { name: "changes <id>", summary: "list files changed by a session" },
      { name: "diff <id>", summary: "show a changed file diff" },
      { name: "tool-output <id> <tool>", summary: "show stored tool output" },
      { name: "trace-page <id>", summary: "show paged trace entries" },
      { name: "trace-outline <id>", summary: "show a trace outline" },
    ],
    notes: [
      "Plain 'send' prompts an idle session and steers a busy session at the next turn boundary; use '--follow-up' to wait until current work finishes.",
      "Orchestrate with 'watch <id...>' for live transitions and 'wait <id>' to block on one condition.",
      "Inspect history progressively: 'inspect <id> --view summary' for counts, '--view outline' to choose turns, then '--view messages' or '--view tools'.",
    ],
    examples: [
      { command: "oppi session watch sess_123 --until idle" },
      { command: 'oppi session send sess_123 --text "focus on the failing test"' },
      { command: "oppi session inspect sess_123 --view outline" },
    ],
  },
  {
    path: ["session", "list"],
    title: "List sessions",
    summary:
      "List app-style session rows, optionally filtered by workspace, worktree, status, or limit.",
    usage: "oppi session list [--workspace <workspace>] [--worktree <worktree>] [--json]",
    flags: [
      { name: "--workspace", value: "<workspace>", summary: "workspace id or unique name" },
      { name: "--worktree", value: "<worktree>", summary: "worktree id" },
      {
        name: "--status",
        value: "<status>",
        summary: "active, stopped, or a concrete session status",
      },
      { name: "--limit", value: "<count>", summary: "maximum sessions to return" },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    notes: [
      "Without --workspace, this uses the same recent cross-workspace projection as the app home view.",
      "With --workspace, this uses the workspace session-list projection and includes importable local Pi TUI sessions.",
    ],
    examples: [{ command: "oppi session list --workspace ws_123 --json" }],
  },
  {
    path: ["session", "get"],
    title: "Get session",
    summary: "Show session metadata without dumping transcript or trace entries.",
    usage: "oppi session get <id> [--json]",
    arguments: [{ name: "<id>", summary: "session id" }],
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    examples: [{ command: "oppi session get sess_123 --json" }],
  },
  {
    path: ["session", "send"],
    title: "Send to session",
    summary: "Prompt an idle session, steer a busy session, or queue a follow-up.",
    usage: "oppi session send <id> --text <text> [--steer | --follow-up] [--json]",
    arguments: [{ name: "<id>", summary: "session id" }],
    flags: [
      { name: "--text", value: "<text>", summary: "message text to send", required: true },
      { name: "--steer", summary: "require a busy session and steer at the next turn boundary" },
      {
        name: "--follow-up",
        summary: "require a busy session and wait until current work finishes",
      },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    notes: [
      "Pass @- to --text to read the message from stdin.",
      "Without a delivery flag, send prompts an idle session and steers a busy session after its current tool calls, before the next model turn.",
      "Use --follow-up for work that should begin only after the agent finishes its current work.",
    ],
    examples: [
      { command: 'oppi session send sess_123 --text "Focus on the failing test"' },
      { command: 'oppi session send sess_123 --text "Afterward, summarize the fix" --follow-up' },
    ],
  },
  {
    path: ["session", "abort"],
    title: "Abort turn",
    summary: "Abort the current streaming turn without stopping the session.",
    usage: "oppi session abort <id> [--json]",
    arguments: [{ name: "<id>", summary: "session id" }],
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    notes: ["Aborts the in-flight turn only; use 'session stop' to end the session."],
    examples: [{ command: "oppi session abort sess_123" }],
  },
  {
    path: ["session", "dialogs"],
    title: "List pending dialogs",
    summary: "List pending ask/extension-UI dialogs a session is blocked on.",
    usage: "oppi session dialogs <id> [--json]",
    arguments: [{ name: "<id>", summary: "session id" }],
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    notes: ["Each row shows the request id, method, prompt, and options for 'session respond'."],
    examples: [{ command: "oppi session dialogs sess_123 --json" }],
  },
  {
    path: ["session", "respond"],
    title: "Respond to a dialog",
    summary: "Answer a pending ask/extension-UI dialog with text, an option, confirm, or cancel.",
    usage:
      "oppi session respond <id> [--dialog <requestId>] [--text <value> | --option <value> | --answers <json> | --confirm | --decline | --cancel] [--json]",
    arguments: [{ name: "<id>", summary: "session id" }],
    flags: [
      {
        name: "--dialog",
        value: "<requestId>",
        summary: "target dialog; optional when only one is pending",
      },
      { name: "--text", value: "<value>", summary: "free-text answer" },
      { name: "--option", value: "<value>", summary: "selected option value" },
      { name: "--answers", value: "<json>", summary: "ask answers object for multi-question asks" },
      { name: "--confirm", summary: "confirm a confirm dialog" },
      { name: "--decline", summary: "decline a confirm dialog" },
      { name: "--cancel", summary: "cancel/dismiss the dialog" },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    notes: [
      "Use --option for select, --text for input, and --confirm/--decline for confirm.",
      "Single-question asks accept --text/--option; multi-question asks need --answers.",
      "Choose exactly one response flag.",
    ],
    examples: [
      { command: "oppi session respond sess_123 --option unit" },
      { command: `oppi session respond sess_123 --dialog ask-1 --answers '{"approach":"unit"}'` },
    ],
  },
  {
    path: ["session", "watch"],
    title: "Watch sessions",
    summary: "Stream one compact line per state transition for one or more sessions.",
    usage:
      "oppi session watch <id...> [--until idle|attention|any-change] [--all] [--interval <duration>] [--timeout <duration>] [--json]",
    arguments: [{ name: "<id...>", summary: "one or more session ids" }],
    flags: [
      {
        name: "--until",
        value: "<condition>",
        summary: "exit on idle, attention, or any-change (default idle)",
      },
      { name: "--all", summary: "require every watched session to meet --until (default any)" },
      {
        name: "--interval",
        value: "<duration>",
        summary: "poll interval such as 2 or 500ms; bare numbers are seconds (default 2s)",
      },
      {
        name: "--timeout",
        value: "<duration>",
        summary: "max watch time such as 900, 30s, or 30m; bare numbers are seconds (default 30m)",
      },
      { name: "--json", summary: "emit NDJSON transition/resolution events" },
    ],
    notes: [
      "Emits transitions only; the matching transition is the resolution event. any-change also detects event activity without a status change.",
      "With --all, idle/attention must hold for every session at resolution; exits nonzero on timeout.",
    ],
    examples: [
      { command: "oppi session watch sess_123 --until idle" },
      { command: "oppi session watch sess_1 sess_2 --until attention --json" },
    ],
  },
  {
    path: ["session", "wait"],
    title: "Wait for a session",
    summary: "Block until a session is idle or needs attention, then print the terminal state.",
    usage: "oppi session wait <id> [--for idle|attention|either] [--timeout <duration>] [--json]",
    arguments: [{ name: "<id>", summary: "session id" }],
    flags: [
      {
        name: "--for",
        value: "<condition>",
        summary: "idle, attention, or either (default either)",
      },
      {
        name: "--timeout",
        value: "<duration>",
        summary: "max wait such as 900, 30s, or 10m; bare numbers are seconds (default 10m)",
      },
      {
        name: "--poll",
        value: "<duration>",
        summary: "poll interval such as 1 or 500ms; bare numbers are seconds (default 1s)",
      },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    notes: ["Use watch for multiple sessions or live state transitions."],
    examples: [{ command: "oppi session wait sess_123 --for idle --json" }],
  },
  {
    path: ["session", "read"],
    title: "Read session transcript",
    summary: "Read transcript-style trace entries for a session.",
    usage: "oppi session read <id> [--tail <count>] [--json]",
    arguments: [{ name: "<id>", summary: "session id" }],
    flags: [
      { name: "--tail", value: "<count>", summary: "return only the last trace entries" },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    examples: [{ command: "oppi session read sess_123 --tail 50 --json" }],
  },
  {
    path: ["session", "events"],
    title: "Session events",
    summary: "Read live catch-up events for an active session.",
    usage: "oppi session events <id> [--since <cursor>] [--json]",
    arguments: [{ name: "<id>", summary: "session id" }],
    flags: [
      { name: "--since", value: "<cursor>", summary: "event sequence cursor" },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    examples: [{ command: "oppi session events sess_123 --since 42 --json" }],
  },
  {
    path: ["session", "trace"],
    title: "Session trace",
    summary: "Read raw trace entries for a session.",
    usage: "oppi session trace <id> [--include <parts>] [--json]",
    arguments: [{ name: "<id>", summary: "session id" }],
    flags: [
      { name: "--include", value: "<parts>", summary: "trace parts such as summary,tools" },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    examples: [{ command: "oppi session trace sess_123 --include summary,tools --json" }],
  },
  {
    path: ["session", "stop"],
    title: "Stop session",
    summary: "Stop a session through the local API.",
    usage: "oppi session stop <id> [--json]",
    arguments: [{ name: "<id>", summary: "session id" }],
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    examples: [{ command: "oppi session stop sess_123 --json" }],
  },
  {
    path: ["session", "search"],
    title: "Search sessions",
    summary: "Search indexed session content.",
    usage:
      "oppi session search [query] [--workspace <workspace>|--all] [--since <time>] [--until <time>] [--limit <count>] [--json]",
    arguments: [{ name: "[query]", summary: "search query text" }],
    flags: [
      { name: "--query", value: "<text>", summary: "search query text" },
      {
        name: "--workspace",
        value: "<workspace>",
        summary: "filter by workspace id or name; defaults to cwd inference",
      },
      { name: "--all", summary: "search across all workspaces instead of inferring from cwd" },
      {
        name: "--since",
        value: "<time>",
        summary: "filter to sessions updated at or after this time",
      },
      {
        name: "--until",
        value: "<time>",
        summary: "filter to sessions updated at or before this time",
      },
      { name: "--limit", value: "<count>", summary: "maximum results to return" },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    notes: [
      "Without --workspace or --all, the CLI infers the workspace from the current directory.",
      "With a query, results sort by weighted full-text relevance with a small recency boost.",
      "With --since/--until and no query, results sort by updated_at descending.",
    ],
    examples: [
      { command: "oppi session search tests --workspace ws_123 --since 2026-07-01 --json" },
    ],
  },
  {
    path: ["session", "inspect"],
    title: "Inspect session",
    summary: "Inspect selected turns without dumping the full session trace.",
    usage: "oppi session inspect <id> [--turns <spec>] [--view <view>] [--json]",
    arguments: [{ name: "<id>", summary: "session id" }],
    flags: [
      {
        name: "--turns",
        value: "<spec>",
        summary: "all, one turn, a range, or comma-separated turns",
      },
      {
        name: "--view",
        value: "<view>",
        summary: "overview, outline, response, messages, summary, or tools",
      },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    notes: [
      "Without --view, inspect shows a compact outline.",
      "Use summary for counts, response for the latest assistant response, or messages/tools for selected turns.",
    ],
    examples: [
      { command: "oppi session inspect sess_123 --view summary --json" },
      { command: "oppi session inspect sess_123 --view outline --json" },
      { command: "oppi session inspect sess_123 --view response" },
      { command: "oppi session inspect sess_123 --turns 3-7 --view messages --json" },
    ],
  },
  {
    path: ["session", "resume"],
    title: "Resume session",
    summary: "Resume a stopped workspace session through the local API.",
    usage: "oppi session resume <id> [--json]",
    arguments: [{ name: "<id>", summary: "session id" }],
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    examples: [{ command: "oppi session resume sess_123 --json" }],
  },
  {
    path: ["session", "fork"],
    title: "Fork session",
    summary: "Fork a session from a trace entry.",
    usage: "oppi session fork <id> --entry <entry-id> [--name <text>] [--json]",
    arguments: [{ name: "<id>", summary: "source session id" }],
    flags: [
      {
        name: "--entry",
        value: "<entry-id>",
        summary: "trace entry id to fork from",
        required: true,
      },
      { name: "--name", value: "<text>", summary: "forked session name" },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    examples: [{ command: "oppi session fork sess_123 --entry turn-42 --json" }],
  },
  {
    path: ["session", "delete"],
    title: "Delete session",
    summary: "Delete a session through the workspace session API.",
    usage: "oppi session delete <id> [--json]",
    arguments: [{ name: "<id>", summary: "session id" }],
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    examples: [{ command: "oppi session delete sess_123 --json" }],
  },
  {
    path: ["session", "changes"],
    title: "Session changes",
    summary: "List files changed by a session.",
    usage: "oppi session changes <id> [--json]",
    arguments: [{ name: "<id>", summary: "session id" }],
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    examples: [{ command: "oppi session changes sess_123 --json" }],
  },
  {
    path: ["session", "diff"],
    title: "Session diff",
    summary: "Show the overall diff for one changed file in a session.",
    usage: "oppi session diff <id> (--path <path> | -- <path>) [--json]",
    arguments: [{ name: "<id>", summary: "session id" }],
    flags: [
      {
        name: "--path",
        value: "<path>",
        summary: "workspace-relative changed file path",
        required: true,
      },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    notes: ["Use -- before paths that begin with a dash."],
    examples: [
      { command: "oppi session diff sess_123 --path server/src/cli.ts --json" },
      { command: "oppi session diff sess_123 -- server/src/cli.ts" },
    ],
  },
  {
    path: ["session", "tool-output"],
    title: "Session tool output",
    summary: "Show stored output for one tool call.",
    usage: "oppi session tool-output <id> <tool-call-id> [--json]",
    arguments: [
      { name: "<id>", summary: "session id" },
      { name: "<tool-call-id>", summary: "tool call id" },
    ],
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    examples: [{ command: "oppi session tool-output sess_123 call_123 --json" }],
  },
  {
    path: ["session", "trace-page"],
    title: "Session trace page",
    summary: "Read a bounded trace page for a session.",
    usage: "oppi session trace-page <id> [--cursor <cursor>] [--around-entry <entry-id>] [--json]",
    arguments: [{ name: "<id>", summary: "session id" }],
    flags: [
      { name: "--cursor", value: "<cursor>", summary: "trace page cursor" },
      { name: "--around-entry", value: "<entry-id>", summary: "center the page around an entry" },
      { name: "--target-events", value: "<count>", summary: "target event count" },
      { name: "--preview-bytes", value: "<count>", summary: "tool-output preview byte budget" },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    examples: [{ command: "oppi session trace-page sess_123 --target-events 80 --json" }],
  },
  {
    path: ["session", "trace-outline"],
    title: "Session trace outline",
    summary: "Read a compact, jumpable event index for a session without full tool output.",
    usage: "oppi session trace-outline <id> [--json]",
    arguments: [{ name: "<id>", summary: "session id" }],
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    notes: [
      "This is a low-level entry index, not a turn summary; large sessions can still return many rows.",
      "Start with 'oppi session inspect <id> --view outline' unless exact entry ids are needed.",
      "Pass an entry id to 'trace-page --around-entry' for bounded surrounding detail.",
    ],
    examples: [
      { command: "oppi session inspect sess_123 --view outline --json" },
      { command: "oppi session trace-outline sess_123 --json" },
    ],
  },
  {
    path: ["agent"],
    title: "Saved Agents",
    summary: "Create, inspect, update, archive, and launch reusable Agent definitions.",
    usage: "oppi agent <subcommand> [flags]",
    subcommands: [
      { name: "list", summary: "list saved Agents" },
      { name: "get <agent>", summary: "show one saved Agent by id or unique name" },
      {
        name: "create",
        summary: "create a saved Agent from flags and optional file or inline JSON",
      },
      { name: "update <agent>", summary: "patch a saved Agent from file or inline JSON" },
      { name: "archive <agent>", summary: "archive a saved Agent" },
    ],
    notes: [
      "Agent definitions are target-agnostic; workspace/worktree/cwd are launch inputs, not stored Agent fields.",
      "Use 'oppi session create --agent <agent> --workspace <workspace> --prompt <text>' to launch a saved Agent.",
      "Server-default Agent launches and self-management extensions are separate from public saved Agent definitions.",
    ],
    examples: [
      { command: "oppi agent create --name Reviewer --definition ./agent.json --json" },
      { command: 'oppi session create --agent Reviewer --workspace ws_123 --prompt "Review this"' },
    ],
  },
  {
    path: ["agent", "list"],
    title: "List saved Agents",
    summary: "List active saved Agent definitions.",
    usage: "oppi agent list [--json]",
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    examples: [{ command: "oppi agent list --json" }],
  },
  {
    path: ["agent", "get"],
    title: "Get saved Agent",
    summary: "Show one saved Agent by agent id or unique name.",
    usage: "oppi agent get <agent> [--json]",
    arguments: [{ name: "<agent>", summary: "agent id or unique name" }],
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    examples: [{ command: "oppi agent get Reviewer --json" }],
  },
  {
    path: ["agent", "create"],
    title: "Create saved Agent",
    summary: "Create a saved Agent from --name and an optional file or inline JSON definition.",
    usage:
      "oppi agent create [--name <name>] [--definition <file> | --definition-json <json-object>] [--json]",
    flags: [
      {
        name: "--name",
        value: "<name>",
        summary: "Agent display name; overrides definition.name",
      },
      { name: "--definition", value: "<file>", summary: "JSON AgentDefinition fields" },
      {
        name: "--definition-json",
        value: "<json-object>",
        summary: "inline JSON AgentDefinition fields; maximum 65536 bytes",
      },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    notes: [
      "Choose at most one of --definition or --definition-json; --name or definition.name is required.",
      "Definitions cannot include workspace, worktree, schedule, attachments, or other launch-only fields.",
      "definition.icon uses the tagged default, emoji, symbol, or Genmoji asset-reference object.",
    ],
    examples: [
      { command: "oppi agent create --name Reviewer --definition ./agent.json --json" },
      { command: `oppi agent create --definition-json '{"name":"Reviewer"}' --json` },
    ],
  },
  {
    path: ["agent", "update"],
    title: "Update saved Agent",
    summary: "Patch a saved Agent from a JSON definition file or inline JSON object.",
    usage:
      "oppi agent update <agent> (--definition <file> | --definition-json <json-object>) [--json]",
    arguments: [{ name: "<agent>", summary: "agent id or unique name" }],
    flags: [
      {
        name: "--definition",
        value: "<file>",
        summary: "JSON AgentDefinition fields to patch",
      },
      {
        name: "--definition-json",
        value: "<json-object>",
        summary: "inline JSON AgentDefinition fields to patch; maximum 65536 bytes",
      },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    notes: ["Choose exactly one of --definition or --definition-json."],
    examples: [
      { command: "oppi agent update Reviewer --definition ./agent-update.json --json" },
      {
        command: `oppi agent update Reviewer --definition-json '{"description":"Reviews risky diffs"}' --json`,
      },
    ],
  },
  {
    path: ["agent", "archive"],
    title: "Archive saved Agent",
    summary: "Archive a saved Agent so it is hidden from normal list and launch flows.",
    usage: "oppi agent archive <agent> [--json]",
    arguments: [{ name: "<agent>", summary: "agent id or unique name" }],
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    examples: [{ command: "oppi agent archive Reviewer --json" }],
  },
  {
    path: ["skill"],
    title: "Server Skills",
    summary: "Inspect server Skills and replace files for server-authorized editable Skills.",
    usage: "oppi skill <subcommand> [flags]",
    subcommands: [
      { name: "list", summary: "list server Skills and editing capability" },
      { name: "get <skill-id>", summary: "inspect one Skill definition and file list" },
      { name: "file <skill-id>", summary: "read one contained Skill file" },
      { name: "update-file <skill-id>", summary: "replace one existing editable Skill file" },
    ],
    notes: [
      "Skill ids and editability are server-authored; package Skills are read-only.",
      "File paths must be contained relative paths from the Skill catalog.",
    ],
    examples: [
      { command: "oppi skill list --json" },
      { command: "oppi skill get skill_abc --json" },
    ],
  },
  {
    path: ["skill", "list"],
    title: "List server Skills",
    summary: "List server Skills with canonical ids and editing capability.",
    usage: "oppi skill list [--json]",
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    examples: [{ command: "oppi skill list --json" }],
  },
  {
    path: ["skill", "get"],
    title: "Get server Skill",
    summary: "Read one Skill definition and its contained file list.",
    usage: "oppi skill get <skill-id> [--json]",
    arguments: [{ name: "<skill-id>", summary: "canonical server Skill id" }],
    flags: [{ name: "--json", summary: "write the standard JSON envelope" }],
    examples: [{ command: "oppi skill get skill_abc --json" }],
  },
  {
    path: ["skill", "file"],
    title: "Read server Skill file",
    summary: "Read one existing text file contained by a server Skill.",
    usage: "oppi skill file <skill-id> --path <relative-path> [--json]",
    arguments: [{ name: "<skill-id>", summary: "canonical server Skill id" }],
    flags: [
      {
        name: "--path",
        value: "<relative-path>",
        summary: "contained Skill file path",
        required: true,
      },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    examples: [{ command: "oppi skill file skill_abc --path SKILL.md --json" }],
  },
  {
    path: ["skill", "update-file"],
    title: "Update server Skill file",
    summary: "Atomically replace one existing file for a server-authorized editable Skill.",
    usage:
      "oppi skill update-file <skill-id> --path <relative-path> --base-revision <sha256> --content-json <json-string> [--json]",
    arguments: [{ name: "<skill-id>", summary: "canonical server Skill id" }],
    flags: [
      {
        name: "--path",
        value: "<relative-path>",
        summary: "contained existing Skill file path",
        required: true,
      },
      {
        name: "--base-revision",
        value: "<sha256>",
        summary: "revision returned by the latest 'oppi skill file' read",
        required: true,
      },
      {
        name: "--content-json",
        value: "<json-string>",
        summary: "complete replacement body as a JSON string (maximum 1 MiB decoded)",
        required: true,
      },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    notes: [
      "Package Skills and other server-authorized read-only Skills cannot be changed.",
      "A stale base revision returns a conflict instead of overwriting intervening edits.",
      "The Oppi session tool requires the complete body inline for approval and rejects @-.",
    ],
    examples: [
      {
        command: `oppi skill update-file skill_abc --path SKILL.md --base-revision <sha256> --content-json '"# Updated\\n"' --json`,
      },
    ],
  },
  {
    path: ["session", "create"],
    title: "Create a session",
    summary: "Launch a workspace session and optionally send its first prompt.",
    usage: "oppi session create --workspace <workspace> --prompt <text> [flags]",
    flags: [
      {
        name: "--workspace",
        value: "<workspace>",
        summary: "workspace id or unique name to launch in",
        required: true,
      },
      {
        name: "--prompt",
        value: "<text>",
        summary: "first prompt sent to the session",
        required: true,
      },
      { name: "--name", value: "<text>", summary: "session name" },
      {
        name: "--model",
        value: "<model>",
        summary: "model override; fuzzy-matched against enabled Pi models",
      },
      { name: "--thinking", value: "<level>", summary: "thinking level override" },
      { name: "--worktree", value: "<id>", summary: "workspace worktree id" },
      {
        name: "--agent",
        value: "<agent>",
        summary: "saved Agent id/name; omit or use workspace_default for workspace defaults",
      },
      {
        name: "--allow-nested-delegation",
        summary: "authorize this child to spawn sessions; the grant propagates down the subtree",
      },
      {
        name: "--idempotency-key",
        value: "<key>",
        summary: "reuse one launch/session across retries of the same request",
      },
      { name: "--json", summary: "write the standard JSON envelope" },
    ],
    notes: [
      "Pass @- to --prompt to read the first prompt from stdin.",
      "JSON output is compact and returns the launch id as data.session_id.",
      "Managed sessions can create only direct children by default. A root may pass --allow-nested-delegation to authorize a child to spawn its own children; the grant then propagates down the subtree, so explicitly requested grandchild sessions work without re-authorizing at every level.",
      "With --idempotency-key, retrying the same create request reuses the existing launch instead of creating a duplicate session.",
      "If another launcher still owns the active lease for that key, the server can report launch_in_progress; retry with the same key.",
      "--model accepts exact provider/model IDs or fuzzy text like sonnet; it resolves against /models, which is filtered by Pi enabledModels.",
    ],
    examples: [
      {
        command:
          'oppi session create --workspace ws_123 --prompt "Inspect the failing CLI test" --idempotency-key cli-test-001',
      },
      {
        command:
          'oppi session create --agent Reviewer --workspace ws_123 --prompt "Review this" --json',
      },
    ],
  },
];

export function resolveHelpTopic(path: CliHelpPath): HelpTopic | undefined {
  const normalized = [...path].map((part) => part.toLowerCase()).filter(Boolean);
  return HELP_TOPICS.find((topic) => samePath(topic.path, normalized));
}

export function helpTopicToJson(topic: HelpTopic): HelpJsonTopic {
  return JSON.parse(JSON.stringify(topic)) as HelpJsonTopic;
}

export function renderHelpTopic(topic: HelpTopic): string {
  const lines: string[] = [];

  lines.push(`  ${c.bold(topic.title)}`);
  lines.push("");
  lines.push(`  ${topic.summary}`);
  lines.push("");

  if (topic.usage) {
    lines.push(`  ${c.bold("Usage:")} ${topic.usage}`);
    lines.push("");
  }

  appendParagraphs(lines, topic.description);
  appendExamples(lines, "Common flows", topic.commonFlows);
  appendItems(lines, "Subcommands", topic.subcommands);
  appendItems(lines, "Arguments", topic.arguments);
  appendItems(lines, "Common keys", topic.keys);
  appendFlags(lines, topic.flags);
  appendParagraphs(lines, topic.notes, "Notes");
  appendExamples(lines, "Examples", topic.examples);

  return lines.join("\n");
}

function samePath(a: readonly string[], b: readonly string[]): boolean {
  return a.length === b.length && a.every((part, index) => part === b[index]);
}

function appendParagraphs(
  lines: string[],
  paragraphs: string[] | undefined,
  heading?: string,
): void {
  if (!paragraphs || paragraphs.length === 0) return;
  if (heading) {
    lines.push(`  ${c.bold(`${heading}:`)}`);
    lines.push("");
  }
  for (const paragraph of paragraphs) {
    lines.push(`  ${paragraph}`);
  }
  lines.push("");
}

function appendItems(lines: string[], heading: string, items: HelpItem[] | undefined): void {
  if (!items || items.length === 0) return;
  lines.push(`  ${c.bold(`${heading}:`)}`);
  lines.push("");
  const width = Math.max(...items.map((item) => item.name.length));
  for (const item of items) {
    lines.push(`    ${c.cyan(item.name.padEnd(width))}  ${item.summary}`);
  }
  lines.push("");
}

function appendFlags(lines: string[], flags: HelpFlag[] | undefined): void {
  if (!flags || flags.length === 0) return;
  lines.push(`  ${c.bold("Flags:")}`);
  lines.push("");
  const labels = flags.map((flag) => `${flag.name}${flag.value ? ` ${flag.value}` : ""}`);
  const width = Math.max(...labels.map((label) => label.length));
  flags.forEach((flag, index) => {
    const label = labels[index] ?? flag.name;
    const required = flag.required ? c.yellow(" required") : "";
    lines.push(`    ${c.cyan(label.padEnd(width))}  ${flag.summary}${required}`);
  });
  lines.push("");
}

function appendExamples(
  lines: string[],
  heading: string,
  examples: HelpExample[] | undefined,
): void {
  if (!examples || examples.length === 0) return;
  lines.push(`  ${c.bold(`${heading}:`)}`);
  lines.push("");
  for (const example of examples) {
    lines.push(`    ${c.dim(example.command)}`);
    if (example.summary) lines.push(`      ${c.dim(example.summary)}`);
  }
  lines.push("");
}
