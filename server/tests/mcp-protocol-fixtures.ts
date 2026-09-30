import { fileURLToPath } from "node:url";
import type { McpAuthFlowSnapshot, McpScopeSnapshot, McpServersResponse } from "../src/types.js";

export const MCP_HTTP_SNAPSHOT_FILE = fileURLToPath(
  new URL("../../protocol/mcp-http.json", import.meta.url),
);
export function buildMcpHttpFixture(): {
  /** One list per scope: global, then projects in each trust state. */
  catalogs: McpServersResponse[];
  /** The list served while a sign-in is live: last snapshot plus the flow to resume. */
  signInCatalog: McpServersResponse;
  flows: McpAuthFlowSnapshot[];
} {
  const fixture: { scopes: McpScopeSnapshot[]; flows: McpAuthFlowSnapshot[] } = {
    scopes: [
      {
        id: "global",
        title: "Global",
        kind: "global",
        errors: [],
        servers: [
          {
            name: "echo",
            transport: "stdio",
            config: {
              command: "node",
              args: ["echo.cjs"],
              cwd: "/tmp/project",
              env: { KEY: "[redacted]", REF: "${TOKEN}" },
            },
            enabled: true,
            exposure: "codemode",
            state: "connected",
            tools: ["echo"],
            toolExposure: { echo: "direct" },
            supportsOAuth: false,
          },
          {
            name: "remote",
            transport: "http",
            config: {
              url: "https://example.test/mcp",
              headers: { "X-Key": "[redacted]", "X-Reference": "!get-key" },
              oauth: { clientId: "client", clientSecret: "[redacted]", callbackPort: 8765 },
            },
            enabled: true,
            exposure: "codemode-deferred",
            state: "needs-auth",
            tools: [],
            error: "Sign-in required",
            supportsOAuth: true,
          },
          {
            name: "failed",
            transport: "stdio",
            config: { command: "missing-command" },
            enabled: true,
            exposure: "deferred",
            state: "failed",
            tools: [],
            error: "Could not start command",
            supportsOAuth: false,
          },
          {
            name: "disabled",
            transport: "http",
            config: { url: "https://example.test/disabled" },
            enabled: false,
            exposure: "hidden",
            state: "disabled",
            tools: [],
            supportsOAuth: true,
          },
        ],
      },
      {
        id: "workspace-one",
        title: "Project One",
        kind: "project",
        projectTrust: "ask",
        errors: ["Invalid MCP entry"],
        servers: [
          {
            name: "project",
            transport: "stdio",
            config: { command: "echo" },
            enabled: true,
            exposure: "direct",
            state: "untrusted",
            tools: [],
            supportsOAuth: false,
          },
        ],
        inherited: [
          {
            name: "echo",
            transport: "stdio",
            config: { command: "node", args: ["echo.cjs"] },
            enabled: true,
            exposure: "codemode",
            state: "connected",
            tools: ["echo"],
            supportsOAuth: false,
          },
        ],
      },
      {
        id: "workspace-trusted",
        title: "Project Trusted",
        kind: "project",
        projectTrust: "trusted",
        errors: [],
        servers: [
          {
            name: "echo",
            transport: "stdio",
            config: { command: "node", args: ["project-echo.cjs"] },
            enabled: true,
            exposure: "codemode",
            state: "connected",
            tools: ["echo"],
            supportsOAuth: false,
          },
        ],
        inherited: [
          {
            name: "echo",
            transport: "stdio",
            config: { command: "node", args: ["echo.cjs"] },
            enabled: true,
            exposure: "codemode",
            state: "replaced",
            tools: [],
            supportsOAuth: false,
          },
        ],
      },
      {
        id: "workspace-distrusted",
        title: "Project Distrusted",
        kind: "project",
        projectTrust: "distrusted",
        errors: [],
        servers: [],
        inherited: [],
      },
    ],
    flows: (
      ["pending", "awaiting_external", "completed", "failed", "cancelled", "expired"] as const
    ).map(
      (status): McpAuthFlowSnapshot => ({
        flowId: `flow-${status}`,
        scopeId: "global",
        serverName: "remote",
        launchMode: "phone_browser",
        status,
        ...(status === "awaiting_external"
          ? {
              auth: {
                url: "https://auth.example/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A8765%2Fcallback&state=fixture",
                instructions: "Paste the complete callback URL.",
              },
            }
          : {}),
        ...(["failed", "cancelled", "expired"].includes(status)
          ? { error: "Sign-in did not finish" }
          : {}),
        createdAt: 1739750400000,
        updatedAt: 1739750401000,
        expiresAt: 1739750700000,
      }),
    ),
  };
  return {
    catalogs: fixture.scopes.map((scope) => ({ scope })),
    signInCatalog: { scope: fixture.scopes[0], activeSignIn: fixture.flows[1] },
    flows: fixture.flows,
  };
}
export function serializeMcpHttpFixture(): string {
  return JSON.stringify(buildMcpHttpFixture(), null, 2) + "\n";
}
