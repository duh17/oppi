# Container Secret Isolation — Auth Proxy Design

Motivated by Armin Ronacher's Gondolin security architecture. This document
covers: what Gondolin does, how Pi Remote compares, what we tested, what we
found, and what we're building.

## Background: Gondolin's Approach

[Source: earendil-works.github.io/gondolin/security/ and /network/]
[Referenced by @mitsuhiko, 2026-02-07]

Gondolin runs untrusted agent code in QEMU VMs with three key security properties:

**1. Network confinement.** The guest gets a virtual `eth0` but no real NAT.
The host implements a userspace network stack that only allows HTTP/TLS to
allowlisted hosts. Arbitrary TCP, UDP (except DNS), SOCKS, SSH — all blocked
at the protocol level. TLS is MITM'd so the host can inspect HTTPS requests.
DNS rebinding is prevented by re-resolving at connect time.

**2. Secrets never enter the guest.** The guest receives random placeholder
env vars (`GONDOLIN_SECRET_<random>`). When the guest makes an HTTP request,
the host scans outbound headers and replaces placeholders with real secrets
— but only if the destination hostname is on the secret's allowlist. The guest
literally cannot read the real token because it never enters VM memory.

**3. Programmable filesystem.** The guest sees a FUSE mount backed by host-side
providers. The host controls exactly what files are visible and whether they're
read-only. No ambient host filesystem access.

## Pi Remote's Current State (Before This Work)

Pi Remote runs agents in Apple containers (macOS `container` CLI) with:

- **Default NAT network** — full internet access (`192.168.64.0/24`)
- **`auth.json` copied into container** — real Anthropic OAuth tokens on disk
- **Policy-based protection** — glob patterns blocking `cat auth.json`, etc.
- **Workspace bind mounts** — host directories mounted into container

### What works

- Permission gate intercepts tool calls, routes approval to phone
- Policy engine evaluates layered rules (hard deny → workspace → user → learned)
- Container provides process isolation (can't damage host)

### What doesn't work: secret protection

The policy rule `{ tool: "bash", pattern: "*auth.json*", action: "deny" }` is
trivially bypassed. We tested these inside a running oppi-server container:

```bash
# Bypass 1: base64 encoded path
cat $(echo L2hvbWUvcGkvLnBpL2FnZW50L2F1dGguanNvbg== | base64 -d)
# → prints full auth.json contents

# Bypass 2: variable indirection
F=/home/pi/.pi/agent/au; cat "${F}th.json"
# → prints full auth.json contents

# Bypass 3: shell glob
cat /home/pi/.pi/agent/a*h.json
# → prints full auth.json contents

# Bypass 4: different language
python3 -c "print(open('/home/pi/.pi/agent/auth.json').read())"
# → prints full auth.json contents
```

All four produce the real OAuth tokens. Pattern matching bash commands is a
losing game against an adversary that can generate arbitrary code.

Combined with full internet access (default network), an agent can read the
tokens and exfiltrate them to any host.

## Experiment: Apple Container Network Modes

We tested what Apple containers actually provide for network isolation.

### Default network (`mode: nat`, 192.168.64.0/24)

```bash
# Internet access: YES
container exec <id> curl -s https://example.com  # → 200

# Host access: YES (via gateway 192.168.64.1)
container exec <id> curl -s http://192.168.64.1:7749/health  # → {"ok":true}

# DNS: YES
container exec <id> nslookup example.com  # → resolves
```

### Internal network (`--internal`, `mode: hostOnly`)

Created with: `container network create --internal --subnet 10.99.0.0/24 test-internal`

```bash
# Internet access: NO
container run --rm --network test-internal ... curl -s --connect-timeout 5 https://example.com
# → timeout (exit 28)

# DNS: NO
container run --rm --network test-internal ... nslookup example.com
# → "connection timed out; no servers could be reached"

# Host access via gateway: YES
container run --rm --network test-internal ... curl -s http://10.99.0.1:7749/health
# → {"ok":true}

# Host — arbitrary ports reachable:
container run --rm --network test-internal ... nc -z -w 3 10.99.0.1 22
# → exit 0 (SSH reachable)
```

### Network inspection

```bash
container network inspect test-internal
# → mode: "hostOnly", gateway: "10.99.0.1", subnet: "10.99.0.0/24"

container network inspect default
# → mode: "nat", gateway: "192.168.64.1", subnet: "192.168.64.0/24"
```

### Findings

| Capability | Default (NAT) | Internal (hostOnly) |
|---|---|---|
| Internet egress | Yes | **No** |
| DNS resolution | Yes | **No** |
| Host gateway access | Yes (192.168.64.1) | Yes (10.99.0.1) |
| Reach any host port | Yes | Yes |
| Reach other containers | Same subnet | Same subnet |

**The `--internal` flag is a blunt but effective kill switch for internet
access.** It's not Gondolin's per-host allowlisting, but it eliminates the
entire class of "exfiltrate over the network" attacks. The container can still
reach host services via the gateway — which is what we need for the permission
gate and the auth proxy.

**Gap:** All host ports bound to `*` or the gateway IP are reachable from the
container. This exposes services like LM Studio (:1234), nginx (:8080), Hugo
(:1313), etc. Acceptable for our threat model (agent isn't trying to attack
host services) but worth noting.

## Experiment: Tracing Pi's Auth and Header Flow

We traced how `models.json` headers and `auth.json` credentials flow through
pi's source code to actual HTTP requests. All paths verified in the compiled
source of pi v0.52.7.

### models.json override-only path

When `models.json` contains only `baseUrl` (no `models` array, no `apiKey`):

```
models.json: { providers: { anthropic: { baseUrl: "http://proxy" } } }
                                              ↓
model-registry.js:501  — override-only branch detected (no models array)
model-registry.js:503  — this.models.map() over all built-in anthropic models
model-registry.js:508  — model.baseUrl = config.baseUrl ?? model.baseUrl
model-registry.js:509  — model.headers = merged(model.headers, config.headers)
                                              ↓
Result: all built-in Anthropic models get new baseUrl, keep existing config
```

**Verified:** Override-only path works. No `apiKey` or `models` array needed.

### apiKey resolution

```
Agent.run()
  → agent-loop.js:150  — resolvedApiKey = config.getApiKey(config.model.provider)
    → agent.js:285     — getApiKey = this.getApiKey (set in constructor)
      → sdk.ts         — calls modelRegistry.getApiKeyForProvider(provider)
        → auth-storage.ts — reads auth.json, returns credential
                                              ↓
Result: apiKey comes from auth.json, independent of models.json
```

**Verified:** Override-only path does not touch apiKey. AuthStorage is the source.

### Headers in API requests

```
model.headers (from models.json)
  → anthropic.js:387   — mergeHeaders({SDK defaults}, model.headers, optionsHeaders)
    → Anthropic SDK     — new Anthropic({ defaultHeaders: merged })
      → HTTP request    — all merged headers sent on every request
```

**Verified:** Custom headers from models.json provider-level `headers` field
are sent on every API request.

### Anthropic SDK auth mechanism

```
anthropic.js:371    — isOAuthToken(apiKey) checks for "sk-ant-oat" substring
  OAuth path:       — new Anthropic({ authToken: apiKey })
                      → client.ts:407 — Authorization: Bearer <token>
  API key path:     — new Anthropic({ apiKey: apiKey })
                      → client.ts:401 — X-Api-Key: <token>
```

**Verified:** Our real credential (`sk-ant-oat-...`) triggers the OAuth path.
A placeholder (`proxy-sess_abc`) does NOT contain `sk-ant-oat`, so it triggers
the API key path (`X-Api-Key` header). The proxy must translate between these.

### resolveConfigValue for header values

```
resolve-config-value.js:
  "!command"  → execSync(command), cached
  "ENV_VAR"  → process.env[value] || value (literal fallback)
  "literal"  → used as-is
```

**Verified:** Literal header values pass through untouched. No risk of
unintended command execution from our static header values.

## Design: Auth Proxy

Based on the experiments and source tracing above.

### Principle

Adopt Gondolin's core insight: **real secrets never enter the guest**. Implement
it using Apple container's `--internal` network (no internet) plus a host-side
auth-injecting reverse proxy (credential substitution at request time).

### Architecture

```
Container (--internal network)          Host
┌──────────────────────────┐    ┌───────────────────────────────────┐
│                          │    │                                   │
│  auth.json:              │    │  auth-proxy (port 7751)           │
│    anthropic:            │    │    bind: 10.200.0.1 only          │
│      type: api_key       │    │                                   │
│      key: proxy-<sessId> │    │    1. Read x-api-key header       │
│                          │    │    2. Parse session ID             │
│  models.json:            │    │    3. Look up real credential      │
│    anthropic:            │    │       (host AuthStorage)           │
│      baseUrl: http://    │    │    4. If OAuth: set Authorization  │
│        10.200.0.1:7751/  │    │       + Claude Code headers       │
│        anthropic         │    │    5. Forward to api.anthropic.com │
│                          │    │    6. Stream response back         │
│  pi ──HTTP──────────────────────→                                 │
│    x-api-key: proxy-abc  │    │                                   │
│                          │    │  host ~/.pi/agent/auth.json       │
│  (no internet access)    │    │    anthropic: { type: oauth,      │
│                          │    │      access: sk-ant-oat-...,      │
└──────────────────────────┘    │      refresh: sk-ant-... }        │
                                └───────────────────────────────────┘
```

### sandbox.ts changes

**1. Stop copying auth.json — write a stub.**

```typescript
// BEFORE (current code, line 242-245):
syncFile(
  join(homedir(), ".pi", "agent", "auth.json"),
  join(agentDir, "auth.json"),
);

// AFTER:
const stubAuth: Record<string, unknown> = {};
for (const provider of this.getProxyProviders()) {
  stubAuth[provider] = {
    type: "api_key",
    key: `proxy-${sessionId}`,
  };
}
writeFileSync(
  join(agentDir, "auth.json"),
  JSON.stringify(stubAuth, null, 2),
  { mode: 0o600 },
);
```

The placeholder `proxy-<sessionId>` does not start with `sk-ant-oat`, so pi
uses the API key path (sends `x-api-key` header). The proxy translates to
OAuth on the upstream side.

**2. Rewrite models.json baseUrl to point at proxy.**

```typescript
// BEFORE (line 771):
const transformed = content.replace(/http:\/\/localhost:/g, `http://${HOST_GATEWAY}:`);

// AFTER:
private syncModels(src: string, dest: string, sessionId: string): void {
  if (!existsSync(src)) return;
  const content = readFileSync(src, "utf-8");

  // Rewrite localhost → host-gateway (for local models like LM Studio)
  let transformed = content.replace(/http:\/\/localhost:/g, `http://${HOST_GATEWAY}:`);

  // Inject proxy override for remote providers
  const parsed = JSON.parse(transformed);
  parsed.providers ??= {};
  for (const provider of this.getProxyProviders()) {
    parsed.providers[provider] = {
      ...parsed.providers[provider],
      baseUrl: `http://${HOST_GATEWAY}:${AUTH_PROXY_PORT}/${provider}`,
    };
  }
  writeFileSync(dest, JSON.stringify(parsed, null, 2));
}
```

Routes Anthropic API calls through the proxy. Local providers (LM Studio)
stay direct via host-gateway.

**3. Switch to internal network.**

```typescript
// BEFORE (implicit — uses default network):
const args = ["run", "--rm", "-i", ...];

// AFTER:
const args = ["run", "--rm", "-i", "--network", "pi-internal", ...];
```

Network created once at server startup:
```typescript
try {
  execSync("container network create --internal --subnet 10.200.0.0/24 pi-internal",
    { stdio: "ignore" });
} catch {
  // Already exists
}
```

### auth-proxy.ts (new file)

Provider routing with auth translation:

```typescript
interface ProviderRoute {
  prefix: string;                    // "/anthropic"
  upstream: string;                  // "https://api.anthropic.com"
  setAuth: (token: string, headers: Record<string, string>) => void;
}

const ROUTES: ProviderRoute[] = [
  {
    prefix: "/anthropic",
    upstream: "https://api.anthropic.com",
    setAuth(token, headers) {
      if (token.includes("sk-ant-oat")) {
        // OAuth token — Anthropic expects Bearer auth + beta headers
        headers["authorization"] = `Bearer ${token}`;
        headers["anthropic-beta"] = [
          "claude-code-20250219",
          "oauth-2025-04-20",
          "fine-grained-tool-streaming-2025-05-14",
          "interleaved-thinking-2025-05-14",
        ].join(",");
        delete headers["x-api-key"];
      } else {
        headers["x-api-key"] = token;
      }
    },
  },
  {
    prefix: "/openai",
    upstream: "https://api.openai.com",
    setAuth(token, headers) {
      headers["authorization"] = `Bearer ${token}`;
      delete headers["x-api-key"];
    },
  },
];
```

Session registry and request flow:

```typescript
interface SessionEntry {
  userId: string;
  providers: Set<string>;
}

// sessions.ts calls registerSession() on spawn, removeSession() on stop.
```

Request lifecycle:

```
1. Match route by URL prefix        → /anthropic/v1/messages
2. Extract x-api-key from request   → "proxy-sess_abc"
3. Parse session ID                 → "sess_abc"
4. Validate session is registered   → sessions.has("sess_abc")
5. Validate provider access         → entry.providers.has("anthropic")
6. Get real token from host         → hostAuthStorage.getApiKey("anthropic")
7. Strip prefix, build upstream URL → https://api.anthropic.com/v1/messages
8. Copy headers, apply setAuth()    → replaces x-api-key with Bearer token
9. Forward request body             → stream to upstream
10. Stream response back            → pipe upstream response to container
```

### OAuth refresh

The proxy holds a pi `AuthStorage` instance pointed at the host's real
`~/.pi/agent/auth.json`. Calling `getApiKey("anthropic")` on an expired OAuth
token triggers automatic refresh with file locking (same mechanism pi uses
today). The container never sees refresh tokens or participates in the flow.

### What the proxy does NOT do

- No request/response body inspection (not Gondolin's MITM approach)
- No TLS termination (connection to proxy is plaintext over internal network)
- No API path allowlisting
- No response caching or rewriting

~150 lines of code. Thin auth-injecting reverse proxy.

### Local providers (LM Studio, Ollama)

No change. These use `apiKey: "DUMMY"` and connect directly to the host via
the existing `localhost` → `HOST_GATEWAY` rewrite. Not proxied because there
are no real credentials to protect.

### Which providers need proxying?

Only those with real credentials in the host's `auth.json`:

```typescript
function getProxyProviders(): string[] {
  const hostAuth = join(homedir(), ".pi", "agent", "auth.json");
  if (!existsSync(hostAuth)) return [];
  return Object.keys(JSON.parse(readFileSync(hostAuth, "utf-8")));
}
```

## Comparison: Before and After

| Property | Before | After |
|----------|--------|-------|
| Real API tokens in container | Yes (`auth.json`) | No (stub placeholder) |
| Container internet access | Full (NAT) | None (`--internal`) |
| Token exfiltration via network | `curl` to any host | Impossible (no internet) |
| Token exfiltration via files | Read `auth.json` | Nothing to read |
| Placeholder useful outside proxy | N/A | No (`proxy-sess_abc` is meaningless) |
| OAuth refresh in container | Yes | No (host only) |
| Session-scoped API access | No | Yes (proxy validates session) |
| Access revoked on session end | Token persists in file | `removeSession()` cuts access |

## Comparison: Pi Remote vs Gondolin After This Change

| Capability | Gondolin | Pi Remote (after) |
|---|---|---|
| Secret isolation | Placeholders in VM, host substitutes in HTTP headers | Placeholders in container, host proxy substitutes |
| Network confinement | Per-host allowlist, protocol-level (HTTP/TLS only) | Binary: no internet at all (`--internal` network) |
| Allowed destinations | Configurable allowlist with wildcard support | Only the auth proxy (and host services on gateway) |
| TLS inspection | Full MITM, host terminates and re-originates TLS | None (proxy receives plaintext from internal network) |
| DNS | Forwarded but results disregarded for policy | Blocked entirely |
| Filesystem | FUSE-backed programmable VFS | Bind mounts with path canonicalization |
| Compute isolation | QEMU VM | Apple container (lighter, macOS-native) |
| Startup time | Seconds (VM boot) | Sub-second (container start) |
| Human-in-the-loop | No (static policy) | Yes (phone approval for "ask" decisions) |
| Adaptive policy | No | Yes ("Always Allow" with scoping) |

Gondolin is more surgical (per-host network policy, TLS inspection, VFS).
Pi Remote is blunter (no internet at all) but has the human supervision layer
that Gondolin doesn't. Different threat models, complementary approaches.

## Implementation Order

1. ✅ `src/auth-proxy.ts` — proxy with per-provider credential substitution
2. ✅ Network setup — `pi-internal` (--internal) at server startup
3. ✅ `src/sandbox.ts` — stub auth.json, rewrite models.json, `--network pi-internal`
4. ✅ `src/sessions.ts` — register/remove sessions with proxy
5. End-to-end test — container → proxy → Anthropic API

## Decision: NAT networking (not --internal)

After building the auth proxy with `--internal` network support, we decided
to use **default NAT networking** instead. Rationale:

**The auth proxy already solves credential isolation.** Real AI tokens never
enter the container regardless of network mode. The `--internal` network
was defense-in-depth against prompt injection data exfiltration — a real
but narrow risk for a personal server running your own agents.

**The cost of --internal is high.** Every external tool breaks: git, npm,
pip, curl, fetch skill, search skill. Each needs proxy plumbing (forward
proxy, CONNECT tunneling, credential helpers). The complexity isn't worth
it for the threat model.

**NAT + auth proxy = EC2 instance role model.** The container has internet
(like an EC2 instance) but no long-lived credentials on disk. It gets
temporary, scoped credentials from the auth proxy (like IMDS). This is
practical and well-understood.

**Code impact:**
- `sandbox.ts`: remove `--network pi-internal`, revert HOST_GATEWAY to
  `192.168.64.1`, remove `ensureNetwork()`
- `server.ts`: remove `ensureNetwork()` call
- Auth proxy: no changes (works on any network, binds 0.0.0.0)

See `integration-design.md` for the full credential vending system for
external services (GitHub, npm, AWS, etc.).

## Open Questions

**Cost tracking.** All API traffic flows through the proxy — natural hook point
for usage logging and per-session/user cost attribution. Not v1.

**Multiple real providers.** Currently Anthropic and OpenAI-Codex, both fully
proxied. Anthropic uses placeholder substitution (`proxy-<sessionId>` →
real OAuth). OpenAI-Codex uses a fake JWT with real account ID + embedded
session ID (SDK extracts `chatgpt_account_id` from fake JWT successfully,
proxy swaps Authorization header with real JWT). Adding a provider means
adding a route entry to `ROUTES` in `auth-proxy.ts`.
