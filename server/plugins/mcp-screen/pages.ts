// The MCP Servers screen's pages, drawn from the server's MCP management: one scope's
// `mcp.json` (the global one, or a host workspace's own) with Pi's live probe, and the host's one
// OAuth sign-in. Pure: the facet (`server.ts`) probes and writes these into each page's document;
// tests read them directly.
import type {
  McpAddServerRequest,
  McpAuthFlowSnapshot,
  McpExposure,
  McpScopeSnapshot,
  McpServerSummary,
  McpServersResponse,
} from "../../src/types/mcp.js";
import type { ProjectTrustState } from "../../src/types/workspace.js";
import type {
  ScreenPage,
  ScreenRow,
  ScreenSection,
  ScreenSidebarEntry,
  ScreenStatus,
  ScreenTone,
  ScreenValue,
} from "../../src/types/screens.js";

export const MCP_SCREEN_ID = "oppi.mcp";

/**
 * The sidebar entry: the global servers in the sidebar, and a host workspace's own servers from
 * its Workspace Settings.
 */
export const MCP_SIDEBAR_ENTRY: ScreenSidebarEntry = {
  id: MCP_SCREEN_ID,
  title: "MCP Servers",
  icon: "network",
  order: 50,
  scopes: ["server", "workspace"],
  feature: "mcp",
};
/** The server-wide scope's `mcp.json`: `~/.pi/agent/mcp.json`. */
export const GLOBAL_SCOPE = "global";

/** The MCP scope a screen scope names: `server` is the global file, `workspace:<id>` its own. */
export function mcpScopeOf(scope: string): string {
  return scope.startsWith("workspace:") ? scope.slice("workspace:".length) : GLOBAL_SCOPE;
}

/** What a page is drawn from: the last probe, or why there is none yet. */
export interface McpProbe {
  readonly response?: McpServersResponse;
  readonly error?: string;
  /** The rows are the last known status while Pi's live probe runs. */
  readonly checking?: boolean;
}

interface Exposure {
  value: McpExposure;
  title: string;
  explanation: string;
}
const CODE_MODE: Exposure = {
  value: "codemode",
  title: "Code Mode",
  explanation: "Scripts find and call tools; the model doesn't see them.",
};
const EXPOSURES: Exposure[] = [
  CODE_MODE,
  {
    value: "deferred",
    title: "Deferred",
    explanation: "Tool search loads matching tools into the model context.",
  },
  { value: "direct", title: "Direct", explanation: "Tools are always declared to the model." },
  { value: "hidden", title: "Hidden", explanation: "Tools cannot be called." },
];
/** Each option carries its explanation, which the app shows under the section as it is picked. */
const exposureOptions = EXPOSURES.map(({ value, title, explanation }) => ({
  value,
  title,
  footer: explanation,
}));
const exposureOf = (value: McpExposure): Exposure =>
  EXPOSURES.find((exposure) => exposure.value === value) ?? CODE_MODE;

const STATES: Record<string, { text: string; tone: ScreenTone }> = {
  connected: { text: "Connected", tone: "success" },
  "needs-auth": { text: "Needs sign-in", tone: "warning" },
  disabled: { text: "Disabled", tone: "secondary" },
  untrusted: { text: "Needs remembered trust", tone: "warning" },
  replaced: { text: "Replaced by project", tone: "secondary" },
  failed: { text: "Failed", tone: "danger" },
  disconnected: { text: "Failed", tone: "danger" },
};

function status(state: string, checking = false): ScreenStatus {
  if (state === "unknown" && checking)
    return { text: "Checking\u2026", tone: "secondary", symbol: "circle" };
  const known = STATES[state] ?? {
    text: state.charAt(0).toUpperCase() + state.slice(1),
    tone: "secondary" as const,
  };
  return { ...known, symbol: state === "connected" ? "checkmark.circle" : "circle" };
}

const transportLabel = (entry: McpServerSummary): string =>
  entry.transport === "http" ? "HTTP" : entry.transport;

const LIVE_FLOW = new Set([
  "pending",
  "awaiting_external",
  "awaiting_prompt",
  "awaiting_manual_code",
]);
/** The sign-in that still blocks changes, while it is live. */
const liveFlow = (probe: McpProbe): McpAuthFlowSnapshot | undefined => {
  const flow = probe.response?.activeSignIn;
  return flow && LIVE_FLOW.has(flow.status) ? flow : undefined;
};

/** A page whose probe has not answered yet, or failed with the reason under the page's title. */
function pending(title: string, probe: McpProbe, failure: string): ScreenPage {
  if (probe.error)
    return { title, state: { kind: "failed", title: failure, message: probe.error }, sections: [] };
  return { title, state: { kind: "loading", message: "Probing MCP servers…" }, sections: [] };
}

/** A server's row: its transport, tools and exposure, and its status. */
function serverRow(entry: McpServerSummary, id: string, probe: McpProbe, push: boolean): ScreenRow {
  return {
    kind: "item",
    id,
    title: entry.name,
    subtitle: `${transportLabel(entry)} \u00b7 ${entry.tools.length} tools \u00b7 ${exposureOf(entry.exposure).title}`,
    status: status(entry.state, probe.checking),
    ...(push ? { push: `server/${entry.name}` } : {}),
  };
}

/**
 * One scope's servers: the host's sign-in, scope errors, one row per server, a workspace's
 * servers from the global file, and the note.
 */
export function listPage(probe: McpProbe): ScreenPage {
  const title = "MCP Servers";
  const bar = [{ id: "add", title: "Add MCP Server", symbol: "plus", present: "add" }];
  if (!probe.response) return pending(title, probe, "Couldn't Load MCP Servers");
  const scope = probe.response.scope;
  const global = scope.kind === "global";
  const sections: ScreenSection[] = [];
  const flow = liveFlow(probe);
  if (flow)
    sections.push({
      id: "signin",
      header: `Sign-In on ${flow.serverName}`,
      rows: [
        {
          kind: "button",
          id: "signin.continue",
          title: "Continue Sign-In",
          action: "signin.continue",
        },
        {
          kind: "button",
          id: "signin.cancel",
          title: "Cancel Sign-In",
          role: "destructive",
          action: "signin.cancel",
        },
      ],
    });
  const rows: ScreenRow[] = scope.errors.map((error, index) => ({
    kind: "text",
    id: `error.${index}`,
    text: error,
    tone: "danger",
  }));
  if (scope.servers.length === 0)
    rows.push({ kind: "text", id: "empty", text: "No MCP servers configured", tone: "secondary" });
  for (const entry of scope.servers)
    rows.push(serverRow(entry, `server.${entry.name}`, probe, true));
  sections.push({
    id: "servers",
    ...(global ? {} : { header: "This Workspace" }),
    footer: global
      ? "Global servers from ~/.pi/agent/mcp.json load in every host workspace. Each workspace\u2019s own servers are in its Workspace Settings."
      : "Servers from this workspace\u2019s .pi/mcp.json. A server here replaces a global server with the same name.",
    rows,
  });
  const inherited = scope.inherited ?? [];
  if (inherited.length > 0)
    sections.push({
      id: "inherited",
      header: "From Global",
      footer:
        "Global servers that also load in this workspace. Change them from MCP Servers in the sidebar.",
      rows: inherited.map((entry) => serverRow(entry, `inherited.${entry.name}`, probe, false)),
    });
  sections.push({
    id: "note",
    rows: [
      {
        kind: "text",
        id: "note",
        style: "footnote",
        tone: "secondary",
        text: "Refresh probes Pi's configured servers, not running sessions. Configuration changes apply to new sessions or /reload.",
      },
    ],
  });
  return { title, bar, sections };
}

/**
 * One server: where it connects, Enabled and Exposure, sign-in, references, tools, Remove.
 * Its first header names the scope and, from the app, the host.
 */
export function serverPage(probe: McpProbe, name: string): ScreenPage | { gone: true } {
  const response = probe.response;
  if (!response) return pending(name, probe, "Couldn't Load This Server");
  const scope = response.scope;
  const entry = scope.servers.find((server) => server.name === name);
  if (!entry) return { gone: true };
  const locked = response.activeSignIn !== undefined;
  const info: ScreenRow[] = [
    {
      kind: "value",
      id: "status",
      label: "Status",
      value: status(entry.state, probe.checking).text,
    },
    { kind: "value", id: "transport", label: "Transport", value: transportLabel(entry) },
  ];
  if (entry.config.url)
    info.push({ kind: "text", id: "url", text: entry.config.url, selectable: true });
  if (entry.config.command)
    info.push({
      kind: "text",
      id: "command",
      text: [entry.config.command, ...(entry.config.args ?? [])].join(" "),
      mono: true,
      selectable: true,
    });
  if (entry.config.cwd)
    info.push({ kind: "value", id: "cwd", label: "Working Directory", value: entry.config.cwd });
  const sections: ScreenSection[] = [
    { id: "info", header: scope.title, namesHost: true, rows: info },
    {
      id: "config",
      footer:
        "Saved in this scope's mcp.json. New sessions or /reload pick up configuration changes.",
      rows: [
        {
          kind: "toggle",
          id: "enabled",
          label: "Enabled",
          value: entry.enabled,
          action: "enabled",
          disabled: locked,
        },
        {
          kind: "choice",
          id: "exposure",
          label: "Exposure",
          value: entry.exposure,
          options: exposureOptions,
          action: "exposure",
          disabled: locked,
        },
      ],
    },
  ];
  if (entry.supportsOAuth) {
    const flow = liveFlow(probe);
    sections.push({
      id: "oauth",
      header: "OAuth",
      rows:
        flow?.serverName === name
          ? [
              {
                kind: "button",
                id: "signin.continue",
                title: "Continue Sign-In",
                action: "signin.continue",
              },
            ]
          : [
              {
                kind: "button",
                id: "login",
                title: entry.state === "needs-auth" ? "Sign In" : "Sign In Again",
                action: "login",
                disabled: locked,
              },
              {
                kind: "button",
                id: "logout",
                title: "Sign Out",
                role: "destructive",
                action: "logout",
                disabled: locked,
                confirm: {
                  title: `Sign out of ${name}?`,
                  message:
                    "This removes stored OAuth credentials on the host. You will need to sign in again to use this server.",
                  button: "Sign Out",
                },
              },
            ],
    });
  }
  const references = (id: string, header: string, given?: Record<string, string>): void => {
    const values = given ?? {};
    const keys = Object.keys(values).sort();
    if (keys.length > 0)
      sections.push({
        id,
        header,
        rows: keys.map((key) => ({
          kind: "value",
          id: `${id}.${key}`,
          label: key,
          value: values[key] ?? "[redacted]",
          mono: true,
        })),
      });
  };
  references("headers", "Headers", entry.config.headers);
  references("env", "Environment", entry.config.env);
  if (entry.error)
    sections.push({
      id: "connection",
      header: "Connection Error",
      rows: [
        {
          kind: "text",
          id: "connection.error",
          text: entry.error,
          tone: "danger",
          selectable: true,
        },
      ],
    });
  const errors = response.scope.errors;
  if (errors.length > 0)
    sections.push({
      id: "scope-errors",
      rows: errors.map((error, index) => ({
        kind: "text",
        id: `scope-error.${index}`,
        text: error,
        tone: "danger",
      })),
    });
  const tools = [...new Set(entry.tools)];
  sections.push({
    id: "tools",
    header: `Tools (${entry.tools.length})`,
    rows:
      tools.length === 0
        ? [{ kind: "text", id: "tools.none", text: "No tools available", tone: "secondary" }]
        : tools.map((tool) => ({
            kind: "text",
            id: `tool.${tool}`,
            text: tool,
            mono: true,
            selectable: true,
          })),
  });
  sections.push({
    id: "remove",
    rows: [
      {
        kind: "button",
        id: "remove",
        title: "Remove Server",
        role: "destructive",
        action: "remove",
        disabled: locked,
        confirm: {
          title: `Remove ${name} from ${scope.title}?`,
          message:
            "The configuration entry will be removed. Stored OAuth credentials are not deleted; sign out first if needed.",
          button: "Remove Server",
        },
      },
    ],
  });
  return { title: name, sections };
}

const SECRET_REFERENCES =
  // eslint-disable-next-line no-template-curly-in-string -- mcp.json's own ${NAME} reference syntax.
  "Use ${NAME} references instead of literal secrets. For example: API_KEY=${TOOLS_KEY}, or Authorization=Bearer ${TOKEN}. Values are resolved on the host; literal values are redacted when read back.";

const TRUST: Record<ProjectTrustState, string> = {
  trusted: "trusted",
  ask: "asks at session start",
  distrusted: "not trusted",
};

/**
 * The Add form for the probed scope; its header names the host, from the app. Its draft is the
 * app's until Add sends it (`addRequest`); Add stays off until the name and the URL or the
 * command are filled.
 */
export function addPage(probe: McpProbe): ScreenPage {
  if (!probe.response) return pending("Add MCP Server", probe, "Couldn't Load This Scope");
  const scope: Pick<McpScopeSnapshot, "title" | "projectTrust"> = probe.response.scope;
  return {
    title: "Add MCP Server",
    submit: { title: "Add", action: "add", requires: ["name", "url", "command"] },
    sections: [
      {
        id: "configuration",
        header: "Configuration",
        namesHost: true,
        ...(scope.projectTrust
          ? {
              footer: `Saved to this workspace\u2019s .pi/mcp.json. Project trust: ${TRUST[scope.projectTrust]}.`,
            }
          : {}),
        rows: [
          { kind: "field", id: "name", placeholder: "Server name" },
          { kind: "value", id: "scope", label: "Scope", value: scope.title },
          {
            kind: "choice",
            id: "transport",
            label: "Transport",
            value: "http",
            options: [
              { value: "http", title: "HTTP" },
              { value: "stdio", title: "stdio" },
            ],
          },
          {
            kind: "choice",
            id: "exposure",
            label: "Exposure",
            value: "codemode",
            options: exposureOptions,
          },
        ],
      },
      {
        id: "http",
        header: "Streamable HTTP",
        footer: SECRET_REFERENCES,
        when: { field: "transport", is: "http" },
        rows: [
          { kind: "field", id: "url", placeholder: "https://example.com/mcp", input: "url" },
          {
            kind: "field",
            id: "headers",
            placeholder: "Headers: one KEY=VALUE per line",
            input: "multiline",
          },
        ],
      },
      {
        id: "oauth",
        header: "Optional OAuth Client",
        when: { field: "transport", is: "http" },
        rows: [
          { kind: "field", id: "clientId", placeholder: "Client ID" },
          {
            kind: "field",
            id: "clientSecret",
            // eslint-disable-next-line no-template-curly-in-string -- mcp.json's own ${NAME} reference syntax.
            placeholder: "Client secret reference: ${NAME}",
          },
          {
            kind: "field",
            id: "callbackPort",
            placeholder: "Callback port (automatic if empty)",
            input: "number",
          },
        ],
      },
      {
        id: "stdio",
        header: "Standard Input / Output",
        footer: `${SECRET_REFERENCES}\nAdding a command authorizes Pi to run it on the host when the scope is trusted and the server is enabled.`,
        when: { field: "transport", is: "stdio" },
        rows: [
          { kind: "field", id: "command", placeholder: "Executable (not a shell command)" },
          {
            kind: "field",
            id: "arguments",
            placeholder: "Arguments: one per line (no secrets)",
            input: "multiline",
          },
          { kind: "field", id: "cwd", placeholder: "Working directory (optional)" },
          {
            kind: "field",
            id: "environment",
            placeholder: "Environment: one KEY=VALUE per line",
            input: "multiline",
          },
        ],
      },
    ],
  };
}

/** The Add form's draft as the request `McpService.add` takes; throws the words to show. */
export function addRequest(values: readonly ScreenValue[] | undefined): McpAddServerRequest {
  const draft = new Map((values ?? []).map(({ field, value }) => [field, String(value)]));
  const text = (field: string): string | undefined => {
    const value = draft.get(field)?.trim();
    return value ? value : undefined;
  };
  const name = text("name");
  if (!name) throw new Error("Enter a server name.");
  const pairs = (field: string): Record<string, string> | undefined => {
    const lines = (draft.get(field) ?? "").split("\n").filter((line) => line.trim());
    if (lines.length === 0) return undefined;
    const result: Record<string, string> = {};
    for (const line of lines) {
      const separator = line.indexOf("=");
      const key = line.slice(0, separator).trim();
      if (separator <= 0) throw new Error("Use KEY=VALUE on each line.");
      if (!key || key in result) throw new Error("Keys must be non-empty and unique.");
      result[key] = line.slice(separator + 1);
    }
    return result;
  };
  const exposure = (text("exposure") ?? "codemode") as McpExposure;
  const request: McpAddServerRequest = {
    name,
    ...(exposure !== "codemode" ? { exposure } : {}),
  };
  if ((text("transport") ?? "http") === "http") {
    const url = text("url");
    if (!url) throw new Error("Enter the server's URL.");
    const port = text("callbackPort");
    const callbackPort = port === undefined ? undefined : Number(port);
    if (
      callbackPort !== undefined &&
      (!Number.isInteger(callbackPort) || callbackPort < 1 || callbackPort > 65535)
    )
      throw new Error("Enter a callback port between 1 and 65535.");
    const oauth = {
      ...(text("clientId") ? { clientId: text("clientId") } : {}),
      ...(text("clientSecret") ? { clientSecret: text("clientSecret") } : {}),
      ...(callbackPort !== undefined ? { callbackPort } : {}),
    };
    const headers = pairs("headers");
    return {
      ...request,
      url,
      ...(headers ? { headers } : {}),
      ...(Object.keys(oauth).length > 0 ? { oauth } : {}),
    };
  }
  const command = text("command");
  if (!command) throw new Error("Enter the command to run.");
  const args = (draft.get("arguments") ?? "").split("\n").filter((line) => line.length > 0);
  const env = pairs("environment");
  return {
    ...request,
    command,
    ...(args.length > 0 ? { args } : {}),
    ...(text("cwd") ? { cwd: text("cwd") } : {}),
    ...(env ? { env } : {}),
  };
}

const FLOW_STATUS: Record<string, string> = {
  pending: "Starting…",
  awaiting_external: "Waiting for approval",
  awaiting_prompt: "Waiting for approval",
  awaiting_manual_code: "Waiting for the callback URL",
  completed: "Signed in",
  failed: "Failed",
  cancelled: "Cancelled",
  expired: "Expired",
};

/** The host's sign-in: its state, the sign-in link, and the callback URL to paste. */
export function signInPage(flow: McpAuthFlowSnapshot | undefined): ScreenPage {
  const title = "Sign In";
  if (!flow)
    return {
      title,
      state: { kind: "empty", title: "No Sign-In", message: "No MCP sign-in is in progress." },
      sections: [],
    };
  const live = LIVE_FLOW.has(flow.status);
  const sections: ScreenSection[] = [
    {
      id: "summary",
      header: flow.serverName,
      rows: [
        {
          kind: "value",
          id: "status",
          label: "Status",
          value: FLOW_STATUS[flow.status] ?? flow.status,
        },
      ],
    },
  ];
  if (live && flow.auth)
    sections.push({
      id: "signin",
      header: "Sign In",
      footer:
        "After approval, the browser may fail to load 127.0.0.1. Copy its full callback URL and paste it below. You can also complete sign-in using a browser on the host.",
      rows: [
        { kind: "button", id: "open", title: "Open Sign-In Page", url: flow.auth.url },
        { kind: "field", id: "callback", placeholder: "Paste the full callback URL", input: "url" },
      ],
    });
  else if (live)
    sections.push({
      id: "preparing",
      rows: [
        { kind: "text", id: "preparing", text: "Preparing the sign-in page…", tone: "secondary" },
      ],
    });
  if (flow.error)
    sections.push({
      id: "error",
      rows: [{ kind: "text", id: "error", text: flow.error, tone: "danger" }],
    });
  if (live)
    sections.push({
      id: "cancel",
      rows: [
        {
          kind: "button",
          id: "cancel",
          title: "Cancel Sign-In",
          role: "destructive",
          action: "signin.cancel",
        },
      ],
    });
  return {
    title,
    sections,
    ...(live && flow.auth ? { submit: { title: "Submit", action: "callback" } } : {}),
  };
}
