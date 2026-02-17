/**
 * Auth-injecting reverse proxy for container API access.
 *
 * Real API credentials never enter containers. Containers send requests
 * with placeholder tokens, and this proxy replaces them with real credentials
 * from the host's auth.json before forwarding to upstream APIs.
 *
 * Per-provider credential stubs:
 *   Anthropic:    api_key "sk-ant-oat01-proxy-<sessionId>" (OAuth-shaped)
 *                 → proxy injects real OAuth Bearer
 *   OpenAI-Codex: api_key "<fake-jwt>" → fake JWT embeds session ID + real account ID
 *                 (SDK extracts chatgpt_account_id from fake JWT successfully,
 *                  proxy swaps Authorization header with real JWT)
 *
 * Flow:
 *   Container → HTTP (placeholder auth) → Auth Proxy
 *     → extract session ID from placeholder
 *     → validate session is registered
 *     → read real credential from host auth.json
 *     → inject real auth headers
 *     → HTTPS → upstream API
 */

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { request as httpsRequest } from "node:https";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

// ─── Constants ───

export const AUTH_PROXY_PORT = 7751;
const ANTHROPIC_OAUTH_STUB_PREFIX = "sk-ant-oat01-proxy-";

function resolveAuthProxyPort(explicitPort?: number): number {
  if (
    Number.isInteger(explicitPort)
    && (explicitPort ?? 0) > 0
    && (explicitPort ?? 0) <= 65_535
  ) {
    return explicitPort as number;
  }

  const raw = process.env.OPPI_AUTH_PROXY_PORT;
  if (raw && raw.trim().length > 0) {
    const parsed = Number.parseInt(raw, 10);
    if (Number.isInteger(parsed) && parsed > 0 && parsed <= 65_535) {
      return parsed;
    }

    console.warn(
      `[auth-proxy] Invalid OPPI_AUTH_PROXY_PORT="${raw}"; using default ${AUTH_PROXY_PORT}`,
    );
  }

  return AUTH_PROXY_PORT;
}

/**
 * OAuth beta headers required by Anthropic for Claude Code auth flow.
 * Added/merged by the proxy to guarantee required OAuth betas are present.
 */
const ANTHROPIC_OAUTH_BETAS = ["claude-code-20250219", "oauth-2025-04-20"];

/** JWT claim path where OpenAI stores the account ID. */
const OPENAI_AUTH_CLAIM = "https://api.openai.com/auth";

// ─── JWT Utilities ───

/** Decode a JWT payload without signature verification. */
function decodeJwtPayload(token: string): Record<string, unknown> | null {
  try {
    const parts = token.split(".");
    if (parts.length !== 3) return null;
    return JSON.parse(Buffer.from(parts[1], "base64").toString("utf-8"));
  } catch {
    return null;
  }
}

/**
 * Build a fake JWT that carries session ID and account ID.
 *
 * The container's openai-codex SDK calls extractAccountId(token) which
 * parses the JWT payload. Our fake JWT satisfies that parser while being
 * obviously unusable as a real credential (alg: "none", no real signature).
 */
function buildFakeJwt(sessionId: string, accountId: string): string {
  const header = Buffer.from(JSON.stringify({ alg: "none" })).toString("base64");
  const payload = Buffer.from(
    JSON.stringify({
      [OPENAI_AUTH_CLAIM]: { chatgpt_account_id: accountId },
      oppi_session: sessionId,
    }),
  ).toString("base64");
  return `${header}.${payload}.placeholder`;
}

/** Extract chatgpt_account_id from a real OpenAI JWT. */
function extractAccountId(jwt: string): string | null {
  const payload = decodeJwtPayload(jwt);
  const auth = payload?.[OPENAI_AUTH_CLAIM] as Record<string, unknown> | undefined;
  const id = auth?.chatgpt_account_id;
  return typeof id === "string" && id.length > 0 ? id : null;
}

/** Extract bearer token value from an Authorization header. */
function getBearerToken(authHeader: string | undefined): string | null {
  if (!authHeader?.startsWith("Bearer ")) return null;
  return authHeader.slice(7);
}

// ─── Provider Routes ───

export interface ProviderRoute {
  /** URL prefix that triggers this route (e.g., "/anthropic") */
  prefix: string;
  /** Auth.json credential key (e.g., "anthropic", "openai-codex") */
  authKey: string;
  /** Upstream base URL */
  upstream: string;
  /** Extract session ID from the incoming request headers. */
  extractSessionId: (headers: Record<string, string>) => string | null;
  /** Inject real auth headers, replacing the placeholder. */
  injectAuth: (token: string, headers: Record<string, string>) => void;
  /** Build the stub credential for the container's auth.json. */
  buildStubCredential: (
    sessionId: string,
    realCredential: Record<string, unknown>,
  ) => Record<string, unknown>;
}

export const ROUTES: ProviderRoute[] = [
  {
    prefix: "/anthropic",
    authKey: "anthropic",
    upstream: "https://api.anthropic.com",

    extractSessionId(headers: Record<string, string>): string | null {
      const bearer = getBearerToken(headers["authorization"]);
      if (bearer?.startsWith(ANTHROPIC_OAUTH_STUB_PREFIX)) {
        return bearer.slice(ANTHROPIC_OAUTH_STUB_PREFIX.length);
      }
      return null;
    },

    injectAuth(token: string, headers: Record<string, string>): void {
      headers["authorization"] = `Bearer ${token}`;

      // Merge OAuth-required beta headers with existing ones from the SDK
      const existing =
        headers["anthropic-beta"]
          ?.split(",")
          .map((s) => s.trim())
          .filter(Boolean) ?? [];
      const merged = [...new Set([...ANTHROPIC_OAUTH_BETAS, ...existing])];
      headers["anthropic-beta"] = merged.join(",");

      // Claude Code identity headers (Anthropic expects these for OAuth)
      headers["user-agent"] = "claude-cli/2.1.2 (external, cli)";
      headers["x-app"] = "cli";
    },

    buildStubCredential(sessionId: string): Record<string, unknown> {
      // Must look like a real Anthropic OAuth token so pi uses OAuth codepath.
      // Session ID is embedded for proxy-side lookup.
      return { type: "api_key", key: `${ANTHROPIC_OAUTH_STUB_PREFIX}${sessionId}` };
    },
  },
  {
    prefix: "/openai-codex",
    authKey: "openai-codex",
    upstream: "https://chatgpt.com/backend-api",

    extractSessionId(headers: Record<string, string>): string | null {
      const auth = headers["authorization"];
      if (!auth?.startsWith("Bearer ")) return null;
      const payload = decodeJwtPayload(auth.slice(7));
      return typeof payload?.oppi_session === "string" ? payload.oppi_session : null;
    },

    injectAuth(token: string, headers: Record<string, string>): void {
      // Replace fake JWT with real one.
      // All other headers (chatgpt-account-id, OpenAI-Beta, originator,
      // User-Agent) are already correct — built by the container SDK
      // using the account ID from the fake JWT payload.
      headers["authorization"] = `Bearer ${token}`;
    },

    buildStubCredential(
      sessionId: string,
      realCred: Record<string, unknown>,
    ): Record<string, unknown> {
      const realJwt = (realCred.access ?? "") as string;
      const accountId = extractAccountId(realJwt) ?? "unknown";
      return { type: "api_key", key: buildFakeJwt(sessionId, accountId) };
    },
  },
];

/**
 * Resolve full upstream URL while preserving any upstream base path prefix.
 *
 * Example:
 *   upstreamBase: https://chatgpt.com/backend-api
 *   routePrefix:  /openai-codex
 *   incoming:     /openai-codex/codex/responses?x=1
 *   result:       https://chatgpt.com/backend-api/codex/responses?x=1
 */
export function buildUpstreamUrl(upstreamBase: string, routePrefix: string, incoming: URL): URL {
  const upstream = new URL(upstreamBase);

  const pathAfterPrefix = incoming.pathname.slice(routePrefix.length).replace(/^\/+/, "");

  const basePath = upstream.pathname.replace(/\/+$/, "");
  upstream.pathname =
    pathAfterPrefix.length > 0
      ? `${basePath}/${pathAfterPrefix}`.replace(/\/{2,}/g, "/")
      : basePath || "/";

  upstream.search = incoming.search;
  return upstream;
}

// ─── Types ───

interface SessionEntry {
  providers: Set<string>;
}

interface AuthCredential {
  type: "oauth" | "api_key";
  access?: string;
  key?: string;
  expires?: number;
}

/** Hop-by-hop headers that must not be forwarded. */
const HOP_BY_HOP = new Set(["host", "connection", "transfer-encoding", "keep-alive", "upgrade"]);

// ─── Auth Proxy ───

export class AuthProxy {
  private sessions = new Map<string, SessionEntry>();
  private server: ReturnType<typeof createServer>;
  private authPath: string;
  private authData: Record<string, AuthCredential> = {};
  private lastAuthLoad = 0;
  private readonly authCacheTtlMs = 5_000;

  readonly port: number;
  readonly host: string;

  constructor(opts?: { port?: number; host?: string; authPath?: string }) {
    this.port = resolveAuthProxyPort(opts?.port);
    this.host = opts?.host ?? "0.0.0.0";
    this.authPath = opts?.authPath ?? join(homedir(), ".pi", "agent", "auth.json");
    this.server = createServer((req, res) => void this.handleRequest(req, res));
  }

  // ─── Lifecycle ───

  async start(): Promise<void> {
    this.loadAuth();
    return new Promise((resolve, reject) => {
      this.server.listen(this.port, this.host, () => {
        console.log(`[auth-proxy] Listening on ${this.host}:${this.port}`);
        resolve();
      });
      this.server.on("error", reject);
    });
  }

  async stop(): Promise<void> {
    this.sessions.clear();
    return new Promise((resolve) => {
      this.server.close(() => resolve());
    });
  }

  // ─── Session Registry ───

  registerSession(sessionId: string, providers?: string[]): void {
    const providerSet = new Set(providers ?? this.getHostProviders());
    this.sessions.set(sessionId, { providers: providerSet });
    console.log(`[auth-proxy] Session registered: ${sessionId} (${[...providerSet].join(", ")})`);
  }

  removeSession(sessionId: string): void {
    if (this.sessions.delete(sessionId)) {
      console.log(`[auth-proxy] Session removed: ${sessionId}`);
    }
  }

  // ─── Provider Queries ───

  /** All providers with credentials in host auth.json. */
  getHostProviders(): string[] {
    this.ensureAuthLoaded();
    return Object.keys(this.authData);
  }

  /** All providers that have a proxy route. */
  getProxiedProviders(): string[] {
    this.ensureAuthLoaded();
    return ROUTES.filter((r) => r.authKey in this.authData).map((r) => r.authKey);
  }

  /** Get the proxy baseUrl for a provider (for models.json override). */
  getProviderProxyUrl(authKey: string, hostGateway: string): string | undefined {
    const route = ROUTES.find((r) => r.authKey === authKey);
    if (!route) return undefined;
    return `http://${hostGateway}:${this.port}${route.prefix}`;
  }

  /**
   * Build stub auth.json entries for all proxied providers.
   *
   * Each provider's route defines how to build its stub credential:
   * - Anthropic: OAuth-shaped placeholder "sk-ant-oat01-proxy-<sessionId>"
   * - OpenAI-Codex: fake JWT with real account ID + embedded session ID
   */
  buildStubAuth(sessionId: string): Record<string, unknown> {
    this.ensureAuthLoaded();
    const stub: Record<string, unknown> = {};
    for (const route of ROUTES) {
      const cred = this.authData[route.authKey];
      if (!cred) continue;
      stub[route.authKey] = route.buildStubCredential(
        sessionId,
        cred as unknown as Record<string, unknown>,
      );
    }
    return stub;
  }

  // ─── Request Handler ───

  private async handleRequest(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const requestUrl = new URL(req.url || "/", "http://oppi-server-auth-proxy.local");

    if (requestUrl.pathname === "/health") {
      this.sendJson(res, 200, { ok: true, sessions: this.sessions.size });
      return;
    }

    const route = ROUTES.find((r) => requestUrl.pathname.startsWith(r.prefix));
    if (!route) {
      console.warn(`[auth-proxy] Unknown provider route: ${requestUrl.pathname}`);
      this.sendError(res, 404, "Unknown provider route");
      return;
    }

    this.handleRoute(req, res, route, requestUrl);
  }

  private handleRoute(
    req: IncomingMessage,
    res: ServerResponse,
    route: ProviderRoute,
    requestUrl: URL,
  ): void {
    const headers = this.copyHeaders(req);

    // Extract session ID from the request (provider-specific)
    const sessionId = route.extractSessionId(headers);
    if (!sessionId) {
      this.sendError(res, 401, "Missing or invalid session token");
      return;
    }

    const session = this.sessions.get(sessionId);
    if (!session) {
      this.sendError(res, 403, `Session not registered: ${sessionId}`);
      return;
    }

    if (!session.providers.has(route.authKey)) {
      this.sendError(res, 403, `Session not authorized for: ${route.authKey}`);
      return;
    }

    // Resolve real credential from host auth.json
    const token = this.getCredential(route.authKey);
    if (!token) {
      this.sendError(res, 502, `No credential for: ${route.authKey}`);
      return;
    }

    const upstreamUrl = buildUpstreamUrl(route.upstream, route.prefix, requestUrl);

    route.injectAuth(token, headers);
    headers["host"] = upstreamUrl.hostname;

    this.forward(req, res, upstreamUrl, headers);
  }

  // ─── HTTP Forwarding ───

  private forward(
    req: IncomingMessage,
    res: ServerResponse,
    upstream: URL,
    headers: Record<string, string>,
  ): void {
    const proxyReq = httpsRequest(upstream, { method: req.method, headers }, (proxyRes) => {
      const responseHeaders: Record<string, string | string[]> = {};
      for (const [key, value] of Object.entries(proxyRes.headers)) {
        if (HOP_BY_HOP.has(key) || !value) continue;
        responseHeaders[key] = value;
      }
      res.writeHead(proxyRes.statusCode ?? 502, responseHeaders);
      proxyRes.pipe(res);
    });

    proxyReq.on("error", (err) => {
      console.error(`[auth-proxy] Upstream error: ${err.message}`);
      if (!res.headersSent) {
        this.sendError(res, 502, `Upstream error: ${err.message}`);
      }
    });

    req.pipe(proxyReq);
  }

  private copyHeaders(req: IncomingMessage): Record<string, string> {
    const headers: Record<string, string> = {};
    for (const [key, value] of Object.entries(req.headers)) {
      if (HOP_BY_HOP.has(key)) continue;
      if (typeof value === "string") {
        headers[key] = value;
      } else if (Array.isArray(value)) {
        headers[key] = value.join(", ");
      }
    }
    return headers;
  }

  // ─── Credential Resolution ───

  /** Force re-read of host auth.json (e.g., after token refresh). */
  reloadAuth(): void {
    this.loadAuth();
  }

  private getCredential(providerId: string): string | null {
    this.ensureAuthLoaded();
    const cred = this.authData[providerId];
    if (!cred) return null;

    if (cred.type === "oauth") {
      if (cred.expires && Date.now() >= cred.expires) {
        // Token expired — force re-read (host pi may have refreshed)
        this.loadAuth();
        const updated = this.authData[providerId];
        if (!updated?.access || (updated.expires && Date.now() >= updated.expires)) {
          console.warn(`[auth-proxy] OAuth token expired for ${providerId}`);
          return null;
        }
        return updated.access;
      }
      return cred.access ?? null;
    }

    if (cred.type === "api_key") {
      return cred.key ?? null;
    }

    return null;
  }

  private ensureAuthLoaded(): void {
    if (Date.now() - this.lastAuthLoad > this.authCacheTtlMs) {
      this.loadAuth();
    }
  }

  private loadAuth(): void {
    if (!existsSync(this.authPath)) {
      this.authData = {};
      return;
    }
    try {
      this.authData = JSON.parse(readFileSync(this.authPath, "utf-8"));
      this.lastAuthLoad = Date.now();
    } catch {
      // Keep existing data on parse error
    }
  }

  // ─── Response Helpers ───

  private sendJson(res: ServerResponse, status: number, data: Record<string, unknown>): void {
    res.writeHead(status, { "content-type": "application/json" });
    res.end(JSON.stringify(data));
  }

  private sendError(res: ServerResponse, status: number, message: string): void {
    res.writeHead(status, { "content-type": "text/plain" });
    res.end(message);
  }
}
