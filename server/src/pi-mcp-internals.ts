/**
 * Pi's MCP building blocks that are not package exports: config loading, transports,
 * connections, credentials, tool/resource definitions, and tool search. Load them from
 * Pi's installed dist (`pi-private.ts`) so validation, the HTTP/OAuth transport, result
 * conversion, and naming stay Pi's, not a second copy. Same file URLs as Pi's lazy loader, so
 * the module instances (and their error classes) are shared.
 */
import { importPiDist } from "./pi-private.js";
import type {
  LoadedMcpConfig,
  McpExposure,
  McpServerConfig,
  McpServerEntry,
  McpTransportFactory,
  ToolDefinition,
} from "@earendil-works/pi-coding-agent";

/** The fields of an MCP `Tool` Oppi reads. */
export interface McpTool {
  name: string;
  description?: string;
  inputSchema: Record<string, unknown>;
  annotations?: { readOnlyHint?: boolean; idempotentHint?: boolean };
}

type McpServerState =
  "connecting" | "connected" | "disconnected" | "needs-auth" | "failed" | "closed";

/** Pi's `McpServerConnection`: one configured server, reconnecting lazily. */
export interface McpServerConnection {
  readonly entry: McpServerEntry;
  readonly name: string;
  readonly state: McpServerState;
  readonly error: string | undefined;
  readonly tools: McpTool[];
  readonly hasResources: boolean;
  readonly instructions: string | undefined;
  readonly timeoutMs: number;
  readonly oauthUrl: string | undefined;
  getClient(): Promise<unknown>;
  reconnect(): Promise<void>;
  close(): Promise<void>;
}

export interface McpOAuthCredentialStore {
  tokens(name: string, serverUrl: string): unknown;
}

type McpServerLog = object;

/** Pi's `{ entry, connection }` shape; `renderServersSection` reads only the connection's instructions. */
export interface McpServerListing {
  entry: McpServerEntry;
  connection?: Pick<McpServerConnection, "instructions">;
}

export interface ToolSearchDocument {
  name: string;
  text: string;
}

export interface PiMcpInternals {
  loadMcpConfig: (options: {
    agentDir: string;
    cwd: string;
    projectTrusted: boolean;
  }) => LoadedMcpConfig;
  createDefaultTransport: McpTransportFactory;
  McpServerConnection: new (options: {
    entry: McpServerEntry;
    cwd: string;
    createTransport: McpTransportFactory;
    credentials: McpOAuthCredentialStore;
    providerToken?: (provider: string) => Promise<string | undefined>;
    onTools: (connection: McpServerConnection) => void;
    onChange?: (connection: McpServerConnection) => void;
    log?: McpServerLog;
  }) => McpServerConnection;
  McpOAuthCredentialStore: new () => McpOAuthCredentialStore;
  McpServerLog: new (path: string) => McpServerLog;
  getMcpToolExposure: (config: McpServerConfig, tool: string) => McpExposure;
  createMcpToolName: (server: string, tool: string, isTaken?: (name: string) => boolean) => string;
  createMcpToolDefinition: (options: {
    server: string;
    tool: McpTool;
    name: string;
    exposure: McpExposure;
    namespace: { name: string; description?: string; instructions?: string };
    timeoutMs: number;
    getClient: () => Promise<McpServerConnection>;
    readableResources?: () => boolean;
  }) => ToolDefinition;
  createMcpResourceToolDefinitions: (options: {
    exposure: McpExposure;
    servers: () => readonly McpServerConnection[];
  }) => ToolDefinition[];
  renderServersSection: (servers: readonly McpServerListing[]) => string | undefined;
  mcpNamespace: (server: string) => string;
  /** `--tools` / `--exclude-tools` matching: exact names, and patterns where `*` matches anything. */
  createToolNameMatcher: (entries: readonly string[]) => (name: string) => boolean;
  /** A server tool (`mcp__<server>__<tool>`) or one of the MCP resource tools. */
  isMcpToolName: (name: string) => boolean;
  createToolSearchDocument: (
    tool: { name: string; description: string; parameters: unknown },
    namespace?: { name: string; description?: string; instructions?: string },
  ) => ToolSearchDocument;
  Bm25Ranker: new () => {
    rank(
      query: string,
      documents: readonly ToolSearchDocument[],
      limit: number,
    ): { name: string; score: number }[];
  };
  TOOL_SEARCH_DESCRIPTION: string;
  DEFAULT_TOOL_SEARCH_LIMIT: number;
  /** `list_mcp_resources`, `list_mcp_resource_templates`, `read_mcp_resource`. */
  MCP_RESOURCE_TOOL_NAMES: readonly string[];
}

let loading: Promise<PiMcpInternals> | undefined;

export function loadPiMcpInternals(): Promise<PiMcpInternals> {
  return (loading ??= loadInternals().catch((error: unknown) => {
    loading = undefined;
    throw error;
  }));
}

async function loadInternals(): Promise<PiMcpInternals> {
  // Tool naming moved to Pi's `@earendil-works/pi-mcp` package in 1.5.1.
  const [config, runtime, tools, resources, mcp, servers, search, naming] = await Promise.all([
    importPiDist("extensions/mcp/config.js", ["loadMcpConfig", "getMcpToolExposure"]),
    importPiDist("extensions/mcp/runtime.js", [
      "createDefaultTransport",
      "McpServerConnection",
      "McpOAuthCredentialStore",
      "McpServerLog",
    ]),
    importPiDist("extensions/mcp/tools.js", ["createMcpToolDefinition"]),
    importPiDist("extensions/mcp/resources.js", [
      "createMcpResourceToolDefinitions",
      "LIST_MCP_RESOURCES_TOOL",
      "LIST_MCP_RESOURCE_TEMPLATES_TOOL",
      "READ_MCP_RESOURCE_TOOL",
    ]),
    importPiDist("extensions/mcp/index.js", ["renderServersSection"]),
    importPiDist("core/mcp-servers.js", ["createToolNameMatcher", "isMcpToolName"]),
    importPiDist("extensions/tool-search/tool.js", [
      "createToolSearchDocument",
      "Bm25Ranker",
      "TOOL_SEARCH_DESCRIPTION",
      "DEFAULT_TOOL_SEARCH_LIMIT",
    ]),
    import("@earendil-works/pi-mcp") as Promise<Record<string, unknown>>,
  ]);
  const internals = {
    loadMcpConfig: config.loadMcpConfig,
    createDefaultTransport: runtime.createDefaultTransport,
    McpServerConnection: runtime.McpServerConnection,
    McpOAuthCredentialStore: runtime.McpOAuthCredentialStore,
    McpServerLog: runtime.McpServerLog,
    getMcpToolExposure: config.getMcpToolExposure,
    createMcpToolName: naming.createMcpToolName,
    createMcpToolDefinition: tools.createMcpToolDefinition,
    createMcpResourceToolDefinitions: resources.createMcpResourceToolDefinitions,
    renderServersSection: mcp.renderServersSection,
    mcpNamespace: naming.mcpNamespace,
    createToolNameMatcher: servers.createToolNameMatcher,
    isMcpToolName: servers.isMcpToolName,
    createToolSearchDocument: search.createToolSearchDocument,
    Bm25Ranker: search.Bm25Ranker,
    TOOL_SEARCH_DESCRIPTION: search.TOOL_SEARCH_DESCRIPTION,
    DEFAULT_TOOL_SEARCH_LIMIT: search.DEFAULT_TOOL_SEARCH_LIMIT,
    MCP_RESOURCE_TOOL_NAMES: [
      resources.LIST_MCP_RESOURCES_TOOL,
      resources.LIST_MCP_RESOURCE_TEMPLATES_TOOL,
      resources.READ_MCP_RESOURCE_TOOL,
    ],
  };
  if (naming.createMcpToolName === undefined || naming.mcpNamespace === undefined)
    throw new Error("@earendil-works/pi-mcp no longer exports its tool naming");
  return internals as unknown as PiMcpInternals;
}
