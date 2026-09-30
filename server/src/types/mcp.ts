import type { ProviderAuthFlowStatus, ProviderAuthLaunchMode } from "../provider-auth/types.js";
import type { ProjectTrustState } from "./workspace.js";

export type McpExposure = "codemode" | "codemode-deferred" | "deferred" | "direct" | "hidden";
export interface McpServerConfig {
  url?: string;
  command?: string;
  args?: string[];
  cwd?: string;
  env?: Record<string, string>;
  headers?: Record<string, string>;
  oauth?: { clientId?: string; clientSecret?: string; callbackPort?: number };
}
export interface McpServerSummary {
  name: string;
  transport: "http" | "stdio";
  config: McpServerConfig;
  enabled: boolean;
  exposure: McpExposure;
  state: string;
  tools: string[];
  toolExposure?: Record<string, McpExposure>;
  error?: string;
  supportsOAuth: boolean;
}
export interface McpScopeSnapshot {
  /** global, or the owning workspace id. Never a client-provided filesystem path. */
  id: string;
  title: string;
  kind: "global" | "project";
  /** Project scopes only: the trust answer Workspace settings show for all project resources. */
  projectTrust?: ProjectTrustState;
  /** This scope's own mcp.json. In an untrusted project, enabled rows are `untrusted`. */
  servers: McpServerSummary[];
  /** Project scopes only: global servers that also load here, read-only. A global server
   * that a same-name project server replaces has state `replaced`. */
  inherited?: McpServerSummary[];
  errors: string[];
}
export interface McpServersResponse {
  scope: McpScopeSnapshot;
  /** The host-wide sign-in that still blocks MCP mutations (live, or terminal with its child
   * not yet reaped), in any scope. While present, `scope` is the last live probe, not a fresh
   * one, so a phone that opened this view mid-flow can resume or cancel it. Absent once the
   * host is idle. */
  activeSignIn?: McpAuthFlowSnapshot;
}
/** Body of POST /mcp/scopes/{scopeId}/servers. */
export interface McpAddServerRequest extends McpServerConfig {
  name: string;
  exposure?: McpExposure;
}
export interface McpPatchServerRequest {
  enabled?: boolean;
  exposure?: McpExposure;
}
export interface McpAuthFlowSnapshot {
  flowId: string;
  scopeId: string;
  serverName: string;
  launchMode: ProviderAuthLaunchMode;
  status: ProviderAuthFlowStatus;
  auth?: { url: string; instructions?: string };
  error?: string;
  createdAt: number;
  updatedAt: number;
  expiresAt: number;
}
