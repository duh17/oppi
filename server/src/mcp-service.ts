import { existsSync } from "node:fs";
import { ProjectTrustStore } from "@earendil-works/pi-coding-agent";
import { join } from "node:path";
import type { Workspace } from "./types.js";
import type {
  McpAddServerRequest,
  McpExposure,
  McpPatchServerRequest,
  McpScopeSnapshot,
  McpServersResponse,
  McpServerSummary,
} from "./types/mcp.js";
import type { ProviderAuthLaunchMode } from "./provider-auth/types.js";
import { resolveHostPath } from "./host.js";
import { McpCli, type McpCliProcess } from "./mcp-cli.js";
import { McpAuthManager } from "./mcp-auth.js";
import {
  isRecord,
  McpError,
  MCP_EXPOSURES,
  patchMcpConfig,
  readMcpDocument,
  redactMcpDiagnostic,
  safeMcpConfig,
} from "./mcp-config.js";

interface Scope {
  id: string;
  title: string;
  kind: "global" | "project";
  cwd: string;
  path: string;
}
interface PiReport {
  name: string;
  scope: string;
  state: string;
  tools: string[];
  error?: string;
  toolExposure?: Record<string, McpExposure>;
}
export class McpService {
  private readonly cli: McpCli;
  readonly auth: McpAuthManager;
  private queue: Promise<unknown> = Promise.resolve();
  private pendingOperations = 0;
  private listFlight?: Promise<McpServersResponse>;
  /** Last live probe per scope, served while a sign-in owns Pi's credential store. */
  private readonly lastProbe = new Map<string, McpScopeSnapshot>();
  private readonly children = new Set<McpCliProcess>();
  private disposed = false;
  private disposal?: Promise<void>;
  constructor(
    private readonly options: {
      agentDir: string;
      listWorkspaces: () => Workspace[];
      loginTtlMs?: number;
      /** Upper bound on waiting for killed children during dispose. */
      disposeDeadlineMs?: number;
    },
  ) {
    this.cli = new McpCli(options.agentDir, (child) => {
      this.children.add(child);
      const settled = (): void => {
        this.children.delete(child);
      };
      void child.done.then(settled, settled);
    });
    this.auth = new McpAuthManager(this.cli, options.loginTtlMs);
  }
  private scopes(): Scope[] {
    return [
      {
        id: "global",
        title: "Global",
        kind: "global",
        cwd: this.cli.globalCwd,
        path: join(this.options.agentDir, "mcp.json"),
      },
      ...this.options.listWorkspaces().flatMap((workspace): Scope[] => {
        if (workspace.runtime === "sandbox" || !workspace.hostMount) return [];
        const cwd = resolveHostPath(workspace.hostMount);
        return [
          {
            id: workspace.id,
            title: workspace.name,
            kind: "project",
            cwd,
            path: join(cwd, ".pi", "mcp.json"),
          },
        ];
      }),
    ];
  }
  private scope(id: string): Scope {
    const scope = this.scopes().find((entry) => entry.id === id);
    if (!scope) throw new McpError(404, "Host workspace scope not found");
    return scope;
  }
  private entry(scope: Scope, name: string): Record<string, unknown> {
    const doc = readMcpDocument(scope.path);
    const entries = isRecord(doc.mcpServers) ? doc.mcpServers : {};
    if (!Object.hasOwn(entries, name) || !isRecord(entries[name]))
      throw new McpError(404, "MCP server not found in this scope");
    return entries[name];
  }
  /** Serialize management operations and reject them during login. Scope probes within
   * one refresh run concurrently; independent Pi processes may refresh credentials. */
  private exclusive<T>(operation: () => Promise<T> | T): Promise<T> {
    if (this.disposed) return Promise.reject(new McpError(503, "MCP management is shutting down"));
    // A queued mutation could outlive the phone deadline before its CLI even starts.
    if (this.pendingOperations > 0)
      return Promise.reject(new McpError(409, "MCP management is busy. Retry when it finishes."));
    this.pendingOperations += 1;
    const result = this.queue
      .then(() => {
        if (this.disposed) throw new McpError(503, "MCP management is shutting down");
        if (this.auth.hasActive())
          throw new McpError(409, "Finish or cancel the current MCP sign-in first");
        return operation();
      })
      .finally(() => {
        this.pendingOperations -= 1;
      });
    this.queue = result.catch(() => undefined);
    return result;
  }
  list(): Promise<McpServersResponse> {
    // Pi's login child writes ~/.pi/agent/mcp-auth.json, and a probe may refresh tokens
    // into the same file. Do not run a second writer beside a live sign-in: serve the last
    // live snapshot (config-only rows for scopes never probed) plus the flow to resume.
    const activeSignIn = this.auth.active();
    if (activeSignIn && !this.disposed)
      return Promise.all(
        this.scopes().map((scope) => this.lastProbe.get(scope.id) ?? this.probe(scope, false)),
      ).then((scopes) => ({ scopes, activeSignIn }));
    // Coalesce simultaneous refreshes instead of queuing another 20-second probe.
    // Do not spend the phone's deadline waiting behind an unrelated management operation.
    if (this.listFlight) return this.listFlight;
    if (this.pendingOperations > 0)
      return Promise.reject(
        new McpError(409, "MCP management is busy. Retry refresh when it finishes."),
      );
    this.listFlight = this.exclusive(async () => {
      const scopes = await Promise.all(
        this.scopes().map(async (scope): Promise<McpScopeSnapshot> => {
          // Missing project files remain cheap add targets, never subprocess probes.
          if (scope.kind === "project" && !existsSync(scope.path))
            return {
              id: scope.id,
              title: scope.title,
              kind: scope.kind,
              hasConfig: false,
              trusted: false,
              servers: [],
              errors: [],
            };
          const live = await this.probe(scope, true);
          this.lastProbe.set(scope.id, live);
          return live;
        }),
      );
      return { scopes };
    }).finally(() => {
      this.listFlight = undefined;
    });
    return this.listFlight;
  }
  private async probe(scope: Scope, live: boolean): Promise<McpScopeSnapshot> {
    const snapshot: McpScopeSnapshot = {
      id: scope.id,
      title: scope.title,
      kind: scope.kind,
      hasConfig: existsSync(scope.path),
      trusted:
        scope.kind === "global" ||
        new ProjectTrustStore(this.options.agentDir).get(scope.cwd) === true,
      servers: [],
      errors: [],
    };
    let document: Record<string, unknown>;
    try {
      document = readMcpDocument(scope.path);
    } catch (error) {
      snapshot.errors.push(error instanceof McpError ? error.message : "Could not read mcp.json");
      return snapshot;
    }
    const globalDocument =
      scope.kind === "global"
        ? document
        : (() => {
            try {
              return readMcpDocument(join(this.options.agentDir, "mcp.json"));
            } catch {
              return {};
            }
          })();
    const entries = isRecord(document.mcpServers) ? document.mcpServers : {};
    let reports: PiReport[] = [];
    if (!live) snapshot.errors.push("Live status is paused while a sign-in is in progress.");
    else
      try {
        // Leave room below the iOS 30-second resource deadline for termination and transport.
        const result = await this.cli.run(["list", "--json"], scope.cwd, { timeoutMs: 20_000 });
        const report: unknown = JSON.parse(result.stdout);
        if (!isRecord(report) || !Array.isArray(report.servers) || !Array.isArray(report.errors))
          throw new Error("Invalid Pi response");
        reports = report.servers.filter(
          (item): item is PiReport =>
            isRecord(item) &&
            item.scope === scope.kind &&
            typeof item.name === "string" &&
            typeof item.state === "string" &&
            Array.isArray(item.tools),
        );
        snapshot.trusted = !report.note;
        if (typeof report.note === "string")
          snapshot.note =
            "This project's mcp.json is ignored by Pi until you trust the project on the host. No project commands were run.";
        // JSON parser excerpts can contain credentials; never echo them to the phone.
        snapshot.errors = report.errors.map((error) =>
          typeof error === "string" &&
          !/JSON|Unexpected token|position|line \d+ column/i.test(error)
            ? redactMcpDiagnostic(error, [document, globalDocument])
            : "Invalid mcp.json. Check the config on the host.",
        );
      } catch (error) {
        snapshot.errors.push(
          error instanceof McpError && error.statusCode === 504
            ? "This scope's live probe timed out after 20 seconds. Other scopes still refreshed."
            : "Pi could not probe this scope. Check its path and MCP configuration on the host.",
        );
      }
    snapshot.servers = Object.entries(entries).flatMap(([name, config]): McpServerSummary[] => {
      if (!isRecord(config)) return [];
      const report = reports.find((item) => item.name === name);
      const enabled = config.enabled !== false;
      const exposure = MCP_EXPOSURES.includes(config.exposure as McpExposure)
        ? (config.exposure as McpExposure)
        : "codemode";
      return [
        {
          name,
          transport: typeof config.url === "string" ? "http" : "stdio",
          config: safeMcpConfig(config),
          enabled,
          exposure,
          state:
            report?.state ??
            (!enabled ? "disabled" : snapshot.note ? "untrusted" : live ? "failed" : "unknown"),
          tools: report?.tools ?? [],
          toolExposure: report?.toolExposure,
          error: report?.error
            ? redactMcpDiagnostic(report.error, [document, globalDocument])
            : undefined,
          supportsOAuth:
            typeof config.url === "string" &&
            !Object.keys(isRecord(config.headers) ? config.headers : {}).some(
              (key) => key.toLowerCase() === "authorization",
            ),
        },
      ];
    });
    return snapshot;
  }
  add(input: McpAddServerRequest): Promise<void> {
    return this.exclusive(async () => {
      if (!isRecord(input)) throw new McpError(400, "Expected an MCP server object");
      const allowed = new Set([
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
      if (Object.keys(input).some((key) => !allowed.has(key)))
        throw new McpError(400, "Unexpected server field");
      if (
        typeof input.name !== "string" ||
        !/^[A-Za-z0-9_-]+$/.test(input.name) ||
        ["__proto__", "constructor", "prototype", "--help", "-h"].includes(input.name)
      )
        throw new McpError(
          400,
          "Use letters, digits, underscores, and hyphens for the server name",
        );
      const scope = this.scope(input.scopeId);
      const doc = readMcpDocument(scope.path);
      if (isRecord(doc.mcpServers) && Object.hasOwn(doc.mcpServers, input.name))
        throw new McpError(
          409,
          "A server with this name already exists in this scope. Remove it before adding a replacement.",
        );
      const args = ["add", ...(scope.kind === "project" ? ["--local"] : [])];
      const option = (key: string, value: unknown): void => {
        if (value === undefined) return;
        if (
          typeof value !== "string" ||
          value.includes("\0") ||
          value === "--help" ||
          value === "-h"
        )
          throw new McpError(400, `Invalid ${key}`);
        args.push(key, value);
      };
      const pairs = (key: string, values: unknown): void => {
        if (values === undefined) return;
        if (
          !isRecord(values) ||
          Object.keys(values).some((name) => !name || name.includes("=") || name.includes("\0"))
        )
          throw new McpError(400, `Invalid ${key} keys`);
        for (const [name, value] of Object.entries(values)) {
          if (typeof value !== "string") throw new McpError(400, `Invalid ${key} value`);
          option(key, `${name}=${value}`);
        }
      };
      if ((input.url === undefined) === (input.command === undefined))
        throw new McpError(400, "Choose a URL or a command, not both");
      if (input.url !== undefined) {
        if (input.args !== undefined || input.env !== undefined || input.cwd !== undefined)
          throw new McpError(400, "Command options cannot be used for a URL server");
        option("--url", input.url);
        pairs("--header", input.headers);
        if (input.oauth !== undefined) {
          if (
            !isRecord(input.oauth) ||
            Object.keys(input.oauth).some(
              (key) => !["clientId", "clientSecret", "callbackPort"].includes(key),
            )
          )
            throw new McpError(400, "Invalid OAuth options");
          option("--oauth-client-id", input.oauth.clientId);
          option("--oauth-client-secret", input.oauth.clientSecret);
          if (input.oauth.callbackPort !== undefined) {
            if (
              !Number.isInteger(input.oauth.callbackPort) ||
              input.oauth.callbackPort < 1 ||
              input.oauth.callbackPort > 65535
            )
              throw new McpError(400, "Invalid callback port");
            option("--oauth-callback-port", String(input.oauth.callbackPort));
          }
        }
      } else {
        if (input.headers !== undefined || input.oauth !== undefined)
          throw new McpError(400, "HTTP options cannot be used for a command server");
        if (
          typeof input.command !== "string" ||
          !input.command.trim() ||
          input.command.includes("\0") ||
          ["--help", "-h"].includes(input.command)
        )
          throw new McpError(400, "Invalid command");
        if (
          input.args !== undefined &&
          (!Array.isArray(input.args) ||
            input.args.some(
              (value) =>
                typeof value !== "string" ||
                value.includes("\0") ||
                ["--help", "-h"].includes(value),
            ))
        )
          throw new McpError(400, "Invalid command arguments");
        option("--cwd", input.cwd);
        pairs("--env", input.env);
      }
      if (input.exposure !== undefined && !MCP_EXPOSURES.includes(input.exposure))
        throw new McpError(400, "Invalid exposure");
      option("--exposure", input.exposure === "codemode" ? undefined : input.exposure);
      args.push(
        "--",
        input.name,
        ...(input.command === undefined ? [] : [input.command, ...(input.args ?? [])]),
      );
      const result = await this.cli.run(args, scope.cwd, { timeoutMs: 20_000 });
      if (result.code !== 0)
        throw new McpError(
          422,
          "Pi rejected this MCP configuration. Check the URL, command, and options.",
        );
    });
  }
  patch(scopeId: string, name: string, patch: McpPatchServerRequest): Promise<void> {
    return this.exclusive(() => {
      if (
        !isRecord(patch) ||
        !Object.keys(patch).length ||
        Object.keys(patch).some((key) => !["enabled", "exposure"].includes(key)) ||
        (patch.enabled !== undefined && typeof patch.enabled !== "boolean") ||
        (patch.exposure !== undefined &&
          (typeof patch.exposure !== "string" ||
            !MCP_EXPOSURES.includes(patch.exposure as McpExposure)))
      )
        throw new McpError(400, "Expected enabled and/or a valid exposure");
      const scope = this.scope(scopeId);
      this.entry(scope, name);
      patchMcpConfig(scope.path, name, patch);
    });
  }
  remove(scopeId: string, name: string): Promise<void> {
    return this.exclusive(async () => {
      const scope = this.scope(scopeId);
      this.entry(scope, name);
      const result = await this.cli.run(
        ["remove", ...(scope.kind === "project" ? ["--local"] : []), "--", name],
        scope.cwd,
        { timeoutMs: 20_000 },
      );
      if (result.code !== 0) throw new McpError(422, "Pi could not remove the MCP server");
    });
  }
  login(
    scopeId: string,
    name: string,
    mode: ProviderAuthLaunchMode,
  ): Promise<ReturnType<McpAuthManager["start"]>> {
    return this.exclusive(() => {
      if (!["phone_browser", "server_browser", "none"].includes(mode))
        throw new McpError(400, "Invalid launchMode");
      const scope = this.scope(scopeId);
      this.entry(scope, name);
      // Match pi mcp login: trust is a saved decision for this cwd, not the
      // outcome of connecting every sibling server in the scope.
      if (
        scope.kind === "project" &&
        new ProjectTrustStore(this.options.agentDir).get(scope.cwd) !== true
      )
        throw new McpError(
          409,
          "Trust this project in Pi on the host before signing in to its MCP servers.",
        );
      return this.auth.start(scopeId, name, scope.cwd, mode);
    });
  }
  logout(scopeId: string, name: string): Promise<void> {
    return this.exclusive(async () => {
      const scope = this.scope(scopeId);
      this.entry(scope, name);
      const result = await this.cli.run(["logout", "--", name], scope.cwd, { timeoutMs: 20_000 });
      if (result.code !== 0)
        throw new McpError(
          422,
          "Pi could not sign out. Check project trust and OAuth configuration.",
        );
    });
  }
  dispose(): Promise<void> {
    if (this.disposal) return this.disposal;
    this.disposed = true;
    // Shutdown must not depend on a grace timer surviving process exit. This
    // includes probes/mutations as well as OAuth children from the same CLI.
    const children = [...this.children];
    for (const child of children) child.stop(true);
    this.auth.dispose();
    // SIGKILL is already sent; a child that cannot be reaped must not stall shutdown.
    let timer: NodeJS.Timeout | undefined;
    const deadline = new Promise<void>((resolve) => {
      timer = setTimeout(resolve, this.options.disposeDeadlineMs ?? 3000);
    });
    const settled = Promise.allSettled(children.map((child) => child.done)).then(() => {});
    this.disposal = Promise.race([settled, deadline]).finally(() => clearTimeout(timer));
    return this.disposal;
  }
}
