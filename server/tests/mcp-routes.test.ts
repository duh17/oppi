import { Readable } from "node:stream";
import { describe, expect, it, vi } from "vitest";
import { RouteHandler, type RouteContext } from "../src/routes/index.js";

const targets = [
  ["POST", "/mcp/servers"],
  ["PATCH", "/mcp/scopes/global/servers/echo"],
  ["POST", "/mcp/scopes/global/servers/echo/login"],
  ["POST", "/mcp/auth/flows/flow-one/manual-code"],
  ["POST", "/mcp/auth/flows/flow-one/cancel"],
  ["POST", "/mcp/scopes/global/servers/echo/logout"],
  ["DELETE", "/mcp/scopes/global/servers/echo"],
] as const;
function harness() {
  const mcp = {
    add: vi.fn(),
    patch: vi.fn(),
    login: vi.fn(),
    remove: vi.fn(),
    logout: vi.fn(),
    auth: { submit: vi.fn(), cancel: vi.fn() },
  };
  const routes = new RouteHandler({ mcp } as unknown as RouteContext);
  const response = {
    statusCode: 0,
    payload: "",
    writeHead(code: number) {
      this.statusCode = code;
    },
    end(value: string) {
      this.payload = value;
    },
  };
  async function send(method: string, path: string, value: unknown, raw = false) {
    await routes.dispatch(
      method,
      path,
      new URL(path, "http://localhost"),
      Readable.from([raw ? value : JSON.stringify(value)]) as never,
      response as never,
    );
    return response;
  }
  return { mcp, send };
}
describe("MCP HTTP request validation", () => {
  for (const [method, path] of targets) {
    it.each([null, [], "text", 12])(`${method} ${path} rejects non-object %j`, async (value) => {
      const { mcp, send } = harness();
      expect((await send(method, path, value)).statusCode).toBe(400);
      for (const fn of [
        mcp.add,
        mcp.patch,
        mcp.login,
        mcp.remove,
        mcp.logout,
        mcp.auth.submit,
        mcp.auth.cancel,
      ])
        expect(fn).not.toHaveBeenCalled();
    });
  }
  it.each([
    { scopeId: 5, name: "echo", command: "node" },
    { scopeId: "global", name: 5, command: "node" },
    { scopeId: "global", name: "echo", url: 5 },
    { scopeId: "global", name: "echo", command: true },
    { scopeId: "global", name: "echo", command: "node", args: [5] },
    { scopeId: "global", name: "echo", command: "node", cwd: false },
    { scopeId: "global", name: "echo", command: "node", env: { KEY: 5 } },
    { scopeId: "global", name: "echo", url: "https://example.test", headers: null },
    { scopeId: "global", name: "echo", url: "https://example.test", oauth: null },
    { scopeId: "global", name: "echo", url: "https://example.test", oauth: { clientId: 5 } },
    { scopeId: "global", name: "echo", url: "https://example.test", oauth: { clientSecret: 5 } },
    {
      scopeId: "global",
      name: "echo",
      url: "https://example.test",
      oauth: { callbackPort: "8765" },
    },
    { scopeId: "global", name: "echo", command: "node", exposure: 5 },
  ])("add rejects wrong field types: %j", async (value) => {
    const { mcp, send } = harness();
    expect((await send("POST", "/mcp/servers", value)).statusCode).toBe(400);
    expect(mcp.add).not.toHaveBeenCalled();
  });
  it.each([{ enabled: "yes" }, { exposure: 5 }, { enabled: null }, { exposure: "bogus" }, {}])(
    "patch rejects %j",
    async (value) => {
      const { mcp, send } = harness();
      expect((await send("PATCH", "/mcp/scopes/global/servers/echo", value)).statusCode).toBe(400);
      expect(mcp.patch).not.toHaveBeenCalled();
    },
  );
  it.each([{ launchMode: 5 }, { launchMode: null }, { launchMode: "bogus" }])(
    "login rejects %j",
    async (value) => {
      const { mcp, send } = harness();
      expect((await send("POST", "/mcp/scopes/global/servers/echo/login", value)).statusCode).toBe(
        400,
      );
      expect(mcp.login).not.toHaveBeenCalled();
    },
  );
  it.each([{ input: 5 }, { input: null }, {}, { input: " " }])(
    "manual callback rejects %j",
    async (value) => {
      const { mcp, send } = harness();
      expect((await send("POST", "/mcp/auth/flows/flow-one/manual-code", value)).statusCode).toBe(
        400,
      );
      expect(mcp.auth.submit).not.toHaveBeenCalled();
    },
  );
  it("malformed JSON is a 400, not an unhandled server error", async () => {
    const { mcp, send } = harness();
    expect((await send("POST", "/mcp/servers", "{", true)).statusCode).toBe(400);
    expect(mcp.add).not.toHaveBeenCalled();
  });
  it("validates before forwarding typed add/patch/login/manual requests", async () => {
    const { mcp, send } = harness();
    const add = {
      scopeId: "global",
      name: "echo",
      command: "node",
      args: ["echo.cjs"],
      env: { KEY: "${TOKEN}" },
    };
    expect((await send("POST", "/mcp/servers", add)).statusCode).toBe(201);
    expect(mcp.add).toHaveBeenCalledWith(add);
    expect(
      (await send("PATCH", "/mcp/scopes/global/servers/echo", { enabled: false })).statusCode,
    ).toBe(200);
    expect(mcp.patch).toHaveBeenCalledWith("global", "echo", { enabled: false });
    expect((await send("POST", "/mcp/scopes/global/servers/echo/login", {})).statusCode).toBe(201);
    expect(mcp.login).toHaveBeenCalledWith("global", "echo", "phone_browser");
    expect(
      (
        await send("POST", "/mcp/auth/flows/flow-one/manual-code", {
          input: "http://127.0.0.1:8765/callback?code=fixture",
        })
      ).statusCode,
    ).toBe(200);
    expect(mcp.auth.submit).toHaveBeenCalledWith(
      "flow-one",
      "http://127.0.0.1:8765/callback?code=fixture",
    );
  });
});
