import { existsSync, readFileSync, writeFileSync } from "node:fs";
import type { McpPatchServerRequest, McpServerConfig } from "./types/mcp.js";

export class McpError extends Error {
  constructor(
    readonly statusCode: number,
    message: string,
  ) {
    super(message);
  }
}
export const MCP_EXPOSURES = ["codemode", "deferred", "direct", "hidden"] as const;
export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
export function readMcpDocument(path: string): Record<string, unknown> {
  if (!existsSync(path)) return {};
  let document: unknown;
  try {
    document = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    throw new McpError(422, "mcp.json is not valid JSON. Fix it on the host before editing.");
  }
  if (
    !isRecord(document) ||
    (document.mcpServers !== undefined && !isRecord(document.mcpServers))
  ) {
    throw new McpError(422, 'mcp.json must contain an object with an "mcpServers" object.');
  }
  return document;
}
/** Match Pi updateMcpServerConfig: preserve unrelated content/indentation, delete defaults. */
export function patchMcpConfig(path: string, name: string, patch: McpPatchServerRequest): void {
  const text = existsSync(path) ? readFileSync(path, "utf8") : "";
  const document = readMcpDocument(path);
  const server = isRecord(document.mcpServers) ? document.mcpServers[name] : undefined;
  if (!isRecord(server)) throw new McpError(404, "MCP server not found in this scope");
  if (patch.enabled !== undefined) {
    if (patch.enabled) delete server.enabled;
    else server.enabled = false;
  }
  if (patch.exposure !== undefined) {
    if (patch.exposure === "codemode") delete server.exposure;
    else server.exposure = patch.exposure;
  }
  const indent = /^([ \t]+)\S/m.exec(text)?.[1] || "  ";
  writeFileSync(path, `${JSON.stringify(document, null, indent)}\n`);
}
/** Only whole command references or values made exclusively of variable references and
 * non-secret header syntax pass through. Mixed literal secrets fail closed. */
export function redactMcpValue(value: string): string {
  if (value.startsWith("!") && value.length > 1) return value;
  if (/^(?:Bearer |Basic )?\$\{[A-Za-z_][A-Za-z0-9_]*\}$/.test(value)) return value;
  return "[redacted]";
}
function stringMap(value: unknown): Record<string, string> | undefined {
  if (!isRecord(value)) return undefined;
  return Object.fromEntries(
    Object.entries(value).map(([key, item]) => [
      key,
      typeof item === "string" ? redactMcpValue(item) : "[redacted]",
    ]),
  );
}
function safeMcpUrl(value: string): string {
  try {
    const url = new URL(value);
    url.username = "";
    url.password = "";
    url.hash = "";
    url.search = new URLSearchParams(
      [...url.searchParams.keys()].map((key) => [key, "[redacted]"]),
    ).toString();
    return url.href;
  } catch {
    return "[invalid URL]";
  }
}
export function safeMcpConfig(value: Record<string, unknown>): McpServerConfig {
  const oauth = isRecord(value.oauth) ? value.oauth : undefined;
  return {
    ...(typeof value.url === "string" ? { url: safeMcpUrl(value.url) } : {}),
    ...(typeof value.command === "string" ? { command: value.command } : {}),
    ...(Array.isArray(value.args)
      ? { args: value.args.filter((arg): arg is string => typeof arg === "string") }
      : {}),
    ...(typeof value.cwd === "string" ? { cwd: value.cwd } : {}),
    ...(value.env === undefined ? {} : { env: stringMap(value.env) }),
    ...(value.headers === undefined ? {} : { headers: stringMap(value.headers) }),
    ...(oauth
      ? {
          oauth: {
            ...(typeof oauth.clientId === "string" ? { clientId: oauth.clientId } : {}),
            ...(typeof oauth.clientSecret === "string"
              ? { clientSecret: redactMcpValue(oauth.clientSecret) }
              : {}),
            ...(typeof oauth.callbackPort === "number" ? { callbackPort: oauth.callbackPort } : {}),
          },
        }
      : {}),
  };
}
/** Subprocess diagnostics can repeat configured secrets. Never send syntax-error excerpts. */
export function redactMcpDiagnostic(text: string, documents: Record<string, unknown>[]): string {
  const secrets = new Set<string>();
  for (const document of documents) {
    const servers = isRecord(document.mcpServers) ? document.mcpServers : {};
    for (const server of Object.values(servers)) {
      if (!isRecord(server)) continue;
      const maps = [
        server.env,
        server.headers,
        isRecord(server.oauth) ? { secret: server.oauth.clientSecret } : {},
      ];
      for (const map of maps) {
        if (!isRecord(map)) continue;
        for (const value of Object.values(map)) {
          if (typeof value === "string" && value && redactMcpValue(value) === "[redacted]")
            secrets.add(value);
        }
      }
    }
  }
  let safe = text;
  for (const secret of [...secrets].sort((a, b) => b.length - a.length))
    safe = safe.split(secret).join("[redacted]");
  // Provider diagnostics must not leak callback codes or OAuth query parameters.
  return safe.replace(/https?:\/\/[^\s]+/g, (value) => {
    try {
      const url = new URL(value);
      url.search = "";
      url.hash = "";
      url.username = "";
      url.password = "";
      return url.href;
    } catch {
      return "[URL]";
    }
  });
}
