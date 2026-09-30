import { createServer, type Server } from "node:http";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
  existsSync,
  realpathSync,
} from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { once } from "node:events";
import { afterEach, describe, expect, it, vi } from "vitest";
import { McpCli } from "../src/mcp-cli.js";
import { McpService } from "../src/mcp-service.js";
import { RouteHandler, type RouteContext } from "../src/routes/index.js";
import { validateMcpCallback } from "../src/mcp-auth.js";
import {
  patchMcpConfig,
  redactMcpValue,
  redactMcpDiagnostic,
  safeMcpConfig,
} from "../src/mcp-config.js";
import type { McpAuthFlowSnapshot, McpServersResponse, Workspace } from "../src/types.js";

const echo = resolve("tests/fixtures/mcp-echo.cjs");
const services: McpService[] = [];
const servers: Server[] = [];
afterEach(async () => {
  await Promise.all(services.splice(0).map((service) => service.dispose()));
  await Promise.all(
    servers.splice(0).map(
      (server) =>
        new Promise<void>((done) => {
          server.closeAllConnections();
          server.close(() => done());
        }),
    ),
  );
});
function fixture(ttl?: number) {
  const dir = mkdtempSync(join(tmpdir(), "oppi-mcp-proof-"));
  const agentDir = join(dir, "agent");
  const project = join(dir, "project");
  mkdirSync(agentDir);
  mkdirSync(join(project, ".pi"), { recursive: true });
  const workspace = {
    id: "workspace-one",
    name: "Project One",
    runtime: "host",
    hostMount: project,
  } as Workspace;
  const service = new McpService({
    agentDir,
    listWorkspaces: () => [workspace, { ...workspace, id: "sandbox", runtime: "sandbox" }],
    loginTtlMs: ttl,
  });
  services.push(service);
  return { dir, agentDir, project, workspace, service };
}
async function listen(server: Server): Promise<string> {
  servers.push(server);
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("No port");
  return `http://127.0.0.1:${address.port}`;
}
async function routes(service: McpService) {
  const handler = new RouteHandler({ mcp: service } as RouteContext);
  return listen(
    createServer((req, res) => {
      const url = new URL(req.url!, "http://127.0.0.1");
      void handler.dispatch(req.method!, url.pathname, url, req, res).catch(() => {
        res.writeHead(500);
        res.end("Route failed");
      });
    }),
  );
}
async function api<T>(base: string, path: string, method = "GET", body?: unknown): Promise<T> {
  const response = await fetch(base + path, {
    method,
    ...(body === undefined
      ? {}
      : { body: JSON.stringify(body), headers: { "Content-Type": "application/json" } }),
  });
  const data = await response.json();
  expect(response.status, JSON.stringify(data)).toBeLessThan(400);
  return data as T;
}
async function oauthServer(): Promise<string> {
  let base = "";
  base = await listen(
    createServer(async (req, res) => {
      const path = new URL(req.url!, base).pathname;
      const chunks: Buffer[] = [];
      for await (const chunk of req) chunks.push(Buffer.from(chunk));
      const raw = Buffer.concat(chunks).toString();
      const json = (value: unknown, status = 200): void => {
        res.writeHead(status, { "Content-Type": "application/json" });
        res.end(JSON.stringify(value));
      };
      if (path.startsWith("/.well-known/oauth-protected-resource"))
        return json({
          resource: base + "/mcp",
          authorization_servers: [base],
          scopes_supported: ["echo"],
        });
      if (
        path.startsWith("/.well-known/oauth-authorization-server") ||
        path.startsWith("/.well-known/openid-configuration")
      )
        return json({
          issuer: base,
          authorization_endpoint: base + "/authorize",
          token_endpoint: base + "/token",
          registration_endpoint: base + "/register",
          response_types_supported: ["code"],
          grant_types_supported: ["authorization_code", "refresh_token"],
          code_challenge_methods_supported: ["S256"],
          token_endpoint_auth_methods_supported: ["none"],
        });
      if (path === "/register")
        return json({ ...JSON.parse(raw), client_id: "fixture-client" }, 201);
      if (path === "/authorize") {
        const auth = new URL(req.url!, base);
        const callback = new URL(auth.searchParams.get("redirect_uri")!);
        callback.searchParams.set("code", "fixture-code");
        callback.searchParams.set("state", auth.searchParams.get("state")!);
        res.writeHead(302, { Location: callback.href });
        res.end();
        return;
      }
      if (path === "/token") {
        const params = new URLSearchParams(raw);
        if (params.get("code") !== "fixture-code") return json({ error: "invalid_grant" }, 400);
        return json({
          access_token: "fixture-token",
          refresh_token: "fixture-refresh",
          token_type: "Bearer",
          expires_in: 3600,
          scope: "echo",
        });
      }
      if (path === "/mcp") {
        if (req.headers.authorization !== "Bearer fixture-token") {
          res.writeHead(401, {
            "WWW-Authenticate": `Bearer resource_metadata="${base}/.well-known/oauth-protected-resource/mcp"`,
          });
          res.end();
          return;
        }
        if (req.method === "DELETE") {
          res.writeHead(200);
          res.end();
          return;
        }
        if (req.method !== "POST") {
          res.writeHead(405);
          res.end();
          return;
        }
        const message = JSON.parse(raw);
        if (message.id === undefined) {
          res.writeHead(202);
          res.end();
          return;
        }
        const result =
          message.method === "initialize"
            ? {
                protocolVersion: "2025-11-25",
                capabilities: { tools: {} },
                serverInfo: { name: "oauth-echo", version: "1.0" },
              }
            : message.method === "tools/list"
              ? { tools: [{ name: "echo", inputSchema: { type: "object" } }] }
              : {};
        return json({ jsonrpc: "2.0", id: message.id, result });
      }
      json({ error: "not found" }, 404);
    }),
  );
  return base;
}

describe("MCP configuration boundary", () => {
  it("bounds mutation CLIs below the phone deadline and rejects waiting behind another mutation", async () => {
    const { service, agentDir } = fixture();
    writeFileSync(
      join(agentDir, "mcp.json"),
      JSON.stringify({ mcpServers: { remote: { url: "https://example.test/mcp" } } }),
    );
    const run = vi.spyOn(McpCli.prototype, "run").mockResolvedValue({ code: 0, stdout: "" });
    try {
      const pending = service.add({ scopeId: "global", name: "new", command: "echo" });
      await expect(service.remove("global", "remote")).rejects.toMatchObject({ statusCode: 409 });
      await pending;
      await service.remove("global", "remote");
      await service.logout("global", "remote");
      expect(run).toHaveBeenCalledTimes(3);
      for (const call of run.mock.calls) expect(call[2]).toEqual({ timeoutMs: 20_000 });
      // Patch is synchronous file editing, not an unbounded CLI.
      await service.patch("global", "remote", { enabled: false });
      expect(run).toHaveBeenCalledTimes(3);
    } finally {
      run.mockRestore();
    }
  });
  it("refuses untrusted project login without probing or running project commands", async () => {
    const { service, project } = fixture();
    writeFileSync(
      join(project, ".pi", "mcp.json"),
      JSON.stringify({ mcpServers: { remote: { url: "https://example.test/mcp" } } }),
    );
    await expect(service.login("workspace-one", "remote", "phone_browser")).rejects.toMatchObject({
      statusCode: 409,
      message: "Trust this project in Pi on the host before signing in to its MCP servers.",
    });
  });
  it("adds the default exposure without storing an explicit codemode field", async () => {
    const { service, agentDir } = fixture();
    await service.add({
      scopeId: "global",
      name: "minimal",
      command: process.execPath,
      args: [echo],
      exposure: "codemode",
    });
    expect(JSON.parse(readFileSync(join(agentDir, "mcp.json"), "utf8")).mcpServers.minimal).toEqual(
      { command: process.execPath, args: [echo] },
    );
  });
  it("redacts URL query values while preserving keys, and overlapping literal secrets longest first", () => {
    const config = safeMcpConfig({
      url: "https://example.test/mcp?token=secret&mode=private&token=other",
    });
    expect(config.url).toBeDefined();
    const url = new URL(config.url ?? "");
    expect([...url.searchParams]).toEqual([
      ["token", "[redacted]"],
      ["mode", "[redacted]"],
      ["token", "[redacted]"],
    ]);
    expect(
      redactMcpDiagnostic("abcdef abc", [
        {
          mcpServers: {
            one: { env: { SHORT: "abc", LONG: "abcdef" } },
          },
        },
      ]),
    ).toBe("[redacted] [redacted]");
  });
  it("preserves indentation, unknown fields, sibling entries, and deletes Pi defaults", () => {
    const { agentDir } = fixture();
    const path = join(agentDir, "mcp.json");
    writeFileSync(
      path,
      JSON.stringify(
        {
          autoEnableCodemode: false,
          custom: { retained: true },
          mcpServers: {
            one: {
              command: "echo",
              enabled: false,
              exposure: "direct",
              toolExposure: { echo: "hidden" },
            },
            two: { url: "https://example.test" },
          },
        },
        null,
        "\t",
      ) + "\n",
    );
    patchMcpConfig(path, "one", { enabled: true, exposure: "codemode" });
    const text = readFileSync(path, "utf8");
    const document = JSON.parse(text);
    expect(text).toContain('\n\t"custom"');
    expect(document).toEqual({
      autoEnableCodemode: false,
      custom: { retained: true },
      mcpServers: {
        one: { command: "echo", toolExposure: { echo: "hidden" } },
        two: { url: "https://example.test" },
      },
    });
    patchMcpConfig(path, "one", { enabled: false, exposure: "hidden" });
    expect(JSON.parse(readFileSync(path, "utf8")).mcpServers.one).toMatchObject({
      enabled: false,
      exposure: "hidden",
    });
  });
  it.each([
    ["literal-key", "[redacted]"],
    ["Bearer literal", "[redacted]"],
    ["${KEY}", "${KEY}"],
    ["Bearer ${TOKEN}", "Bearer ${TOKEN}"],
    ["!get-secret", "!get-secret"],
    ["secret-${NAME}", "[redacted]"],
  ])("redacts %s", (input, expected) => {
    expect(redactMcpValue(input)).toBe(expected);
  });
  it("leaves malformed config untouched and rejects invalid patches/scopes", async () => {
    const { service, agentDir } = fixture();
    const path = join(agentDir, "mcp.json");
    writeFileSync(path, '{"headers": "private-value",');
    await expect(service.patch("global", "echo", { enabled: false })).rejects.toMatchObject({
      statusCode: 422,
    });
    expect(readFileSync(path, "utf8")).toBe('{"headers": "private-value",');
    await expect(
      service.patch("global", "echo", { exposure: "bogus" } as never),
    ).rejects.toMatchObject({ statusCode: 400 });
    await expect(
      service.add({ scopeId: "sandbox", name: "bad", command: "echo" }),
    ).rejects.toMatchObject({ statusCode: 404 });
    const snapshot = await service.list();
    expect(JSON.stringify(snapshot)).not.toContain("private-value");
    expect(snapshot.scopes[0].errors).toHaveLength(1);
  });
});
const authorization =
  "https://auth.example/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A8765%2Fcallback&state=this-flow";
describe("MCP callback boundary", () => {
  it("accepts the matching loopback callback", () => {
    expect(
      validateMcpCallback(authorization, "http://127.0.0.1:8765/callback?code=abc&state=this-flow")
        .pathname,
    ).toBe("/callback");
  });
  it.each([
    "http://localhost:8765/callback",
    "http://127.0.0.1:8766/callback",
    "http://127.0.0.1:8765/other",
    "https://127.0.0.1:8765/callback",
    "http://evil.example:8765/callback",
    "http://127.0.0.1:8765/callback#fragment",
    "http://user:pass@127.0.0.1:8765/callback",
  ])("rejects %s", (url) => {
    const value = new URL(url);
    value.search = "code=abc&state=this-flow";
    expect(() => validateMcpCallback(authorization, value.href)).toThrow();
  });
  it("rejects missing/wrong state and non-loopback advertised redirects", () => {
    expect(() =>
      validateMcpCallback(authorization, "http://127.0.0.1:8765/callback?code=abc&state=other"),
    ).toThrow();
    expect(() =>
      validateMcpCallback(authorization, "http://127.0.0.1:8765/callback?code=abc"),
    ).toThrow();
    expect(() =>
      validateMcpCallback(
        "https://auth.example/?redirect_uri=http://evil.example/callback&state=this-flow",
        "http://evil.example/callback?code=abc&state=this-flow",
      ),
    ).toThrow();
  });
});

describe("MCP routes through real bundled Pi", () => {
  it("signs in one trusted project OAuth server without starting a hanging sibling", async () => {
    const { service, agentDir, project } = fixture();
    const remote = await oauthServer();
    const pidFile = join(agentDir, "sibling.pid");
    writeFileSync(join(agentDir, "trust.json"), JSON.stringify({ [realpathSync(project)]: true }));
    writeFileSync(
      join(project, ".pi", "mcp.json"),
      JSON.stringify({
        mcpServers: {
          remote: { url: remote + "/mcp" },
          hang: {
            command: process.execPath,
            args: [resolve("tests/fixtures/mcp-hang.cjs"), pidFile, "ignore-term"],
          },
        },
      }),
    );
    try {
      const flow = await service.login("workspace-one", "remote", "phone_browser");
      expect(existsSync(pidFile)).toBe(false);
      await expect
        .poll(() => service.auth.get(flow.flowId).status, { timeout: 10_000 })
        .toBe("awaiting_external");
      const approval = await fetch(service.auth.get(flow.flowId).auth!.url, { redirect: "manual" });
      await service.auth.submit(flow.flowId, approval.headers.get("location")!);
      await expect
        .poll(() => service.auth.get(flow.flowId).status, { timeout: 10_000 })
        .toBe("completed");
      expect(existsSync(pidFile)).toBe(false);
    } finally {
      if (existsSync(pidFile)) {
        try {
          process.kill(Number(readFileSync(pidFile, "utf8")), "SIGKILL");
        } catch {
          /* stopped */
        }
      }
    }
  }, 30_000);
  it("disposes an in-flight list and immediately kills its EOF/TERM-ignoring stdio server", async () => {
    const { service, agentDir } = fixture();
    const pidFile = join(agentDir, "list.pid");
    writeFileSync(
      join(agentDir, "mcp.json"),
      JSON.stringify({
        mcpServers: {
          hang: {
            command: process.execPath,
            args: [resolve("tests/fixtures/mcp-hang.cjs"), pidFile, "ignore-term"],
          },
        },
      }),
    );
    const flight = service.list();
    let pid: number | undefined;
    const alive = (): boolean => {
      if (!pid) return false;
      try {
        process.kill(pid, 0);
        return true;
      } catch {
        return false;
      }
    };
    try {
      await expect.poll(() => existsSync(pidFile), { timeout: 5000 }).toBe(true);
      pid = Number(readFileSync(pidFile, "utf8"));
      expect(alive()).toBe(true);
      const start = performance.now();
      await service.dispose();
      expect(performance.now() - start).toBeLessThan(1500);
      await expect.poll(alive, { timeout: 2000 }).toBe(false);
      await expect(
        service.add({ scopeId: "global", name: "late", command: "echo" }),
      ).rejects.toMatchObject({ statusCode: 503 });
    } finally {
      if (pid && alive()) process.kill(pid, "SIGKILL");
      await flight.catch(() => {});
    }
  }, 30_000);
  it("returns healthy trusted scopes when another startup hangs, within the phone deadline", async () => {
    const { service, agentDir, project } = fixture();
    const hanging = await listen(
      createServer(() => {
        /* deliberately never answers initialize */
      }),
    );
    writeFileSync(join(agentDir, "trust.json"), JSON.stringify({ [realpathSync(project)]: true }));
    await service.add({ scopeId: "global", name: "shared", url: hanging + "/mcp" });
    // Project replacement avoids probing the hanging global entry in this scope.
    await service.add({
      scopeId: "workspace-one",
      name: "shared",
      command: process.execPath,
      args: [echo],
    });
    const base = await routes(service);
    const started = performance.now();
    const first = api<McpServersResponse>(base, "/mcp/servers");
    const second = api<McpServersResponse>(base, "/mcp/servers");
    const [snapshot, coalesced] = await Promise.all([first, second]);
    expect(performance.now() - started).toBeLessThan(25_000);
    expect(snapshot).toEqual(coalesced);
    expect(snapshot.scopes[0].errors).toEqual([
      "This scope's live probe timed out after 20 seconds. Other scopes still refreshed.",
    ]);
    expect(snapshot.scopes[1]).toMatchObject({
      trusted: true,
      errors: [],
      servers: [{ name: "shared", state: "connected", tools: ["echo"] }],
    });
  }, 30_000);
  it("connects trusted project tools and keeps same-name globals owned by their scope", async () => {
    const { service, agentDir, project } = fixture();
    writeFileSync(join(agentDir, "trust.json"), JSON.stringify({ [realpathSync(project)]: true }));
    await service.add({
      scopeId: "global",
      name: "shared",
      command: "not-a-real-executable",
      exposure: "hidden",
    });
    await service.add({
      scopeId: "workspace-one",
      name: "shared",
      command: process.execPath,
      args: [echo],
    });
    const base = await routes(service);
    const snapshot = await api<McpServersResponse>(base, "/mcp/servers");
    expect(snapshot.scopes[0].servers[0]).toMatchObject({
      name: "shared",
      state: "failed",
      exposure: "hidden",
    });
    expect(snapshot.scopes[1]).toMatchObject({
      trusted: true,
      errors: [],
      servers: [{ name: "shared", state: "connected", tools: ["echo"] }],
    });
    await api(base, "/mcp/scopes/workspace-one/servers/shared", "PATCH", {
      enabled: false,
      exposure: "direct",
    });
    expect(
      JSON.parse(readFileSync(join(project, ".pi", "mcp.json"), "utf8")).mcpServers.shared,
    ).toMatchObject({ enabled: false, exposure: "direct" });
    expect(JSON.parse(readFileSync(join(agentDir, "mcp.json"), "utf8")).mcpServers.shared).toEqual({
      command: "not-a-real-executable",
      exposure: "hidden",
    });
  }, 30_000);
  it("signs in a project-only OAuth server using its trusted workspace cwd", async () => {
    const { service, agentDir, project } = fixture();
    const remote = await oauthServer();
    const base = await routes(service);
    writeFileSync(join(agentDir, "trust.json"), JSON.stringify({ [realpathSync(project)]: true }));
    await api(base, "/mcp/servers", "POST", {
      scopeId: "workspace-one",
      name: "project-oauth",
      url: remote + "/mcp",
    });
    const initial = await api<McpServersResponse>(base, "/mcp/servers");
    expect(initial.scopes[0].servers).toEqual([]);
    expect(initial.scopes[1]).toMatchObject({
      trusted: true,
      servers: [{ name: "project-oauth", state: "needs-auth" }],
    });
    let flow = (
      await api<{ flow: McpAuthFlowSnapshot }>(
        base,
        "/mcp/scopes/workspace-one/servers/project-oauth/login",
        "POST",
        {},
      )
    ).flow;
    await expect
      .poll(
        async () => {
          flow = (await api<{ flow: McpAuthFlowSnapshot }>(base, `/mcp/auth/flows/${flow.flowId}`))
            .flow;
          return flow.status;
        },
        { timeout: 10_000 },
      )
      .toBe("awaiting_external");
    expect(flow.scopeId).toBe("workspace-one");
    const approval = await fetch(flow.auth!.url, { redirect: "manual" });
    await api(base, `/mcp/auth/flows/${flow.flowId}/manual-code`, "POST", {
      input: approval.headers.get("location"),
    });
    await expect
      .poll(() => service.auth.get(flow.flowId).status, { timeout: 10_000 })
      .toBe("completed");
    const connected = await api<McpServersResponse>(base, "/mcp/servers");
    expect(connected.scopes[1].servers[0]).toMatchObject({ state: "connected", tools: ["echo"] });
    expect(existsSync(join(agentDir, "mcp.json"))).toBe(false);
  }, 30_000);
  it("adds/probes/patches/removes command and URL entries in the right scope without revealing secrets or executing untrusted projects", async () => {
    const { service, agentDir, project } = fixture();
    const base = await routes(service);
    await api(base, "/mcp/servers", "POST", {
      scopeId: "global",
      name: "echo",
      command: process.execPath,
      args: [echo],
      env: { PRIVATE: "literal-secret", REF: "${PATH}" },
    });
    await api(base, "/mcp/servers", "POST", {
      scopeId: "workspace-one",
      name: "remote",
      url: "https://example.test/mcp",
      headers: { Authorization: "Bearer literal-private" },
      oauth: { clientId: "client", clientSecret: "literal-client-secret", callbackPort: 8765 },
    });
    let snapshot = await api<McpServersResponse>(base, "/mcp/servers");
    expect(snapshot.scopes.map((scope) => scope.id)).toEqual(["global", "workspace-one"]);
    expect(snapshot.scopes[0].servers[0]).toMatchObject({
      name: "echo",
      state: "connected",
      tools: ["echo"],
      config: { env: { PRIVATE: "[redacted]", REF: "${PATH}" } },
    });
    expect(snapshot.scopes[1]).toMatchObject({
      trusted: false,
      servers: [
        {
          name: "remote",
          state: "untrusted",
          config: {
            headers: { Authorization: "[redacted]" },
            oauth: { clientSecret: "[redacted]" },
          },
        },
      ],
    });
    expect(JSON.stringify(snapshot)).not.toContain("literal-");
    await api(base, "/mcp/scopes/global/servers/echo", "PATCH", {
      enabled: false,
      exposure: "direct",
    });
    snapshot = await api<McpServersResponse>(base, "/mcp/servers");
    expect(snapshot.scopes[0].servers[0]).toMatchObject({ state: "disabled", exposure: "direct" });
    await api(base, "/mcp/scopes/global/servers/echo", "PATCH", {
      enabled: true,
      exposure: "codemode",
    });
    expect(
      JSON.parse(readFileSync(join(agentDir, "mcp.json"), "utf8")).mcpServers.echo.enabled,
    ).toBeUndefined();
    await api(base, "/mcp/scopes/workspace-one/servers/remote", "DELETE");
    expect(JSON.parse(readFileSync(join(project, ".pi/mcp.json"), "utf8")).mcpServers).toEqual({});
    await api(base, "/mcp/scopes/global/servers/echo", "DELETE");
    expect((await service.list()).scopes[0].servers).toEqual([]);
    console.log(
      "MCP proof: command add → connected (echo tool) → disabled/direct → enabled/default → remove; project URL add → untrusted/redacted → remove",
    );
  }, 30_000);
  it.each(["phone paste", "host callback"])(
    "needs-auth → login → connected → logout using %s",
    async (mode) => {
      const { service, agentDir } = fixture();
      const remote = await oauthServer();
      const base = await routes(service);
      await api(base, "/mcp/servers", "POST", {
        scopeId: "global",
        name: "remote",
        url: remote + "/mcp",
      });
      expect((await api<McpServersResponse>(base, "/mcp/servers")).scopes[0].servers[0].state).toBe(
        "needs-auth",
      );
      let flow = (
        await api<{ flow: McpAuthFlowSnapshot }>(
          base,
          "/mcp/scopes/global/servers/remote/login",
          "POST",
          {},
        )
      ).flow;
      await expect
        .poll(
          async () => {
            flow = (
              await api<{ flow: McpAuthFlowSnapshot }>(base, `/mcp/auth/flows/${flow.flowId}`)
            ).flow;
            return flow.status;
          },
          { timeout: 10_000 },
        )
        .toBe("awaiting_external");
      const approval = await fetch(flow.auth!.url, { redirect: "manual" });
      const callback = approval.headers.get("location")!;
      if (mode === "phone paste")
        await api(base, `/mcp/auth/flows/${flow.flowId}/manual-code`, "POST", { input: callback });
      else expect((await fetch(callback)).status).toBe(200);
      await expect
        .poll(() => service.auth.get(flow.flowId).status, { timeout: 10_000 })
        .toBe("completed");
      const snapshot = await api<McpServersResponse>(base, "/mcp/servers");
      expect(snapshot.scopes[0].servers[0]).toMatchObject({ state: "connected", tools: ["echo"] });
      expect(JSON.stringify(snapshot)).not.toMatch(/fixture-token|fixture-refresh/);
      expect(existsSync(join(agentDir, "mcp-auth.json"))).toBe(true);
      await api(base, "/mcp/scopes/global/servers/remote/logout", "POST", {});
      expect((await service.list()).scopes[0].servers[0].state).toBe("needs-auth");
      console.log(
        `MCP proof (${mode}): needs-auth → authorization URL → callback → completed → connected (echo tool) → logout → needs-auth`,
      );
    },
    30_000,
  );
  it("cancel/expiry are terminal despite late child exit; duplicate and post-terminal submissions are rejected", async () => {
    const { service } = fixture(1500);
    const remote = await oauthServer();
    await service.add({ scopeId: "global", name: "remote", url: remote + "/mcp" });
    const flow = await service.login("global", "remote", "phone_browser");
    await expect
      .poll(() => service.auth.get(flow.flowId).status, { timeout: 10_000 })
      .toBe("awaiting_external");
    await expect(service.login("global", "remote", "phone_browser")).rejects.toMatchObject({
      statusCode: 409,
    });
    expect(service.auth.cancel(flow.flowId).status).toBe("cancelled");
    await expect(service.auth.submit(flow.flowId, "bad")).rejects.toMatchObject({
      statusCode: 409,
    });
    expect(service.auth.get(flow.flowId).status).toBe("cancelled");
    await expect.poll(() => service.auth.hasActive(), { timeout: 5000 }).toBe(false);
    const expired = await service.login("global", "remote", "phone_browser");
    await expect
      .poll(() => service.auth.get(expired.flowId).status, { timeout: 10_000 })
      .toBe("expired");
    expect(service.auth.get(flow.flowId).status).toBe("cancelled");
  }, 30_000);
  it("child connection failure settles a failed flow without exposing subprocess output", async () => {
    const { service } = fixture();
    await service.add({ scopeId: "global", name: "dead", url: "http://127.0.0.1:1/mcp" });
    const flow = await service.login("global", "dead", "phone_browser");
    await expect
      .poll(() => service.auth.get(flow.flowId).status, { timeout: 10_000 })
      .toBe("failed");
    expect(service.auth.get(flow.flowId).error).toContain("Pi MCP sign-in failed");
  }, 30_000);
});
