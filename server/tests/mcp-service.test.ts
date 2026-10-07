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
import { makeRouteSessions } from "./harness/route-test-helpers.js";
import { validateMcpCallback } from "../src/mcp-auth.js";
import {
  patchMcpConfig,
  redactMcpValue,
  redactMcpDiagnostic,
  safeMcpConfig,
} from "../src/mcp-config.js";
import type { McpAuthFlowSnapshot, McpServersResponse, Workspace } from "../src/types.js";

const echo = resolve("tests/fixtures/mcp-echo.cjs");
const GLOBAL = "/mcp/scopes/global/servers";
const PROJECT = "/mcp/scopes/workspace-one/servers";
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
  const handler = new RouteHandler({ mcp: service, sessions: makeRouteSessions() } as RouteContext);
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
  it("overlaps probes of different scopes, shares one per scope, and keeps mutations exclusive of probes", async () => {
    const { service } = fixture();
    const gates: Array<() => void> = [];
    const run = vi.spyOn(McpCli.prototype, "run").mockImplementation(
      (args) =>
        new Promise((resolve) => {
          const done = () => resolve({ code: 0, stdout: '{"servers":[],"errors":[]}' });
          if (args[0] === "list") gates.push(done);
          else done();
        }),
    );
    try {
      const global = service.list("global");
      const shared = service.list("global");
      const project = service.list("workspace-one");
      await expect.poll(() => gates.length).toBe(2);
      await expect(service.add("global", { name: "new", command: "echo" })).rejects.toMatchObject({
        statusCode: 409,
      });
      for (const open of gates.splice(0)) open();
      expect(await global).toBe(await shared);
      expect((await project).scope.id).toBe("workspace-one");
      const mutation = service.add("global", { name: "new", command: "echo" });
      await expect(service.list("global")).rejects.toMatchObject({ statusCode: 409 });
      await mutation;
      const next = service.list("global");
      await expect.poll(() => gates.length).toBe(1);
      gates[0]();
      await next;
    } finally {
      run.mockRestore();
    }
  });
  it("bounds mutation CLIs below the phone deadline and rejects waiting behind another mutation", async () => {
    const { service, agentDir } = fixture();
    writeFileSync(
      join(agentDir, "mcp.json"),
      JSON.stringify({ mcpServers: { remote: { url: "https://example.test/mcp" } } }),
    );
    const run = vi.spyOn(McpCli.prototype, "run").mockResolvedValue({ code: 0, stdout: "" });
    try {
      const pending = service.add("global", { name: "new", command: "echo" });
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
  it("refuses project sign-in/out without a remembered trust, even when defaultProjectTrust is always", async () => {
    const { service, project, agentDir } = fixture();
    writeFileSync(
      join(project, ".pi", "mcp.json"),
      JSON.stringify({
        mcpServers: {
          remote: { url: "https://example.test/mcp" },
          off: { url: "https://example.test/off", enabled: false },
        },
      }),
    );
    // Sessions trust by this default, but `pi mcp login/logout` read only a saved decision,
    // so they would miss the project entry (or reach a same-name global one).
    writeFileSync(
      join(agentDir, "settings.json"),
      JSON.stringify({ defaultProjectTrust: "always" }),
    );
    const run = vi.spyOn(McpCli.prototype, "run");
    try {
      for (const action of [
        () => service.login("workspace-one", "remote", "phone_browser"),
        () => service.logout("workspace-one", "remote"),
      ])
        await expect(action()).rejects.toMatchObject({
          statusCode: 409,
          message: expect.stringContaining("Trust (remember)"),
        });
      expect(run).not.toHaveBeenCalled();
      // Sessions load the file, so trust reads Trusted; the probe skipped it, so the row
      // says why it has no status instead of Failed.
      expect((await service.list("workspace-one")).scope).toMatchObject({
        projectTrust: "trusted",
        // A disabled entry is just as unreadable to sign-in, so it says the same.
        servers: [
          { name: "remote", state: "untrusted" },
          { name: "off", enabled: false, state: "untrusted" },
        ],
      });
      writeFileSync(
        join(agentDir, "trust.json"),
        JSON.stringify({ [realpathSync(project)]: false }),
      );
      await expect(service.login("workspace-one", "remote", "phone_browser")).rejects.toMatchObject(
        { statusCode: 409, message: expect.stringContaining("not trusted") },
      );
    } finally {
      run.mockRestore();
    }
  });
  it("does not mark a global replaced when Pi read the project file and rejected the entry", async () => {
    const { service, agentDir, project } = fixture();
    writeFileSync(join(agentDir, "trust.json"), JSON.stringify({ [realpathSync(project)]: true }));
    writeFileSync(
      join(agentDir, "mcp.json"),
      JSON.stringify({
        mcpServers: {
          shared: { url: "https://example.test/global" },
          other: { url: "https://example.test/other" },
        },
      }),
    );
    writeFileSync(
      join(project, ".pi", "mcp.json"),
      JSON.stringify({
        mcpServers: { shared: { url: "ftp://invalid" }, other: { command: "echo" } },
      }),
    );
    // Pi kept the global `shared` (invalid project entry) and loaded the project `other`.
    const servers = [
      { name: "shared", scope: "global", state: "connected", tools: ["t"] },
      { name: "other", scope: "project", state: "connected", tools: [] },
    ];
    const run = vi
      .spyOn(McpCli.prototype, "run")
      .mockResolvedValue({ code: 0, stdout: JSON.stringify({ servers, errors: [] }) });
    try {
      expect((await service.list("workspace-one")).scope.inherited).toMatchObject([
        { name: "shared", state: "connected", tools: ["t"] },
        { name: "other", state: "replaced" },
      ]);
    } finally {
      run.mockRestore();
    }
  });
  it("ignores a distrusted project's file: its servers are untrusted and globals are not replaced", async () => {
    const { service, agentDir, project } = fixture();
    writeFileSync(join(agentDir, "trust.json"), JSON.stringify({ [realpathSync(project)]: false }));
    writeFileSync(
      join(agentDir, "mcp.json"),
      JSON.stringify({ mcpServers: { shared: { url: "https://example.test/global" } } }),
    );
    writeFileSync(
      join(project, ".pi", "mcp.json"),
      JSON.stringify({ mcpServers: { shared: { command: "echo" } } }),
    );
    const report = { name: "shared", scope: "global", state: "connected", tools: ["t"] };
    const run = vi
      .spyOn(McpCli.prototype, "run")
      .mockResolvedValue({ code: 0, stdout: JSON.stringify({ servers: [report], errors: [] }) });
    try {
      expect((await service.list("workspace-one")).scope).toMatchObject({
        projectTrust: "distrusted",
        servers: [{ name: "shared", state: "untrusted", tools: [] }],
        inherited: [{ name: "shared", state: "connected", tools: ["t"] }],
      });
    } finally {
      run.mockRestore();
    }
  });
  it("gives a folderless host workspace the project file in its sessions' home cwd", async () => {
    const { agentDir, dir } = fixture();
    const home = join(dir, "home");
    mkdirSync(home);
    vi.stubEnv("HOME", home);
    const run = vi.spyOn(McpCli.prototype, "run").mockResolvedValue({ code: 0, stdout: "" });
    const service = new McpService({
      agentDir,
      listWorkspaces: () => [{ id: "loose", name: "Loose", runtime: "host" } as Workspace],
    });
    services.push(service);
    try {
      await service.add("loose", { name: "echo", command: "echo" });
      expect(run.mock.calls[0]?.[0].slice(0, 2)).toEqual(["add", "--local"]);
      expect(run.mock.calls[0]?.[1]).toBe(home);
    } finally {
      run.mockRestore();
      vi.unstubAllEnvs();
    }
  });
  it("adds the default exposure without storing an explicit codemode field", async () => {
    const { service, agentDir } = fixture();
    await service.add("global", {
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
  it("lists which global servers a sandbox may run, without probing, and refuses changes there", async () => {
    const { agentDir, workspace } = fixture();
    writeFileSync(
      join(agentDir, "mcp.json"),
      JSON.stringify({
        mcpServers: {
          allowed: { url: "https://mcp.example.com/mcp" },
          elsewhere: { url: "https://other.test/mcp" },
          local: { command: "node", args: ["s.js"], env: { LANG: "C" } },
          secretive: { command: "node", env: { KEY: "${HOST_KEY}" } },
          off: { url: "https://mcp.example.com/off", enabled: false },
        },
      }),
    );
    const service = new McpService({
      agentDir,
      listWorkspaces: () => [
        {
          ...workspace,
          id: "sandbox",
          runtime: "sandbox",
          sandboxConfig: { allowedHosts: ["*.example.com"] },
        },
      ],
    });
    services.push(service);
    const run = vi.spyOn(McpCli.prototype, "run");
    try {
      const { scope } = await service.list("sandbox");
      expect(scope.kind).toBe("sandbox");
      expect(scope.servers.map(({ name, state, error }) => ({ name, state, error }))).toEqual([
        { name: "allowed", state: "available", error: undefined },
        {
          name: "elsewhere",
          state: "blocked",
          error: "other.test is not in this workspace's Allowed Hosts.",
        },
        { name: "local", state: "available", error: undefined },
        { name: "secretive", state: "blocked", error: expect.stringContaining("host secret") },
        { name: "off", state: "disabled", error: undefined },
      ]);
      expect(run).not.toHaveBeenCalled();
      for (const change of [
        () => service.add("sandbox", { name: "new", command: "echo" }),
        () => service.patch("sandbox", "allowed", { enabled: false }),
        () => service.remove("sandbox", "allowed"),
        () => service.login("sandbox", "allowed", "phone_browser"),
        () => service.logout("sandbox", "allowed"),
      ])
        await expect(change()).rejects.toMatchObject({ statusCode: 409 });
      expect(run).not.toHaveBeenCalled();
    } finally {
      run.mockRestore();
    }
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
    await expect(service.add("missing", { name: "bad", command: "echo" })).rejects.toMatchObject({
      statusCode: 404,
    });
    await expect(service.list("missing")).rejects.toMatchObject({ statusCode: 404 });
    const snapshot = await service.list("global");
    expect(JSON.stringify(snapshot)).not.toContain("private-value");
    expect(snapshot.scope.errors).toHaveLength(1);
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
    const flight = service.list("global");
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
      await expect(service.add("global", { name: "late", command: "echo" })).rejects.toMatchObject({
        statusCode: 503,
      });
    } finally {
      if (pid && alive()) process.kill(pid, "SIGKILL");
      await flight.catch(() => {});
    }
  }, 30_000);
  it("lists a healthy scope while another scope's probe hangs, within the phone deadline", async () => {
    const { service, agentDir, project } = fixture();
    const hanging = await listen(
      createServer(() => {
        /* deliberately never answers initialize */
      }),
    );
    writeFileSync(join(agentDir, "trust.json"), JSON.stringify({ [realpathSync(project)]: true }));
    await service.add("global", { name: "shared", url: hanging + "/mcp" });
    // Project replacement avoids probing the hanging global entry in this scope.
    await service.add("workspace-one", { name: "shared", command: process.execPath, args: [echo] });
    const base = await routes(service);
    const started = performance.now();
    const first = api<McpServersResponse>(base, GLOBAL);
    const second = api<McpServersResponse>(base, GLOBAL);
    const other = api<McpServersResponse>(base, PROJECT);
    const [snapshot, coalesced, projectSnapshot] = await Promise.all([first, second, other]);
    expect(performance.now() - started).toBeLessThan(25_000);
    expect(snapshot).toEqual(coalesced);
    expect(snapshot.scope.errors).toEqual(["This scope's live probe timed out after 20 seconds."]);
    expect(projectSnapshot.scope).toMatchObject({
      projectTrust: "trusted",
      errors: [],
      servers: [{ name: "shared", state: "connected", tools: ["echo"] }],
    });
  }, 30_000);
  it("connects trusted project tools and shows the same-name global as replaced there", async () => {
    const { service, agentDir, project } = fixture();
    writeFileSync(join(agentDir, "trust.json"), JSON.stringify({ [realpathSync(project)]: true }));
    await service.add("global", {
      name: "shared",
      command: "not-a-real-executable",
      exposure: "hidden",
    });
    await service.add("workspace-one", { name: "shared", command: process.execPath, args: [echo] });
    const base = await routes(service);
    const global = await api<McpServersResponse>(base, GLOBAL);
    expect(global.scope.servers[0]).toMatchObject({
      name: "shared",
      state: "failed",
      exposure: "hidden",
    });
    expect((await api<McpServersResponse>(base, PROJECT)).scope).toMatchObject({
      projectTrust: "trusted",
      errors: [],
      servers: [{ name: "shared", state: "connected", tools: ["echo"] }],
      inherited: [{ name: "shared", state: "replaced", tools: [], exposure: "hidden" }],
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
  // Pi still accepts `codemode-deferred` in hand-written mcp.json, but the app only decodes
  // Pi's four exposures; one unknown value would fail the whole server list on the phone.
  it("lists Pi's legacy codemode-deferred alias as codemode", async () => {
    const { service, agentDir } = fixture();
    writeFileSync(
      join(agentDir, "mcp.json"),
      JSON.stringify({
        mcpServers: {
          echo: {
            command: process.execPath,
            args: [echo],
            exposure: "codemode-deferred",
            toolExposure: { echo: "codemode-deferred" },
          },
        },
      }),
    );
    const snapshot = await service.list("global");
    expect(snapshot.scope.servers).toMatchObject([
      { name: "echo", state: "connected", exposure: "codemode" },
    ]);
    expect(JSON.stringify(snapshot)).not.toContain("codemode-deferred");
  }, 30_000);
  it("signs in a project-only OAuth server using its trusted workspace cwd", async () => {
    const { service, agentDir, project } = fixture();
    const remote = await oauthServer();
    const base = await routes(service);
    writeFileSync(join(agentDir, "trust.json"), JSON.stringify({ [realpathSync(project)]: true }));
    await api(base, PROJECT, "POST", { name: "project-oauth", url: remote + "/mcp" });
    expect((await api<McpServersResponse>(base, GLOBAL)).scope.servers).toEqual([]);
    expect((await api<McpServersResponse>(base, PROJECT)).scope).toMatchObject({
      projectTrust: "trusted",
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
    const connected = await api<McpServersResponse>(base, PROJECT);
    expect(connected.scope.servers[0]).toMatchObject({ state: "connected", tools: ["echo"] });
    expect(existsSync(join(agentDir, "mcp.json"))).toBe(false);
  }, 30_000);
  it("adds/probes/patches/removes command and URL entries in the right scope without revealing secrets or executing untrusted projects", async () => {
    const { service, agentDir, project } = fixture();
    const base = await routes(service);
    await api(base, GLOBAL, "POST", {
      name: "echo",
      command: process.execPath,
      args: [echo],
      env: { PRIVATE: "literal-secret", REF: "${PATH}" },
    });
    await api(base, PROJECT, "POST", {
      name: "remote",
      url: "https://example.test/mcp",
      headers: { Authorization: "Bearer literal-private" },
      oauth: { clientId: "client", clientSecret: "literal-client-secret", callbackPort: 8765 },
    });
    let snapshot = await api<McpServersResponse>(base, GLOBAL);
    const projectSnapshot = await api<McpServersResponse>(base, PROJECT);
    expect(snapshot.scope.id).toBe("global");
    expect(snapshot.scope.servers.map((entry) => entry.name)).toEqual(["echo"]);
    expect(snapshot.scope.servers[0]).toMatchObject({
      name: "echo",
      state: "connected",
      tools: ["echo"],
      config: { env: { PRIVATE: "[redacted]", REF: "${PATH}" } },
    });
    // An undecided project asks at session start; Pi's non-interactive probe does not trust
    // it, yet the global server still loads (and probes) in the project's cwd.
    expect(projectSnapshot.scope).toMatchObject({
      id: "workspace-one",
      projectTrust: "ask",
      inherited: [{ name: "echo", state: "connected", tools: ["echo"] }],
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
    expect(JSON.stringify([snapshot, projectSnapshot])).not.toContain("literal-");
    await api(base, "/mcp/scopes/global/servers/echo", "PATCH", {
      enabled: false,
      exposure: "direct",
    });
    snapshot = await api<McpServersResponse>(base, GLOBAL);
    expect(snapshot.scope.servers[0]).toMatchObject({ state: "disabled", exposure: "direct" });
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
    expect((await service.list("global")).scope.servers).toEqual([]);
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
      await api(base, GLOBAL, "POST", { name: "remote", url: remote + "/mcp" });
      expect((await api<McpServersResponse>(base, GLOBAL)).scope.servers[0].state).toBe(
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
      const snapshot = await api<McpServersResponse>(base, GLOBAL);
      expect(snapshot.scope.servers[0]).toMatchObject({ state: "connected", tools: ["echo"] });
      expect(JSON.stringify(snapshot)).not.toMatch(/fixture-token|fixture-refresh/);
      expect(existsSync(join(agentDir, "mcp-auth.json"))).toBe(true);
      await api(base, "/mcp/scopes/global/servers/remote/logout", "POST", {});
      expect((await service.list("global")).scope.servers[0].state).toBe("needs-auth");
      console.log(
        `MCP proof (${mode}): needs-auth → authorization URL → callback → completed → connected (echo tool) → logout → needs-auth`,
      );
    },
    30_000,
  );
  it("cancel/expiry are terminal despite late child exit; duplicate and post-terminal submissions are rejected", async () => {
    // Pi's login child needs more than 1.5s to publish the URL on a busy host.
    const { service } = fixture(20_000);
    const remote = await oauthServer();
    await service.add("global", { name: "remote", url: remote + "/mcp" });
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
      .poll(() => service.auth.get(expired.flowId).status, { timeout: 25_000 })
      .toBe("expired");
    expect(service.auth.get(flow.flowId).status).toBe("cancelled");
  }, 60_000);
  it("child connection failure settles a failed flow without exposing subprocess output", async () => {
    const { service } = fixture();
    await service.add("global", { name: "dead", url: "http://127.0.0.1:1/mcp" });
    const flow = await service.login("global", "dead", "phone_browser");
    await expect
      .poll(() => service.auth.get(flow.flowId).status, { timeout: 10_000 })
      .toBe("failed");
    expect(service.auth.get(flow.flowId).error).toContain("Pi MCP sign-in failed");
  }, 30_000);
  it("lists during a live sign-in without a second credential writer, reports the flow, and keeps mutations exclusive", async () => {
    const { service } = fixture();
    const remote = await oauthServer();
    const base = await routes(service);
    await service.add("global", { name: "remote", url: remote + "/mcp" });
    const before = await api<McpServersResponse>(base, GLOBAL);
    expect(before.activeSignIn).toBeUndefined();
    expect(before.scope.servers[0]).toMatchObject({ name: "remote", state: "needs-auth" });

    const flow = await service.login("global", "remote", "phone_browser");
    await expect
      .poll(() => service.auth.get(flow.flowId).status, { timeout: 10_000 })
      .toBe("awaiting_external");
    const run = vi.spyOn(McpCli.prototype, "run");
    try {
      const during = await api<McpServersResponse>(base, GLOBAL);
      // A workspace list also reports the host-wide flow so it can be resumed or cancelled.
      const project = await api<McpServersResponse>(base, PROJECT);
      expect(run).not.toHaveBeenCalled(); // No probe beside the login's credential writer.
      expect(project.activeSignIn?.flowId).toBe(flow.flowId);
      expect(during.scope.servers[0]).toMatchObject({ name: "remote", state: "needs-auth" });
      expect(during.activeSignIn).toMatchObject({
        flowId: flow.flowId,
        scopeId: "global",
        serverName: "remote",
        status: "awaiting_external",
      });
      expect(during.activeSignIn?.auth?.url).toContain("redirect_uri=");
    } finally {
      run.mockRestore();
    }
    for (const [path, method, body] of [
      [GLOBAL, "POST", { name: "other", url: remote + "/mcp" }],
      ["/mcp/scopes/global/servers/remote", "PATCH", { enabled: false }],
      ["/mcp/scopes/global/servers/remote", "DELETE", {}],
      ["/mcp/scopes/global/servers/remote/login", "POST", {}],
      ["/mcp/scopes/global/servers/remote/logout", "POST", {}],
    ] as const) {
      const response = await fetch(base + path, {
        method,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      expect(response.status, `${method} ${path}`).toBe(409);
    }

    // Cancel: the list keeps answering while Pi's child is reaped, then goes live again.
    await api(base, `/mcp/auth/flows/${flow.flowId}/cancel`, "POST", {});
    const cancelled = await api<McpServersResponse>(base, GLOBAL);
    if (cancelled.activeSignIn)
      expect(cancelled.activeSignIn).toMatchObject({ flowId: flow.flowId, status: "cancelled" });
    await expect
      .poll(async () => (await api<McpServersResponse>(base, GLOBAL)).activeSignIn, {
        timeout: 5000,
      })
      .toBeUndefined();
    await service.patch("global", "remote", { enabled: false });
  }, 30_000);
  it("serves config-only rows when a sign-in starts before any probe", async () => {
    const { service } = fixture();
    const remote = await oauthServer();
    await service.add("global", { name: "remote", url: remote + "/mcp" });
    const flow = await service.login("global", "remote", "phone_browser");
    const during = await service.list("global");
    expect(during.activeSignIn?.flowId).toBe(flow.flowId);
    expect(during.scope.servers[0]).toMatchObject({ name: "remote", state: "unknown" });
    expect(during.scope.errors).toEqual(["Live status is paused while a sign-in is in progress."]);
    service.auth.cancel(flow.flowId);
  }, 30_000);
  it("bounds dispose by a deadline when a killed child never settles", async () => {
    const { agentDir } = fixture();
    const stop = vi.fn();
    const deadline = new McpService({ agentDir, listWorkspaces: () => [], disposeDeadlineMs: 200 });
    services.push(deadline);
    (deadline as unknown as { children: Set<unknown> }).children.add({
      stop,
      done: new Promise(() => {}),
    });
    const start = performance.now();
    await deadline.dispose();
    expect(stop).toHaveBeenCalledWith(true);
    expect(performance.now() - start).toBeGreaterThanOrEqual(150);
    expect(performance.now() - start).toBeLessThan(1500);
  });
});
