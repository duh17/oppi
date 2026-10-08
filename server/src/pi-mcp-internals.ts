/**
 * Pi's MCP building blocks that are not package exports: config loading, transports,
 * connections, credentials, tool/resource definitions, and tool search. Load them from
 * Pi's installed dist (as `pi-global-config.ts` and `mcp-cli.ts` do) so validation, the
 * HTTP/OAuth transport, result conversion, and naming stay Pi's, not a second copy. Same
 * file URLs as Pi's lazy loader, so the module instances (and their error classes) are shared.
 */
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
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

/** Pi's `{ entry, connection }` shape that `renderServersSection` reads. */
export interface McpServerListing {
  entry: McpServerEntry;
  connection?: McpServerConnection;
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
  const dist = dirname(fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent")));
  const load = (path: string): Promise<Record<string, unknown>> =>
    import(pathToFileURL(join(dist, path)).href) as Promise<Record<string, unknown>>;
  const [config, runtime, tools, resources, mcp, servers, search] = await Promise.all([
    load("extensions/mcp/config.js"),
    load("extensions/mcp/runtime.js"),
    load("extensions/mcp/tools.js"),
    load("extensions/mcp/resources.js"),
    load("extensions/mcp/index.js"),
    load("core/mcp-servers.js"),
    load("extensions/tool-search/tool.js"),
  ]);
  const internals = {
    loadMcpConfig: config.loadMcpConfig,
    createDefaultTransport: runtime.createDefaultTransport,
    McpServerConnection: runtime.McpServerConnection,
    McpOAuthCredentialStore: runtime.McpOAuthCredentialStore,
    McpServerLog: runtime.McpServerLog,
    getMcpToolExposure: config.getMcpToolExposure,
    createMcpToolName: tools.createMcpToolName,
    createMcpToolDefinition: tools.createMcpToolDefinition,
    createMcpResourceToolDefinitions: resources.createMcpResourceToolDefinitions,
    renderServersSection: mcp.renderServersSection,
    mcpNamespace: servers.mcpNamespace,
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
  const missing = Object.entries(internals)
    .filter(
      ([, value]) => value === undefined || (Array.isArray(value) && value.includes(undefined)),
    )
    .map(([name]) => name);
  if (missing.length)
    throw new Error(`Pi's MCP modules moved (${missing.join(", ")}); update pi-mcp-internals.ts`);
  return internals as unknown as PiMcpInternals;
}
