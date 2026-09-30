import type { ProviderAuthFlowStatus, ProviderAuthLaunchMode } from "../provider-auth/types.js";

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
  hasConfig: boolean;
  trusted: boolean;
  servers: McpServerSummary[];
  errors: string[];
  note?: string;
}
export interface McpServersResponse {
  scopes: McpScopeSnapshot[];
  /** The sign-in that still blocks MCP mutations (live, or terminal with its child not yet
   * reaped). While present, scopes are the last live probe, not a fresh one, so a phone that
   * opened this view mid-flow can resume or cancel it. Absent once the host is idle. */
  activeSignIn?: McpAuthFlowSnapshot;
}
export interface McpAddServerRequest extends McpServerConfig {
  scopeId: string;
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
