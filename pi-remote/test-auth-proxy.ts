/**
 * Test: auth-proxy credential substitution and routing.
 *
 * Verifies:
 * 1. Health endpoint
 * 2. Provider queries (all providers proxied, no passthrough)
 * 3. Session lifecycle (register, reject unregistered, remove)
 * 4. Anthropic: OAuth-shaped placeholder → real OAuth injection + beta headers
 * 5. OpenAI-Codex: fake JWT → session ID extraction + real JWT injection
 * 6. Stub auth building (buildStubAuth)
 * 7. Expired token handling
 */

import { writeFileSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { AuthProxy, ROUTES, buildUpstreamUrl } from "./src/auth-proxy.js";

// ─── Test Helpers ───

let passed = 0;
let failed = 0;

function assert(condition: boolean, message: string): void {
  if (condition) {
    console.log(`  ✓ ${message}`);
    passed++;
  } else {
    console.error(`  ✗ ${message}`);
    failed++;
  }
}

async function fetchJson(url: string, opts?: RequestInit): Promise<{ status: number; headers: Headers; body: string }> {
  const res = await fetch(url, opts);
  const body = await res.text();
  return { status: res.status, headers: res.headers, body };
}

function decodeJwtPayload(token: string): Record<string, unknown> | null {
  try {
    const parts = token.split(".");
    if (parts.length !== 3) return null;
    return JSON.parse(Buffer.from(parts[1], "base64").toString("utf-8"));
  } catch {
    return null;
  }
}

// Real-ish JWT for testing (matches OpenAI JWT structure)
function buildRealJwt(accountId: string): string {
  const header = Buffer.from(JSON.stringify({ alg: "RS256" })).toString("base64");
  const payload = Buffer.from(JSON.stringify({
    "https://api.openai.com/auth": { chatgpt_account_id: accountId },
    sub: "user-test",
    exp: Math.floor(Date.now() / 1000) + 3600,
  })).toString("base64");
  return `${header}.${payload}.realsignature`;
}

// ─── Main ───

async function main(): Promise<void> {
  console.log("\n=== Auth Proxy Tests ===\n");

  const tmpDir = join(tmpdir(), `auth-proxy-test-${Date.now()}`);
  mkdirSync(tmpDir, { recursive: true });
  const authPath = join(tmpDir, "auth.json");

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

  const proxyPort = 17751;
  const proxy = new AuthProxy({ port: proxyPort, authPath });

  try {
    await proxy.start();

    // --- Health check ---
    console.log("Health check:");
    const health = await fetchJson(`http://127.0.0.1:${proxyPort}/health`);
    assert(health.status === 200, "Health returns 200");
    assert(health.body.includes('"ok":true'), "Health body has ok:true");

    // --- Provider queries ---
    console.log("\nProvider queries:");
    assert(proxy.getHostProviders().includes("anthropic"), "Host providers: anthropic");
    assert(proxy.getHostProviders().includes("openai-codex"), "Host providers: openai-codex");
    assert(proxy.getProxiedProviders().length === 2, "Two proxied providers");

    const anthropicUrl = proxy.getProviderProxyUrl("anthropic", "10.200.0.1");
    assert(anthropicUrl === `http://10.200.0.1:${proxyPort}/anthropic`, `Anthropic proxy URL: ${anthropicUrl}`);

    const codexUrl = proxy.getProviderProxyUrl("openai-codex", "10.200.0.1");
    assert(codexUrl === `http://10.200.0.1:${proxyPort}/openai-codex`, `Codex proxy URL: ${codexUrl}`);

    // --- Upstream URL path joining ---
    console.log("\nUpstream URL joining:");
    {
      const codexUpstream = buildUpstreamUrl(
        "https://chatgpt.com/backend-api",
        "/openai-codex",
        new URL("http://proxy/openai-codex/codex/responses?x=1"),
      );
      assert(
        codexUpstream.toString() === "https://chatgpt.com/backend-api/codex/responses?x=1",
        `Codex upstream keeps /backend-api prefix: ${codexUpstream.toString()}`,
      );

      const anthropicUpstream = buildUpstreamUrl(
        "https://api.anthropic.com",
        "/anthropic",
        new URL("http://proxy/anthropic/v1/messages"),
      );
      assert(
        anthropicUpstream.toString() === "https://api.anthropic.com/v1/messages",
        `Anthropic upstream path: ${anthropicUpstream.toString()}`,
      );
    }

    // --- Unregistered session → 403 ---
    console.log("\nUnregistered session:");
    const unregistered = await fetchJson(`http://127.0.0.1:${proxyPort}/anthropic/v1/messages`, {
      method: "POST",
      headers: {
        authorization: "Bearer sk-ant-oat01-proxy-unknown-session",
        "content-type": "application/json",
      },
      body: "{}",
    });
    assert(unregistered.status === 403, `Unregistered → 403 (got ${unregistered.status})`);

    // --- Register session ---
    proxy.registerSession("sess-001", "user-001");

    // --- Missing token → 401 ---
    console.log("\nMissing token:");
    const noToken = await fetchJson(`http://127.0.0.1:${proxyPort}/anthropic/v1/messages`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    });
    assert(noToken.status === 401, `Missing token → 401 (got ${noToken.status})`);

    // --- Bad prefix → 401 ---
    console.log("\nBad prefix:");
    const badPrefix = await fetchJson(`http://127.0.0.1:${proxyPort}/anthropic/v1/messages`, {
      method: "POST",
      headers: {
        authorization: "Bearer not-proxy-prefix",
        "content-type": "application/json",
      },
      body: "{}",
    });
    assert(badPrefix.status === 401, `Bad prefix → 401 (got ${badPrefix.status})`);

    // --- Unknown route → 404 ---
    console.log("\nUnknown route:");
    const unknownRoute = await fetchJson(`http://127.0.0.1:${proxyPort}/google/v1/stuff`);
    assert(unknownRoute.status === 404, `Unknown route → 404 (got ${unknownRoute.status})`);

    // --- Remove session → 403 ---
    console.log("\nRemove session:");
    proxy.removeSession("sess-001");
    const removed = await fetchJson(`http://127.0.0.1:${proxyPort}/anthropic/v1/messages`, {
      method: "POST",
      headers: {
        authorization: "Bearer sk-ant-oat01-proxy-sess-001",
        "content-type": "application/json",
      },
      body: "{}",
    });
    assert(removed.status === 403, `Removed session → 403 (got ${removed.status})`);

    // --- Anthropic header injection ---
    console.log("\nAnthropic header injection:");
    {
      const route = ROUTES.find(r => r.prefix === "/anthropic")!;
      const headers: Record<string, string> = {
        "x-api-key": "proxy-sess-001",
        "anthropic-beta": "fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14",
        "content-type": "application/json",
      };
      route.injectAuth("sk-ant-oat01-real-token", headers);

      assert(!("x-api-key" in headers), "x-api-key removed");
      assert(headers["authorization"] === "Bearer sk-ant-oat01-real-token", "Authorization Bearer set");
      assert(headers["anthropic-beta"].includes("claude-code-20250219"), "OAuth beta: claude-code");
      assert(headers["anthropic-beta"].includes("oauth-2025-04-20"), "OAuth beta: oauth");
      assert(headers["anthropic-beta"].includes("fine-grained-tool-streaming-2025-05-14"), "Existing beta preserved");
      assert(headers["anthropic-beta"].includes("interleaved-thinking-2025-05-14"), "Existing beta preserved (2)");
      assert(headers["user-agent"] === "claude-cli/2.1.2 (external, cli)", "User-Agent set");
      assert(headers["x-app"] === "cli", "x-app set");
    }

    // --- Anthropic session ID extraction ---
    console.log("\nAnthropic session ID extraction:");
    {
      const route = ROUTES.find(r => r.prefix === "/anthropic")!;
      assert(
        route.extractSessionId({ authorization: "Bearer sk-ant-oat01-proxy-sess-abc" }) === "sess-abc",
        "Extracts from OAuth-shaped Authorization token",
      );
      assert(
        route.extractSessionId({ "x-api-key": "proxy-sess-legacy" }) === "sess-legacy",
        "Extracts from legacy x-api-key token",
      );
      assert(route.extractSessionId({ authorization: "Bearer not-a-proxy" }) === null, "Rejects non-proxy bearer");
      assert(route.extractSessionId({}) === null, "Rejects missing key");
    }

    // --- OpenAI-Codex session ID extraction ---
    console.log("\nOpenAI-Codex session ID extraction:");
    {
      const route = ROUTES.find(r => r.prefix === "/openai-codex")!;

      // Build a fake JWT as the proxy would produce
      const header = Buffer.from(JSON.stringify({ alg: "none" })).toString("base64");
      const payload = Buffer.from(JSON.stringify({
        "https://api.openai.com/auth": { chatgpt_account_id: "acct-123" },
        pi_remote_session: "sess-codex-001",
      })).toString("base64");
      const fakeJwt = `${header}.${payload}.placeholder`;

      assert(
        route.extractSessionId({ authorization: `Bearer ${fakeJwt}` }) === "sess-codex-001",
        "Extracts session ID from fake JWT",
      );
      assert(route.extractSessionId({ authorization: "Bearer not.a.jwt" }) === null, "Rejects malformed JWT");
      assert(route.extractSessionId({}) === null, "Rejects missing auth");
    }

    // --- OpenAI-Codex header injection ---
    console.log("\nOpenAI-Codex header injection:");
    {
      const route = ROUTES.find(r => r.prefix === "/openai-codex")!;
      const headers: Record<string, string> = {
        authorization: "Bearer fake.jwt.placeholder",
        "chatgpt-account-id": "acct-123",
        "openai-beta": "responses=experimental",
        originator: "pi",
      };
      route.injectAuth("real.jwt.token", headers);

      assert(headers["authorization"] === "Bearer real.jwt.token", "Real JWT injected");
      assert(headers["chatgpt-account-id"] === "acct-123", "Account ID preserved");
      assert(headers["openai-beta"] === "responses=experimental", "OpenAI-Beta preserved");
      assert(headers["originator"] === "pi", "Originator preserved");
    }

    // --- OpenAI-Codex end-to-end: fake JWT in request → session validated ---
    console.log("\nOpenAI-Codex session validation via fake JWT:");
    {
      proxy.registerSession("sess-codex-e2e", "user-001");

      const header = Buffer.from(JSON.stringify({ alg: "none" })).toString("base64");
      const payload = Buffer.from(JSON.stringify({
        "https://api.openai.com/auth": { chatgpt_account_id: "acct-123" },
        pi_remote_session: "sess-codex-e2e",
      })).toString("base64");
      const fakeJwt = `${header}.${payload}.placeholder`;

      // This will try to forward to chatgpt.com (and likely fail with a network error)
      // but we can verify the proxy accepted the session (not 401/403)
      const result = await fetchJson(`http://127.0.0.1:${proxyPort}/openai-codex/codex/responses`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${fakeJwt}`,
          "chatgpt-account-id": "acct-123",
          "content-type": "application/json",
        },
        body: "{}",
      });

      // Any non-proxy error body proves the request passed session validation
      // and reached upstream. Proxy-side auth failures are plain text with one
      // of these exact messages.
      const proxyErrors = [
        "Missing or invalid session token",
        "Session not registered",
        "Session not authorized for",
        "No credential for",
        "Unknown provider route",
      ];
      const blockedByProxy = proxyErrors.some((m) => result.body.includes(m));
      assert(
        !blockedByProxy,
        `Request reached upstream (status ${result.status}, body starts: ${result.body.slice(0, 80)})`,
      );

      proxy.removeSession("sess-codex-e2e");
    }

    // --- buildStubAuth ---
    console.log("\nbuildStubAuth:");
    {
      const stub = proxy.buildStubAuth("sess-stub-test");
      assert("anthropic" in stub, "Stub has anthropic entry");
      assert("openai-codex" in stub, "Stub has openai-codex entry");

      // Anthropic stub
      const antStub = stub["anthropic"] as Record<string, string>;
      assert(antStub.type === "api_key", "Anthropic stub type is api_key");
      assert(
        antStub.key === "sk-ant-oat01-proxy-sess-stub-test",
        "Anthropic stub key is sk-ant-oat01-proxy-<sessionId>",
      );

      // OpenAI-Codex stub
      const codexStub = stub["openai-codex"] as Record<string, string>;
      assert(codexStub.type === "api_key", "Codex stub type is api_key");

      // Verify the fake JWT has the right structure
      const fakePayload = decodeJwtPayload(codexStub.key);
      assert(fakePayload !== null, "Codex stub key is a valid JWT");

      const auth = fakePayload?.["https://api.openai.com/auth"] as Record<string, string> | undefined;
      assert(auth?.chatgpt_account_id === "acct-test-123", "Fake JWT has real account ID");
      assert(fakePayload?.pi_remote_session === "sess-stub-test", "Fake JWT has session ID");
    }

    // --- Expired token ---
    console.log("\nExpired token:");
    writeFileSync(authPath, JSON.stringify({
      anthropic: {
        type: "oauth",
        access: "sk-ant-oat01-expired",
        expires: Date.now() - 1000,
      },
    }));
    proxy.reloadAuth();

    proxy.registerSession("sess-expired", "user-001");
    const expired = await fetchJson(`http://127.0.0.1:${proxyPort}/anthropic/v1/messages`, {
      method: "POST",
      headers: {
        authorization: "Bearer sk-ant-oat01-proxy-sess-expired",
        "content-type": "application/json",
      },
      body: "{}",
    });
    assert(expired.status === 502, `Expired token → 502 (got ${expired.status})`);

    console.log(`\n--- Results: ${passed} passed, ${failed} failed ---\n`);

  } finally {
    await proxy.stop();
    rmSync(tmpDir, { recursive: true, force: true });
  }

  process.exit(failed > 0 ? 1 : 0);
}

main().catch((err) => {
  console.error("Test error:", err);
  process.exit(1);
});
