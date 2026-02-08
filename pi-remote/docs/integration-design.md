# Integration Credential Vending — Design

EC2 instances don't store AWS credentials. They call a metadata service
(`169.254.169.254`) to get temporary, scoped credentials from an attached
IAM role. The instance never sees long-lived secrets.

Same model for pi-remote containers.

## Mental Model

```
EC2 world:
  Instance → IMDS (169.254.169.254) → temporary AWS credentials
  Instance role defines what the instance can access
  Credentials rotate automatically, revocable instantly

Pi Remote world:
  Container → Auth Proxy (192.168.64.1:7751) → temporary service credentials
  Workspace integrations define what the session can access
  Credentials are session-scoped, revocable from the phone
```

Containers run on NAT (full internet). They can reach external services
directly — they just need credentials. The auth proxy is the metadata
service: it vends credentials without storing them in the container.

## What the user sees (iOS app)

### 1. Connect a service (one-time setup)

```
Settings > Integrations > [+]

  GitHub          [Connect]
  npm             [Connect]
  Gmail (read)    [Connect]
  AWS             [Connect]
```

Tap "Connect GitHub":
1. iOS opens SFSafariViewController → github.com OAuth
2. User logs in, grants scopes (repo, read:org)
3. Callback returns to pi-remote server
4. Server stores encrypted credentials
5. iOS shows: "GitHub ✓ Connected — repo, read:org"

This is the same UX as adding accounts in iOS Settings or connecting
services in Shortcuts. OAuth happens on the phone, credentials land on
the server. The container never participates.

### 2. Configure workspace integrations

```
Workspace: "coding"

  Model:          Claude Opus 4
  Skills:         [searxng, fetch, ast-grep]
  Integrations:   [GitHub ✓] [npm ✓] [AWS ✗]
                   ^^^^^^^^    ^^^^^    ^^^^
                   enabled    enabled  disabled
```

Each workspace declares which integrations its sessions can use.
A research workspace might get none. A coding workspace gets GitHub + npm.
Toggling is instant — no re-auth needed.

### 3. Session uses credentials transparently

The agent runs `git push origin feature-branch`. Git calls the credential
helper, which fetches a token from the auth proxy. The push works. The
agent never sees the token value, and if the session ends, the credential
helper stops working.

### 4. Revoke from the phone

```
Settings > Integrations > GitHub > [Disconnect]
```

Instant. All active sessions lose GitHub access. The credential helper
returns 403 on the next call.

## Architecture

### Network: NAT (default), not --internal

Containers use the default Apple container network (192.168.64.0/24, NAT).
Full internet access. The auth proxy runs on the gateway (192.168.64.1).

Why NAT instead of --internal:
- CLI tools (git, npm, pip, curl) work naturally
- No forward proxy or CONNECT tunneling needed
- Fetch/search skills work without special plumbing
- The auth proxy still keeps real AI tokens off-disk
- Acceptable residual risk: workspace data exfiltration via prompt injection
  (same risk as running pi locally on your laptop)

### Credential flow

```
Container                          Host (192.168.64.1)
┌──────────────────────┐    ┌─────────────────────────────────┐
│                      │    │                                 │
│  git push            │    │  Auth Proxy (:7751)             │
│    ↓                 │    │                                 │
│  credential helper   │    │  GET /integrations/github/cred  │
│    ↓                 │    │    → validate session           │
│  curl proxy/cred ────────→│    → check workspace allows it  │
│    ↓                 │    │    → read encrypted cred store  │
│  gets token in memory│    │    → return { token, expires }  │
│    ↓                 │    │                                 │
│  git uses token ─────────→│  (direct to github.com via NAT) │
│                      │    │                                 │
│  .gitconfig:         │    │  Credential Store               │
│    credential.helper │    │  ~/.config/pi-remote/           │
│    = !curl proxy/cred│    │    integrations.json (encrypted)│
│                      │    │                                 │
└──────────────────────┘    └─────────────────────────────────┘
```

Key property: the token passes through container memory during the git
operation but is never written to disk. If the session ends or the
integration is revoked, the credential helper returns 403.

### Two credential categories

**AI providers** (existing auth-proxy routes):
- Anthropic, OpenAI-Codex
- Proxy intercepts API requests, injects auth headers
- Container sends placeholder tokens (proxy-<sessionId>, fake JWT)
- Token never touches container memory

**External integrations** (new):
- GitHub, npm, Gmail, AWS, etc.
- Container fetches credentials from vending endpoint
- Token passes through container memory briefly
- Container calls external service directly (NAT)

The difference: AI providers are reverse-proxied (full credential isolation).
External integrations are vended (credential in memory during use). This
is the same trade-off EC2 makes — the instance holds temporary credentials
in memory while using them.

### Credential store

```json
// ~/.config/pi-remote/integrations.json (encrypted at rest)
{
  "github": {
    "type": "oauth",
    "accessToken": "gho_xxxx",
    "refreshToken": "ghr_xxxx",
    "scopes": ["repo", "read:org"],
    "expiresAt": 1739000000000,
    "connectedAt": 1738900000000,
    "oauth": {
      "authorizeUrl": "https://github.com/login/oauth/authorize",
      "tokenUrl": "https://github.com/login/oauth/access_token",
      "clientId": "Iv1.abc123"
    }
  },
  "npm": {
    "type": "token",
    "token": "npm_xxxx",
    "connectedAt": 1738900000000
  }
}
```

OAuth tokens are refreshed automatically by the server when expired.
Static tokens (npm, API keys) are stored as-is.

### Vending endpoint

```
GET /integrations/:service/credential
Headers:
  x-session-id: <sessionId>    (set by credential helper)
  x-api-key: proxy-<sessionId> (reuse existing session auth)

Response (200):
  { "token": "gho_xxxx", "expires_in": 3600 }

Response (403):
  "Integration not enabled for this workspace"

Response (404):
  "Integration not connected"
```

The proxy validates:
1. Session is registered
2. Session's workspace includes this integration
3. Integration is connected and not expired
4. Return credential (refresh first if needed)

### Container setup (sandbox.ts)

When a session starts, sandbox.ts injects credential helpers based on
the workspace's enabled integrations:

**Git** (if GitHub enabled):
```ini
# .gitconfig injected into container
[credential "https://github.com"]
  helper = "!f() { T=$(curl -sf -H 'x-session-id: SESSION_ID' http://192.168.64.1:7751/integrations/github/credential | jq -r .token); echo protocol=https; echo host=github.com; echo username=x-access-token; echo password=$T; }; f"
```

**npm** (if npm enabled):
```ini
# .npmrc injected into container
//registry.npmjs.org/:_authToken=${NPM_TOKEN}
```
Plus `NPM_TOKEN` env var that calls the proxy, or a simpler approach:
inject the token directly (it's in memory either way).

**AWS** (if AWS enabled):
```ini
# ~/.aws/config injected into container
[default]
credential_process = curl -sf -H 'x-session-id: SESSION_ID' http://192.168.64.1:7751/integrations/aws/credential
```

### Workspace type (extended)

```typescript
interface Workspace {
  // ... existing fields ...

  // Integrations available to sessions in this workspace
  integrations: string[];  // ["github", "npm"]
}
```

### Integration registry

```typescript
interface IntegrationDef {
  id: string;                    // "github"
  name: string;                  // "GitHub"
  icon: string;                  // "github" (SF Symbol or custom)
  credentialType: "oauth" | "token" | "api_key";

  // OAuth config (if applicable)
  oauth?: {
    authorizeUrl: string;
    tokenUrl: string;
    clientId: string;
    defaultScopes: string[];
  };

  // How to inject into container
  delivery: GitCredentialHelper | NpmRc | AwsCredentialProcess | EnvVar;
}
```

Start with a small set of built-in integrations. Not a plugin system —
just a registry of known services with their OAuth configs and delivery
mechanisms.

## OAuth flow (iOS ↔ Server)

```
iOS App                         Server                      GitHub
───────                         ──────                      ──────
POST /integrations/github/connect
  ← { authUrl, state }

Open SFSafariViewController(authUrl)
                                                    ← user logs in
                                                    ← grants scopes
                            GET /integrations/callback
                              ?code=xxx&state=yyy
                            → exchange code for tokens
                            → store in integrations.json
                            → 302 → pi-remote://callback?ok

SFSafariViewController closes
                            ← WS: { type: "integration_connected",
                                     service: "github",
                                     scopes: ["repo"] }
iOS updates UI: "GitHub ✓"
```

The server hosts the OAuth callback endpoint. The iOS app opens the
OAuth URL in SFSafariViewController. After auth completes, the callback
redirects to a custom URL scheme (pi-remote://) that closes the browser
and updates the iOS UI.

## Comparison

| | OpenClaw + Composio | Pi Remote |
|---|---|---|
| Where OAuth happens | Composio cloud | Pi-remote server (self-hosted) |
| Where credentials stored | Composio vault (cloud) | Server disk (encrypted) |
| How agent accesses service | Composio proxies the API call | Agent calls API directly, credentials vended |
| Credential visibility | Agent never sees token | Token in memory during use |
| Revocation | Composio dashboard | iOS app |
| Audit log | Composio captures all API calls | Auth proxy logs credential vends |
| Trust model | Trust Composio (third party) | Trust your own server |
| Network model | Container has no internet | Container has full internet (NAT) |

Pi Remote's model is deliberately simpler. No cloud dependency, no API call
proxying for external services. The trade-off: tokens briefly exist in
container memory during use. Acceptable for a personal server.

## Implementation order

1. **Switch to NAT networking** — remove --internal, update HOST_GATEWAY
   back to 192.168.64.1, keep auth proxy for AI credential isolation

2. **Integration credential store** — encrypted JSON, CRUD operations,
   OAuth token refresh

3. **Vending endpoint** — GET /integrations/:service/credential on auth proxy,
   session + workspace validation

4. **Container injection** — sandbox.ts writes .gitconfig, .npmrc, etc.
   based on workspace integrations

5. **OAuth callback endpoint** — server hosts /integrations/callback,
   handles code exchange

6. **iOS integration management** — Settings > Integrations, connect/disconnect,
   workspace integration toggles

7. **Wire protocol** — integration_connected/disconnected messages,
   workspace integration field in create/update

Steps 1-4 are server-only and testable from CLI. Step 5 adds the OAuth
flow. Steps 6-7 are the iOS UX.

## Open questions

**Encryption at rest.** integrations.json contains real OAuth tokens.
Options: macOS Keychain, age-encrypted file, or just strict file
permissions (600) since the server runs as the user. Start simple.

**Token refresh timing.** Refresh proactively before expiry (like the
existing auth proxy does for AI providers) vs. on-demand when the
credential helper calls. On-demand is simpler.

**Scope granularity.** GitHub supports fine-grained PATs with per-repo
permissions. Could the workspace config specify scopes? Or keep it
simple: the connected integration's scopes are what you get.

**Audit logging.** Every credential vend is logged (proxy already logs).
Should we surface this in the iOS app? "GitHub credential accessed 12
times this session." Nice to have, not v1.
