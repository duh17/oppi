/**
 * MCP for sandbox workspaces.
 *
 * A sandbox session's Pi agent runs in this host process; only its tools run in the
 * Gondolin VM. Pi's MCP extension would therefore spawn stdio servers on the host, call
 * HTTP servers outside Allowed Hosts, and fill `${NAME}` from host secrets. This module
 * supplies the extension's `loadConfig` and `createTransport` so that:
 *
 * - only global servers the owner picked for the workspace load (never the project
 *   `.pi/mcp.json`, nor servers other extensions register);
 * - HTTP servers connect from the host only when the URL host is in Allowed Hosts, and a
 *   private or local host only when listed exactly; OAuth and `${NAME}` headers resolve on
 *   the host (the agent sees tool results only);
 * - stdio servers run inside the VM, and never receive host secret references.
 */
import { isIP } from "node:net";
import { dirname, join, posix } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import type {
  LoadedMcpConfig,
  McpExtensionOptions,
  McpServerEntry,
  McpTransportFactory,
} from "@earendil-works/pi-coding-agent";
import type { GondolinProcess, GondolinVm } from "./gondolin-ops.js";

type McpTransport = ReturnType<McpTransportFactory>;
type JsonRpcMessage = Parameters<McpTransport["send"]>[0];
type Listener<T extends unknown[]> = (...args: T) => void;

/** Same semantics as Gondolin's Allowed Hosts: unset allows all, `*` globs, case-insensitive. */
export function matchesAllowedHost(hostname: string, allowedHosts: string[] | undefined): boolean {
  if (allowedHosts === undefined) return true;
  const host = hostname.toLowerCase();
  return allowedHosts.some((pattern) => {
    const trimmed = pattern.trim();
    if (!trimmed) return false;
    if (trimmed === "*") return true;
    const escaped = trimmed
      .split("*")
      .map((part) => part.replace(/[.+?^${}()|[\]\\]/g, "\\$&"))
      .join(".*");
    return new RegExp(`^${escaped}$`, "i").test(host);
  });
}

function ipv4InRange(ip: string, base: string, bits: number): boolean {
  const toInt = (value: string): number =>
    value.split(".").reduce((sum, octet) => sum * 256 + Number(octet), 0);
  const mask = bits === 0 ? 0 : 2 ** 32 - 2 ** (32 - bits);
  return (toInt(ip) & mask) >>> 0 === (toInt(base) & mask) >>> 0;
}

/**
 * Hosts the VM itself cannot reach (Gondolin blocks internal ranges) but this host can:
 * loopback, private, link-local, CGNAT/tailnet, and local-only names. A name that only
 * resolves to such an address is not caught here.
 */
export function isPrivateHost(hostname: string): boolean {
  // A trailing dot (`localhost.`) names the same host.
  const host = hostname
    .toLowerCase()
    .replace(/^\[|\]$/g, "")
    .replace(/\.+$/, "");
  if (host === "localhost" || /\.(localhost|local|internal|home\.arpa|ts\.net)$/.test(host))
    return true;
  if (isIP(host) === 4) return isPrivateIpv4(host);
  if (isIP(host) !== 6) return false;
  const groups = expandIpv6(host);
  // IPv4-mapped (::ffff:a.b.c.d), IPv4-compatible (::a.b.c.d), and NAT64 (64:ff9b::/96)
  // carry an IPv4 address in the low 32 bits, however the URL parser spelled it.
  const embedded = `${groups[6] >> 8}.${groups[6] & 255}.${groups[7] >> 8}.${groups[7] & 255}`;
  const high = groups.slice(0, 5);
  if (high.every((group) => group === 0) && (groups[5] === 0xffff || groups[5] === 0))
    return groups[5] === 0 && groups[6] === 0 ? groups[7] <= 1 : isPrivateIpv4(embedded);
  if (groups[0] === 0x64 && groups[1] === 0xff9b && groups.slice(2, 6).every((g) => g === 0))
    return isPrivateIpv4(embedded);
  // Unique local fc00::/7, link-local fe80::/10, and deprecated site-local fec0::/10.
  return (
    (groups[0] & 0xfe00) === 0xfc00 ||
    (groups[0] & 0xffc0) === 0xfe80 ||
    (groups[0] & 0xffc0) === 0xfec0
  );
}

function isPrivateIpv4(ip: string): boolean {
  return (
    [
      ["0.0.0.0", 8],
      ["10.0.0.0", 8],
      ["100.64.0.0", 10],
      ["127.0.0.0", 8],
      ["169.254.0.0", 16],
      ["172.16.0.0", 12],
      ["192.168.0.0", 16],
    ] as const
  ).some(([base, bits]) => ipv4InRange(ip, base, bits));
}

/** Eight 16-bit groups of a valid IPv6 address, including a dotted-quad tail. */
function expandIpv6(address: string): number[] {
  let text = address;
  const quad = text.match(/(\d+\.\d+\.\d+\.\d+)$/);
  if (quad) {
    const [a, b, c, d] = quad[1].split(".").map(Number);
    text =
      text.slice(0, -quad[1].length) +
      `${((a << 8) | b).toString(16)}:${((c << 8) | d).toString(16)}`;
  }
  const [head, tail] = text.split("::");
  const parse = (part: string | undefined): number[] =>
    part ? part.split(":").map((group) => parseInt(group, 16)) : [];
  const left = parse(head);
  const right = parse(tail);
  return tail === undefined
    ? left
    : [...left, ...Array<number>(8 - left.length - right.length).fill(0), ...right];
}

/** Why a server cannot load in this sandbox, or undefined when it can. */
export function sandboxMcpBlockReason(
  config: Record<string, unknown>,
  allowedHosts: string[] | undefined,
): string | undefined {
  if (typeof config.url === "string") {
    let host: string;
    try {
      // IPv6 hostnames come bracketed (`[::1]`); Allowed Hosts lists them bare.
      host = new URL(config.url).hostname.replace(/^\[|\]$/g, "");
    } catch {
      return "Its URL is not valid.";
    }
    if (!matchesAllowedHost(host, allowedHosts))
      return `${host} is not in this workspace's Allowed Hosts.`;
    // The host process can reach what the VM cannot; require an exact, deliberate entry.
    if (
      isPrivateHost(host) &&
      !allowedHosts?.some((pattern) => pattern.trim().toLowerCase() === host.toLowerCase())
    )
      return `${host} is a private or local address. List it exactly in Allowed Hosts to allow it.`;
    return undefined;
  }
  const env =
    config.env && typeof config.env === "object" && !Array.isArray(config.env)
      ? Object.values(config.env)
      : [];
  // Pi resolves `$NAME`, `${NAME}`, and `!command` from the host. Pass literals only.
  if (
    env.some((value) => typeof value === "string" && (value.includes("$") || value.startsWith("!")))
  )
    return "Its environment uses host secret references ($NAME or !command), which never enter the sandbox.";
  return undefined;
}

interface PiMcpInternals {
  loadMcpConfig: (options: {
    agentDir: string;
    cwd: string;
    projectTrusted: boolean;
  }) => LoadedMcpConfig;
  createDefaultTransport: McpTransportFactory;
}

/**
 * Pi's own config loader and default transports are not package exports. Load them from
 * Pi's installed dist (as `pi-global-config.ts` and `mcp-cli.ts` do) so validation and the
 * HTTP/OAuth transport stay Pi's, not a second copy. Same file URLs as Pi's lazy loader,
 * so the module instances (and their error classes) are shared.
 */
export async function loadPiMcpInternals(): Promise<PiMcpInternals> {
  const dist = dirname(fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent")));
  const load = (path: string): Promise<Record<string, unknown>> =>
    import(pathToFileURL(join(dist, path)).href) as Promise<Record<string, unknown>>;
  const [config, runtime] = await Promise.all([
    load("extensions/mcp/config.js"),
    load("extensions/mcp/runtime.js"),
  ]);
  if (
    typeof config.loadMcpConfig !== "function" ||
    typeof runtime.createDefaultTransport !== "function"
  )
    throw new Error("Pi's MCP config/runtime modules moved; update sandbox-mcp.ts");
  return {
    loadMcpConfig: config.loadMcpConfig as PiMcpInternals["loadMcpConfig"],
    createDefaultTransport: runtime.createDefaultTransport as McpTransportFactory,
  };
}

/** One newline-delimited JSON-RPC peer running inside the workspace VM. */
export class VmStdioTransport implements McpTransport {
  /** Pi's own stdio transport caps a message at 16 MiB. */
  static readonly maxMessageBytes = 16 * 1024 * 1024;
  private process?: GondolinProcess;
  private readonly abort = new AbortController();
  /** Bytes, so a multi-byte character split across chunks decodes intact. */
  private pending: Buffer[] = [];
  private pendingBytes = 0;
  private stderrTail = "";
  /** Set when this side stops the peer; the exec's abort rejection is then expected. */
  private stopped = false;
  private closed = false;
  private readonly messageListeners = new Set<Listener<[JsonRpcMessage]>>();
  private readonly errorListeners = new Set<Listener<[Error]>>();
  private readonly closeListeners = new Set<Listener<[]>>();

  constructor(
    private readonly vm: () => Promise<GondolinVm>,
    private readonly argv: string[],
    private readonly options: { cwd: string; env: Record<string, string> },
  ) {}

  async start(): Promise<void> {
    if (this.process) throw new Error("Transport already started");
    const vm = await this.vm();
    // Closed while waiting for the VM: never start a peer nobody will stop.
    if (this.stopped) return;
    const proc = vm.exec(this.argv, {
      cwd: this.options.cwd,
      env: this.options.env,
      signal: this.abort.signal,
      stdin: true,
      stdout: "pipe",
      stderr: "pipe",
    });
    this.process = proc;
    // Gondolin rejects an aborted exec. An unhandled rejection stops the whole server, so
    // mark it handled here; `pump` reads the outcome.
    Promise.resolve(proc).catch(() => undefined);
    void this.pump(proc).catch(() => this.finish());
  }

  async send(message: JsonRpcMessage): Promise<void> {
    if (!this.process || this.stopped) throw new Error("Transport is not running");
    this.process.write(JSON.stringify(message) + "\n");
  }

  async close(): Promise<void> {
    this.stop();
    this.finish();
  }

  onMessage(listener: Listener<[JsonRpcMessage]>): () => void {
    this.messageListeners.add(listener);
    return () => this.messageListeners.delete(listener);
  }
  onError(listener: Listener<[Error]>): () => void {
    this.errorListeners.add(listener);
    return () => this.errorListeners.delete(listener);
  }
  onClose(listener: Listener<[]>): () => void {
    this.closeListeners.add(listener);
    return () => this.closeListeners.delete(listener);
  }

  private stop(): void {
    if (this.stopped) return;
    this.stopped = true;
    try {
      this.process?.end();
    } catch {
      // The peer may already be gone.
    }
    this.abort.abort();
  }

  private async pump(proc: GondolinProcess): Promise<void> {
    try {
      for await (const chunk of proc.output()) {
        if (chunk.stream === "stderr") {
          this.stderrTail = (this.stderrTail + chunk.data.toString("utf8")).slice(-2000);
          continue;
        }
        // Buffered chunks hold no newline, so only a chunk with one completes a line; join
        // the pieces once then, never per chunk.
        let oversized = false;
        const firstNewline = chunk.data.indexOf(0x0a);
        if (firstNewline < 0) {
          this.pending.push(chunk.data);
          this.pendingBytes += chunk.data.length;
          oversized = this.pendingBytes > VmStdioTransport.maxMessageBytes;
        } else {
          const data = Buffer.concat([...this.pending, chunk.data]);
          let start = 0;
          let newline = this.pendingBytes + firstNewline;
          while (newline >= 0 && !this.stopped) {
            if (newline - start > VmStdioTransport.maxMessageBytes) {
              oversized = true;
              break;
            }
            const line = data.subarray(start, newline).toString("utf8").trim();
            if (line) this.deliver(line);
            start = newline + 1;
            newline = data.indexOf(0x0a, start);
          }
          const rest = data.subarray(start);
          this.pending = rest.length ? [rest] : [];
          this.pendingBytes = rest.length;
          oversized ||= this.pendingBytes > VmStdioTransport.maxMessageBytes;
        }
        // A listener may have closed the transport mid-chunk.
        if (this.stopped) break;
        if (oversized) {
          this.emitError(new Error("MCP message from the sandbox exceeded 16 MiB"));
          this.stop();
          break;
        }
      }
      const result = await proc;
      if (!this.stopped && result.exitCode !== 0)
        this.emitError(
          new Error(
            `Sandboxed MCP server exited with code ${result.exitCode}` +
              (this.stderrTail.trim() ? `: ${this.stderrTail.trim()}` : ""),
          ),
        );
    } catch (error) {
      if (!this.stopped) this.emitError(error instanceof Error ? error : new Error(String(error)));
    }
    this.finish();
  }

  private deliver(line: string): void {
    let message: JsonRpcMessage;
    try {
      message = JSON.parse(line) as JsonRpcMessage;
    } catch {
      this.emitError(new Error("The sandboxed MCP server wrote a line that is not JSON"));
      return;
    }
    for (const listener of this.messageListeners) {
      try {
        listener(message);
      } catch (error) {
        this.emitError(error instanceof Error ? error : new Error(String(error)));
      }
    }
  }

  private emitError(error: Error): void {
    for (const listener of this.errorListeners) {
      try {
        listener(error);
      } catch {
        // A failing error listener must not stop the pump.
      }
    }
  }

  private finish(): void {
    if (this.closed) return;
    this.closed = true;
    for (const listener of this.closeListeners) {
      try {
        listener();
      } catch {
        // Every close listener still runs.
      }
    }
  }
}

type SandboxMcpOptions = Pick<McpExtensionOptions, "loadConfig" | "createTransport">;

/** No picks: load nothing, so Pi's default loader never reads host or project config. */
export const EMPTY_SANDBOX_MCP: SandboxMcpOptions = {
  loadConfig: () => ({ servers: [], errors: [] }),
  createTransport: (entry) => {
    throw new Error(`MCP server "${entry.name}" is not picked for this sandbox`);
  },
};

/**
 * `loadConfig` and `createTransport` for Pi's MCP extension in a sandbox session.
 * `vm` returns this session's VM; it never re-creates one with other settings.
 */
export function createSandboxMcpOptions(input: {
  internals: PiMcpInternals;
  agentDir: string;
  selected: readonly string[];
  allowedHosts: string[] | undefined;
  guestCwd: string;
  vm: () => Promise<GondolinVm>;
}): SandboxMcpOptions {
  const selected = new Set(input.selected);
  const blockReason = (entry: McpServerEntry): string | undefined =>
    sandboxMcpBlockReason({ ...entry.config }, input.allowedHosts);
  return {
    loadConfig: (ctx) => {
      // Global file only: the project file lives in the workspace.
      const loaded = input.internals.loadMcpConfig({
        agentDir: input.agentDir,
        cwd: ctx.cwd,
        projectTrusted: false,
      });
      const errors = [...loaded.errors];
      const servers = loaded.servers.filter((entry) => {
        if (!selected.has(entry.name)) return false;
        const reason = blockReason(entry);
        if (reason) errors.push(`MCP server "${entry.name}" is blocked in this sandbox: ${reason}`);
        return !reason;
      });
      for (const name of selected)
        if (!loaded.servers.some((entry) => entry.name === name))
          errors.push(`MCP server "${name}" is selected for this sandbox but not in mcp.json.`);
      return { ...loaded, servers, errors };
    },
    createTransport: (entry, cwd, authProvider) => {
      // Pi also connects servers other extensions register; only picked global ones run.
      if (entry.scope !== "global" || !selected.has(entry.name))
        throw new Error(`MCP server "${entry.name}" is not picked for this sandbox`);
      const reason = blockReason(entry);
      if (reason)
        throw new Error(`MCP server "${entry.name}" is blocked in this sandbox: ${reason}`);
      const config = entry.config as {
        url?: string;
        command?: string;
        args?: string[];
        cwd?: string;
        env?: Record<string, string>;
      };
      if (typeof config.url === "string")
        return input.internals.createDefaultTransport(entry, cwd, authProvider);
      return new VmStdioTransport(input.vm, [config.command ?? "", ...(config.args ?? [])], {
        cwd: posix.resolve(input.guestCwd, config.cwd ?? "."),
        env: config.env ?? {},
      });
    },
  };
}
