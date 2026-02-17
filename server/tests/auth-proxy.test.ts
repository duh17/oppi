/**
 * Auth proxy — credential substitution, routing, session lifecycle.
 *
 * Migrated from test-auth-proxy.ts to vitest.
 */

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { writeFileSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { AuthProxy, ROUTES, buildUpstreamUrl } from "../src/auth-proxy.js";

// ─── Test infra ───

let proxy: AuthProxy;
let tmpDir: string;
let authPath: string;
const proxyPort = 17761; // avoid clashing with default or other tests

function buildRealJwt(accountId: string): string {
  const header = Buffer.from(JSON.stringify({ alg: "RS256" })).toString("base64");
  const payload = Buffer.from(JSON.stringify({
    "https://api.openai.com/auth": { chatgpt_account_id: accountId },
    sub: "user-test",
    exp: Math.floor(Date.now() / 1000) + 3600,
  })).toString("base64");
  return `${header}.${payload}.realsignature`;
}

function decodeJwtPayload(token: string): Record<string, unknown> | null {
  try {
    const parts = token.split(".");
    if (parts.length !== 3) return null;
    return JSON.parse(Buffer.from(parts[1], "base64").toString("utf-8"));
  } catch { return null; }
}

async function fetchProxy(path: string, opts?: RequestInit): Promise<{ status: number; headers: Headers; body: string }> {
  const res = await fetch(`http://127.0.0.1:${proxyPort}${path}`, opts);
  const body = await res.text();
  return { status: res.status, headers: res.headers, body };
}

beforeAll(async () => {
  tmpDir = join(tmpdir(), `auth-proxy-test-${Date.now()}`);
  mkdirSync(tmpDir, { recursive: true });
  authPath = join(tmpDir, "auth.json");

  const realCodexJwt = buildRealJwt("acct-test-123");
  writeFileSync(authPath, JSON.stringify({
    anthropic: {
      type: "oauth",
      access: "sk-ant-oat01-test-token-12345",
      expires: Date.now() + 3600_000,
      refresh: "sk-ant-refresh-test",
    },
    "openai-codex": {
      type: "oauth",
      access: realCodexJwt,
      expires: Date.now() + 3600_000,
      accountId: "acct-test-123",
    },
  }));

  proxy = new AuthProxy({ port: proxyPort, authPath });
  await proxy.start();
});

afterAll(async () => {
  await proxy.stop();
  rmSync(tmpDir, { recursive: true, force: true });
});

// ─── Tests ───

describe("health check", () => {
  it("returns 200 with ok:true", async () => {
    const { status, body } = await fetchProxy("/health");
    expect(status).toBe(200);
    expect(body).toContain('"ok":true');
  });
});

describe("provider queries", () => {
  it("lists anthropic and openai-codex as host providers", () => {
    expect(proxy.getHostProviders()).toContain("anthropic");
    expect(proxy.getHostProviders()).toContain("openai-codex");
  });

  it("has two proxied providers", () => {
    expect(proxy.getProxiedProviders()).toHaveLength(2);
  });

  it("builds correct proxy URLs", () => {
    expect(proxy.getProviderProxyUrl("anthropic", "10.200.0.1"))
      .toBe(`http://10.200.0.1:${proxyPort}/anthropic`);
    expect(proxy.getProviderProxyUrl("openai-codex", "10.200.0.1"))
      .toBe(`http://10.200.0.1:${proxyPort}/openai-codex`);
  });
});

describe("upstream URL joining", () => {
  it("keeps /backend-api prefix for codex", () => {
    const url = buildUpstreamUrl(
      "https://chatgpt.com/backend-api",
      "/openai-codex",
      new URL("http://proxy/openai-codex/codex/responses?x=1"),
    );
    expect(url.toString()).toBe("https://chatgpt.com/backend-api/codex/responses?x=1");
  });

  it("strips route prefix for anthropic", () => {
    const url = buildUpstreamUrl(
      "https://api.anthropic.com",
      "/anthropic",
      new URL("http://proxy/anthropic/v1/messages"),
    );
    expect(url.toString()).toBe("https://api.anthropic.com/v1/messages");
  });
});

describe("session lifecycle", () => {
  it("rejects unregistered session with 403", async () => {
    const { status } = await fetchProxy("/anthropic/v1/messages", {
      method: "POST",
      headers: { authorization: "Bearer sk-ant-oat01-proxy-unknown-session", "content-type": "application/json" },
      body: "{}",
    });
    expect(status).toBe(403);
  });

  it("rejects missing token with 401", async () => {
    proxy.registerSession("sess-001");
    const { status } = await fetchProxy("/anthropic/v1/messages", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    });
    expect(status).toBe(401);
    proxy.removeSession("sess-001");
  });

  it("rejects bad prefix with 401", async () => {
    const { status } = await fetchProxy("/anthropic/v1/messages", {
      method: "POST",
      headers: { authorization: "Bearer not-a-proxy", "content-type": "application/json" },
      body: "{}",
    });
    expect(status).toBe(401);
  });

  it("returns 404 for unknown route", async () => {
    const { status } = await fetchProxy("/google/v1/stuff");
    expect(status).toBe(404);
  });

  it("rejects after removeSession with 403", async () => {
    proxy.registerSession("sess-rm-test");
    proxy.removeSession("sess-rm-test");
    const { status } = await fetchProxy("/anthropic/v1/messages", {
      method: "POST",
      headers: { authorization: "Bearer sk-ant-oat01-proxy-sess-rm-test", "content-type": "application/json" },
      body: "{}",
    });
    expect(status).toBe(403);
  });
});

describe("Anthropic header injection", () => {
  it("injects Bearer auth and adds required headers", () => {
    const route = ROUTES.find((r) => r.prefix === "/anthropic")!;
    const headers: Record<string, string> = {
      "anthropic-beta": "fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14",
      "content-type": "application/json",
    };
    route.injectAuth("sk-ant-oat01-real-token", headers);

    expect(headers["authorization"]).toBe("Bearer sk-ant-oat01-real-token");
    expect(headers["anthropic-beta"]).toContain("claude-code-20250219");
    expect(headers["anthropic-beta"]).toContain("oauth-2025-04-20");
    expect(headers["anthropic-beta"]).toContain("fine-grained-tool-streaming-2025-05-14");
    expect(headers["anthropic-beta"]).toContain("interleaved-thinking-2025-05-14");
    expect(headers["user-agent"]).toBe("claude-cli/2.1.2 (external, cli)");
    expect(headers["x-app"]).toBe("cli");
  });
});

describe("Anthropic session ID extraction", () => {
  it("extracts from OAuth-shaped Authorization token", () => {
    const route = ROUTES.find((r) => r.prefix === "/anthropic")!;
    expect(route.extractSessionId({ authorization: "Bearer sk-ant-oat01-proxy-sess-abc" })).toBe("sess-abc");
  });
  it("rejects non-proxy bearer", () => {
    const route = ROUTES.find((r) => r.prefix === "/anthropic")!;
    expect(route.extractSessionId({ authorization: "Bearer not-a-proxy" })).toBeNull();
  });
  it("rejects missing key", () => {
    const route = ROUTES.find((r) => r.prefix === "/anthropic")!;
    expect(route.extractSessionId({})).toBeNull();
  });
});

describe("OpenAI-Codex session ID extraction", () => {
  it("extracts session ID from fake JWT", () => {
    const route = ROUTES.find((r) => r.prefix === "/openai-codex")!;
    const header = Buffer.from(JSON.stringify({ alg: "none" })).toString("base64");
    const payload = Buffer.from(JSON.stringify({
      "https://api.openai.com/auth": { chatgpt_account_id: "acct-123" },
      oppi_session: "sess-codex-001",
    })).toString("base64");
    const fakeJwt = `${header}.${payload}.placeholder`;

    expect(route.extractSessionId({ authorization: `Bearer ${fakeJwt}` })).toBe("sess-codex-001");
  });
  it("rejects malformed JWT", () => {
    const route = ROUTES.find((r) => r.prefix === "/openai-codex")!;
    expect(route.extractSessionId({ authorization: "Bearer not.a.jwt" })).toBeNull();
  });
  it("rejects missing auth", () => {
    const route = ROUTES.find((r) => r.prefix === "/openai-codex")!;
    expect(route.extractSessionId({})).toBeNull();
  });
});

describe("OpenAI-Codex header injection", () => {
  it("injects real JWT and preserves other headers", () => {
    const route = ROUTES.find((r) => r.prefix === "/openai-codex")!;
    const headers: Record<string, string> = {
      authorization: "Bearer fake.jwt.placeholder",
      "chatgpt-account-id": "acct-123",
      "openai-beta": "responses=experimental",
      originator: "pi",
    };
    route.injectAuth("real.jwt.token", headers);

    expect(headers["authorization"]).toBe("Bearer real.jwt.token");
    expect(headers["chatgpt-account-id"]).toBe("acct-123");
    expect(headers["openai-beta"]).toBe("responses=experimental");
    expect(headers["originator"]).toBe("pi");
  });
});

describe("OpenAI-Codex e2e session validation", () => {
  it("request with valid fake JWT passes session check", async () => {
    proxy.registerSession("sess-codex-e2e");

    const header = Buffer.from(JSON.stringify({ alg: "none" })).toString("base64");
    const payload = Buffer.from(JSON.stringify({
      "https://api.openai.com/auth": { chatgpt_account_id: "acct-123" },
      oppi_session: "sess-codex-e2e",
    })).toString("base64");
    const fakeJwt = `${header}.${payload}.placeholder`;

    const result = await fetchProxy("/openai-codex/codex/responses", {
      method: "POST",
      headers: {
        authorization: `Bearer ${fakeJwt}`,
        "chatgpt-account-id": "acct-123",
        "content-type": "application/json",
      },
      body: "{}",
    });

    const proxyErrors = [
      "Missing or invalid session token",
      "Session not registered",
      "Session not authorized for",
      "No credential for",
      "Unknown provider route",
    ];
    const blockedByProxy = proxyErrors.some((m) => result.body.includes(m));
    expect(blockedByProxy).toBe(false);

    proxy.removeSession("sess-codex-e2e");
  });
});

describe("buildStubAuth", () => {
  it("produces correct stub entries for all providers", () => {
    const stub = proxy.buildStubAuth("sess-stub-test");
    expect(stub).toHaveProperty("anthropic");
    expect(stub).toHaveProperty("openai-codex");

    const antStub = stub["anthropic"] as Record<string, string>;
    expect(antStub.type).toBe("api_key");
    expect(antStub.key).toBe("sk-ant-oat01-proxy-sess-stub-test");

    const codexStub = stub["openai-codex"] as Record<string, string>;
    expect(codexStub.type).toBe("api_key");

    const fakePayload = decodeJwtPayload(codexStub.key);
    expect(fakePayload).not.toBeNull();
    const auth = fakePayload?.["https://api.openai.com/auth"] as Record<string, string> | undefined;
    expect(auth?.chatgpt_account_id).toBe("acct-test-123");
    expect(fakePayload?.oppi_session).toBe("sess-stub-test");
  });
});

describe("expired token handling", () => {
  it("returns 502 for expired credential", async () => {
    writeFileSync(authPath, JSON.stringify({
      anthropic: {
        type: "oauth",
        access: "sk-ant-oat01-expired",
        expires: Date.now() - 1000,
      },
    }));
    proxy.reloadAuth();

    proxy.registerSession("sess-expired");
    const { status } = await fetchProxy("/anthropic/v1/messages", {
      method: "POST",
      headers: {
        authorization: "Bearer sk-ant-oat01-proxy-sess-expired",
        "content-type": "application/json",
      },
      body: "{}",
    });
    expect(status).toBe(502);
    proxy.removeSession("sess-expired");
  });
});
