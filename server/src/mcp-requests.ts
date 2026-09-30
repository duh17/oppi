import type { McpAddServerRequest, McpExposure, McpPatchServerRequest } from "./types/mcp.js";
import type { ProviderAuthLaunchMode } from "./provider-auth/types.js";
import { isRecord, McpError, MCP_EXPOSURES } from "./mcp-config.js";

function object(value: unknown, allowed: string[]): Record<string, unknown> {
  if (!isRecord(value)) throw new McpError(400, "Expected a JSON object");
  if (Object.keys(value).some((key) => !allowed.includes(key)))
    throw new McpError(400, "Unexpected request field");
  return value;
}
function optionalStrings(body: Record<string, unknown>, keys: string[]): void {
  for (const key of keys) {
    if (body[key] !== undefined && typeof body[key] !== "string")
      throw new McpError(400, `${key} must be a string`);
  }
}
function exposure(value: unknown): void {
  if (
    value !== undefined &&
    (typeof value !== "string" || !MCP_EXPOSURES.includes(value as McpExposure))
  )
    throw new McpError(400, "Invalid exposure");
}
export function parseMcpAddRequest(value: unknown): McpAddServerRequest {
  const body = object(value, [
    "scopeId",
    "name",
    "url",
    "command",
    "args",
    "cwd",
    "env",
    "headers",
    "oauth",
    "exposure",
  ]);
  if (
    typeof body.scopeId !== "string" ||
    !body.scopeId ||
    typeof body.name !== "string" ||
    !body.name
  )
    throw new McpError(400, "scopeId and name must be non-empty strings");
  optionalStrings(body, ["url", "command", "cwd"]);
  if ((body.url === undefined) === (body.command === undefined))
    throw new McpError(400, "Choose a URL or command");
  if (
    body.args !== undefined &&
    (!Array.isArray(body.args) || body.args.some((arg) => typeof arg !== "string"))
  )
    throw new McpError(400, "args must be an array of strings");
  for (const key of ["env", "headers"]) {
    const values = body[key];
    if (
      values !== undefined &&
      (!isRecord(values) || Object.values(values).some((item) => typeof item !== "string"))
    )
      throw new McpError(400, `${key} must map names to strings`);
  }
  if (body.oauth !== undefined) {
    const oauth = object(body.oauth, ["clientId", "clientSecret", "callbackPort"]);
    optionalStrings(oauth, ["clientId", "clientSecret"]);
    if (
      oauth.callbackPort !== undefined &&
      (typeof oauth.callbackPort !== "number" ||
        !Number.isInteger(oauth.callbackPort) ||
        oauth.callbackPort < 1 ||
        oauth.callbackPort > 65535)
    )
      throw new McpError(400, "Invalid OAuth callback port");
  }
  exposure(body.exposure);
  return body as unknown as McpAddServerRequest;
}
export function parseMcpPatchRequest(value: unknown): McpPatchServerRequest {
  const body = object(value, ["enabled", "exposure"]);
  if (!Object.keys(body).length) throw new McpError(400, "Specify enabled or exposure");
  if (body.enabled !== undefined && typeof body.enabled !== "boolean")
    throw new McpError(400, "enabled must be a boolean");
  exposure(body.exposure);
  return body as McpPatchServerRequest;
}
export function parseMcpLoginRequest(value: unknown): ProviderAuthLaunchMode {
  const body = object(value, ["launchMode"]);
  if (body.launchMode === undefined) return "phone_browser";
  if (
    typeof body.launchMode !== "string" ||
    !["phone_browser", "server_browser", "none"].includes(body.launchMode)
  )
    throw new McpError(400, "Invalid launchMode");
  return body.launchMode as ProviderAuthLaunchMode;
}
export function parseMcpManualRequest(value: unknown): string {
  const body = object(value, ["input"]);
  if (typeof body.input !== "string" || !body.input.trim())
    throw new McpError(400, "Paste the full callback URL");
  return body.input;
}
export function parseMcpEmptyRequest(value: unknown): void {
  object(value, []);
}
