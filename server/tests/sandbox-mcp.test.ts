import { describe, expect, it, vi } from "vitest";
import type { McpServerEntry } from "@earendil-works/pi-coding-agent";
import type { GondolinProcess, GondolinVm } from "../src/gondolin-ops.js";
import {
  createSandboxMcpOptions,
  withoutCodemode,
  matchesAllowedHost,
  sandboxMcpBlockReason,
  VmStdioTransport,
} from "../src/sandbox-mcp.js";

describe("sandbox MCP eligibility", () => {
  it.each([
    [undefined, "api.example.com", true],
    [[], "api.example.com", false],
    [["*"], "api.example.com", true],
    [["*.example.com"], "api.example.com", true],
    [["*.example.com"], "example.com", false],
    [["API.Example.com"], "api.example.com", true],
    [[" "], "api.example.com", false],
    [["example.com"], "evil-example.com", false],
  ])("Allowed Hosts %j admits %s: %s", (hosts, host, allowed) => {
    expect(matchesAllowedHost(host, hosts)).toBe(allowed);
  });

  it.each([
    ["http://localhost:8080/mcp", undefined],
    ["http://127.0.0.1/mcp", ["*"]],
    ["http://192.168.1.5/mcp", ["192.168.*"]],
    ["http://100.101.1.2/mcp", undefined],
    ["http://box.tail1234.ts.net/mcp", ["*.ts.net"]],
    ["http://[::1]/mcp", undefined],
    ["http://[fd00::1]/mcp", undefined],
    ["http://printer.local/mcp", undefined],
    ["http://[::ffff:127.0.0.1]/mcp", undefined],
    ["http://[::ffff:a00:1]/mcp", ["*"]],
    ["http://[::127.0.0.1]/mcp", undefined],
    ["http://[64:ff9b::7f00:1]/mcp", undefined],
    ["http://[fec0::1]/mcp", undefined],
    ["http://nas.home.arpa/mcp", undefined],
  ])("blocks private %s unless listed exactly (Allowed Hosts %j)", (url, hosts) => {
    expect(sandboxMcpBlockReason({ url }, hosts)).toContain("private or local");
    const host = new URL(url).hostname.replace(/^\[|\]$/g, "");
    expect(sandboxMcpBlockReason({ url }, [host])).toBeUndefined();
  });

  it.each(["localhost.", "foo.local."])("treats a trailing-dot name like the name: %s", (host) => {
    expect(sandboxMcpBlockReason({ url: `http://${host}/mcp` }, ["*"])).toContain("private");
  });

  it.each([
    "https://fd.example.com/mcp",
    "https://fcbank.com/mcp",
    "http://100.128.0.1/mcp",
    "http://[2001:db8::1]/mcp",
    "http://[::ffff:8.8.8.8]/mcp",
  ])("does not flag public %s", (url) => {
    expect(sandboxMcpBlockReason({ url }, undefined)).toBeUndefined();
  });

  it.each([
    [{ headers: { Authorization: "!security find-generic-password -w -s mcp" } }],
    [{ oauth: { clientSecret: "!op read op://vault/mcp/secret" } }],
    [{ auth: { provider: "github-copilot" } }],
  ])("blocks HTTP values that could run host commands: %j", (extra) => {
    const url = "https://mcp.example.com/mcp";
    expect(sandboxMcpBlockReason({ url, ...extra }, ["mcp.example.com"])).toMatch(
      /!command|auth\.provider/,
    );
    // `${NAME}` references resolve on the host without running anything.
    expect(
      sandboxMcpBlockReason({ url, headers: { Authorization: "Bearer ${TOKEN}" } }, [
        "mcp.example.com",
      ]),
    ).toBeUndefined();
  });

  it("treats any url key as HTTP, like Pi, so a stdio-typed entry cannot skip the HTTP checks", () => {
    const confused = { type: "stdio", command: "node", url: 1, oauth: { clientSecret: "!cmd" } };
    expect(sandboxMcpBlockReason(confused, undefined)).toBe("Its URL is not valid.");
  });

  it("admits an HTTP server only when its URL host is allowed, whatever its headers", () => {
    const remote = {
      url: "https://mcp.example.com/mcp",
      headers: { Authorization: "Bearer ${T}" },
    };
    expect(sandboxMcpBlockReason(remote, ["mcp.example.com"])).toBeUndefined();
    expect(sandboxMcpBlockReason(remote, ["other.com"])).toContain("mcp.example.com");
    expect(sandboxMcpBlockReason({ url: "not a url" }, undefined)).toBeDefined();
  });

  it.each([
    [{ KEY: "${HOST_TOKEN}" }, false],
    [{ KEY: "$HOST_TOKEN" }, false],
    [{ KEY: "!security find-generic-password" }, false],
    [{ LANG: "C.UTF-8" }, true],
    [undefined, true],
  ])("stdio env %j may enter the VM: %s", (env, allowed) => {
    const reason = sandboxMcpBlockReason({ command: "node", ...(env ? { env } : {}) }, []);
    expect(reason === undefined).toBe(allowed);
  });
});

/** A VM process whose stdout the test drives, recording what the transport writes. */
function fakeVm() {
  const written: string[] = [];
  const chunks: Array<{ stream: "stdout" | "stderr"; data: Buffer }> = [];
  let wake: (() => void) | undefined;
  let exit: ((code: number) => void) | undefined;
  let exited = false;
  let signal: AbortSignal | undefined;
  let execs = 0;
  let rejectAborted: (() => void) | undefined;
  // Like Gondolin's ExecProcess: an aborted exec rejects with "exec aborted".
  const result = new Promise<{ exitCode: number }>((resolve, reject) => {
    exit = (exitCode) => {
      exited = true;
      wake?.();
      resolve({ exitCode });
    };
    rejectAborted = () => {
      exited = true;
      wake?.();
      reject(new Error("exec aborted"));
    };
  });
  const process = Object.assign(result, {
    write: (data: string | Buffer) => written.push(String(data)),
    end: () => undefined,
    output: async function* () {
      while (!exited || chunks.length) {
        if (!chunks.length) await new Promise<void>((resolve) => (wake = resolve));
        const chunk = chunks.shift();
        if (chunk) yield chunk;
      }
    },
  }) as unknown as GondolinProcess;
  const vm = {
    exec: (_argv: string[], options?: { signal?: AbortSignal }) => {
      execs++;
      signal = options?.signal;
      signal?.addEventListener("abort", () => rejectAborted?.());
      return process;
    },
  } as unknown as GondolinVm;
  return {
    vm,
    written,
    execs: () => execs,
    signal: () => signal,
    emit: (stream: "stdout" | "stderr", data: string | Buffer) => {
      chunks.push({ stream, data: Buffer.from(data) });
      wake?.();
    },
    exit: (code: number) => exit?.(code),
  };
}

describe("VmStdioTransport", () => {
  it("frames newline-delimited JSON-RPC across chunk boundaries in both directions", async () => {
    const peer = fakeVm();
    const transport = new VmStdioTransport(async () => peer.vm, ["node", "s.js"], {
      cwd: "/workspace",
      env: {},
    });
    const messages: unknown[] = [];
    transport.onMessage((message) => messages.push(message));
    await transport.start();
    await transport.send({ jsonrpc: "2.0", id: 1, method: "ping" } as never);
    expect(peer.written).toEqual(['{"jsonrpc":"2.0","id":1,"method":"ping"}\n']);
    peer.emit("stdout", '{"jsonrpc":"2.0","id":1,');
    peer.emit("stdout", '"result":{}}\n{"jsonrpc":"2.0","id":2,"result":{}}\n');
    await expect.poll(() => messages.length).toBe(2);
    expect(messages[0]).toEqual({ jsonrpc: "2.0", id: 1, result: {} });
    await transport.close();
  });

  it("reports a non-JSON line and a failed exit with the server's stderr, then closes once", async () => {
    const peer = fakeVm();
    const transport = new VmStdioTransport(async () => peer.vm, ["missing"], {
      cwd: "/workspace",
      env: {},
    });
    const errors: string[] = [];
    let closes = 0;
    transport.onError((error) => errors.push(error.message));
    transport.onClose(() => closes++);
    await transport.start();
    peer.emit("stdout", "hello\n");
    peer.emit("stderr", "sh: missing: not found\n");
    peer.exit(127);
    await expect.poll(() => closes).toBe(1);
    expect(errors).toEqual([
      "The sandboxed MCP server wrote a line that is not JSON",
      "Sandboxed MCP server exited with code 127: sh: missing: not found",
    ]);
    await transport.close();
    expect(closes).toBe(1);
    await expect(transport.send({} as never)).rejects.toThrow("not running");
  });

  it("keeps a multi-byte character split across chunks intact", async () => {
    const peer = fakeVm();
    const transport = new VmStdioTransport(async () => peer.vm, ["node"], { cwd: "/", env: {} });
    const messages: unknown[] = [];
    transport.onMessage((message) => messages.push(message));
    await transport.start();
    const bytes = Buffer.from('{"jsonrpc":"2.0","id":1,"result":"\u4e2d\u6587"}\n');
    const split = bytes.indexOf(Buffer.from("\u4e2d")) + 1;
    peer.emit("stdout", bytes.subarray(0, split));
    peer.emit("stdout", bytes.subarray(split));
    await expect.poll(() => messages.length).toBe(1);
    expect(messages[0]).toMatchObject({ result: "\u4e2d\u6587" });
    await transport.close();
  });

  it("stops an oversized peer without an unhandled rejection", async () => {
    const unhandled = vi.fn();
    process.on("unhandledRejection", unhandled);
    try {
      const peer = fakeVm();
      const transport = new VmStdioTransport(async () => peer.vm, ["node"], {
        cwd: "/",
        env: {},
      });
      const errors: string[] = [];
      let closes = 0;
      transport.onError((error) => errors.push(error.message));
      transport.onClose(() => closes++);
      await transport.start();
      peer.emit("stdout", Buffer.alloc(VmStdioTransport.maxMessageBytes + 1, 0x61));
      await expect.poll(() => closes).toBe(1);
      expect(peer.signal()?.aborted).toBe(true);
      expect(errors).toEqual(["MCP message from the sandbox exceeded 16 MiB"]);
      await new Promise((resolve) => setTimeout(resolve, 20));
      expect(unhandled).not.toHaveBeenCalled();
    } finally {
      process.off("unhandledRejection", unhandled);
    }
  });

  it("refuses an oversized line even when it arrives whole with its newline", async () => {
    const peer = fakeVm();
    const transport = new VmStdioTransport(async () => peer.vm, ["node"], { cwd: "/", env: {} });
    const messages: unknown[] = [];
    const errors: string[] = [];
    transport.onMessage((message) => messages.push(message));
    transport.onError((error) => errors.push(error.message));
    await transport.start();
    const body = Buffer.alloc(VmStdioTransport.maxMessageBytes + 1, 0x61);
    peer.emit("stdout", Buffer.concat([body, Buffer.from("\n")]));
    await expect.poll(() => errors).toEqual(["MCP message from the sandbox exceeded 16 MiB"]);
    expect(messages).toEqual([]);
  });

  it("delivers every line once across arbitrary chunking, and nothing after a close", async () => {
    const peer = fakeVm();
    const transport = new VmStdioTransport(async () => peer.vm, ["node"], { cwd: "/", env: {} });
    const ids: number[] = [];
    transport.onMessage((message) => {
      const id = (message as { id: number }).id;
      ids.push(id);
      if (id === 4) void transport.close();
    });
    await transport.start();
    const text = [1, 2, 3, 4, 5, 6]
      .map((id) => JSON.stringify({ jsonrpc: "2.0", id, result: "\u00e9\u4e2d" }) + "\n")
      .join("");
    const bytes = Buffer.from(text);
    // Uneven chunks: some without a newline, one holding several lines.
    for (const [from, to] of [
      [0, 3],
      [3, 17],
      [17, 60],
      [60, 200],
      [200, bytes.length],
    ])
      peer.emit("stdout", bytes.subarray(from, to));
    await expect.poll(() => ids.at(-1)).toBe(4);
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(ids).toEqual([1, 2, 3, 4]);
  });

  it("never starts a peer when closed while the VM is still coming up", async () => {
    const peer = fakeVm();
    let release: (() => void) | undefined;
    const transport = new VmStdioTransport(
      () => new Promise<GondolinVm>((resolve) => (release = () => resolve(peer.vm))),
      ["node"],
      { cwd: "/", env: {} },
    );
    const starting = transport.start();
    await transport.close();
    release?.();
    await starting;
    expect(peer.execs()).toBe(0);
  });

  it("stops the VM process when closed", async () => {
    const peer = fakeVm();
    const transport = new VmStdioTransport(async () => peer.vm, ["node"], {
      cwd: "/workspace",
      env: {},
    });
    await transport.start();
    expect(peer.signal()?.aborted).toBe(false);
    await transport.close();
    expect(peer.signal()?.aborted).toBe(true);
  });
});

describe("sandbox MCP transports", () => {
  it("connects only picked global servers, never ones other extensions register", () => {
    const createDefaultTransport = vi.fn(() => ({}) as never);
    const vmCalls = vi.fn();
    const options = createSandboxMcpOptions({
      internals: { loadMcpConfig: vi.fn(), createDefaultTransport },
      agentDir: "/agent",
      logPath: "/data/sandbox-mcp-logs/w.log",
      selected: ["picked", "remote"],
      allowedHosts: ["mcp.example.com"],
      guestCwd: "/workspace/w",
      vm: async () => {
        vmCalls();
        return {} as GondolinVm;
      },
    });
    const entry = (
      name: string,
      scope: McpServerEntry["scope"],
      config: McpServerEntry["config"],
    ): McpServerEntry => ({ name, scope, source: "x", config });
    const connect = (value: McpServerEntry) =>
      options.createTransport!(value, "/workspace/w", undefined);

    expect(() => connect(entry("picked", "extension", { command: "node" }))).toThrow("not picked");
    expect(() => connect(entry("other", "global", { command: "node" }))).toThrow("not picked");
    expect(() =>
      connect(entry("remote", "global", { url: "https://evil.test/mcp" } as never)),
    ).toThrow("Allowed Hosts");
    expect(connect(entry("picked", "global", { command: "node" }))).toBeInstanceOf(
      VmStdioTransport,
    );
    connect(entry("remote", "global", { url: "https://mcp.example.com/mcp" } as never));
    expect(createDefaultTransport).toHaveBeenCalledTimes(1);
    expect(vmCalls).not.toHaveBeenCalled();
  });
});

describe("sandbox MCP exposure", () => {
  it("moves codemode exposure to deferred so tool_search reaches every tool", () => {
    const entry = (config: Record<string, unknown>): McpServerEntry =>
      ({ name: "s", scope: "global", source: "x", config }) as unknown as McpServerEntry;
    expect(withoutCodemode(entry({ command: "node" })).config).toMatchObject({
      exposure: "deferred",
    });
    expect(withoutCodemode(entry({ command: "node", exposure: "codemode" })).config).toMatchObject({
      exposure: "deferred",
    });
    const mixed = withoutCodemode(
      entry({
        command: "node",
        exposure: "direct",
        toolExposure: { a: "codemode", b: "hidden", c: "direct" },
      }),
    ).config;
    expect(mixed).toMatchObject({
      exposure: "direct",
      toolExposure: { a: "deferred", b: "hidden", c: "direct" },
    });
  });
});
