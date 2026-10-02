# Server configuration

Operator guide for the local Oppi server: config CLI, dictation (ASR), voice/TTS runtime settings, and extensions.

Config file: `~/.config/oppi/config.json`
Data directory: `~/.config/oppi/` (override with `OPPI_DATA_DIR` or `--data-dir`)

## Config CLI

```bash
oppi config show
oppi config get asr.sttEndpoint
oppi config set asr.sttEndpoint http://127.0.0.1:7936
oppi config validate
oppi config set --help
```

- Paths use dot notation (`tls.mode`, `runtimeEnv.TTS_BASE_URL`).
- `oppi config set` without enough arguments lists supported keys and current values.
- Unknown keys are ignored on startup and reported by `oppi config validate`.
- Many keys need a **server restart** before they take effect (`asr`, `tls`, `port`, `host`, `publicUrl`, `proxy`, `runtimeEnv`, `providerQuotas`). `tls.mode=cloudflare` is not supported; terminate TLS at the reverse proxy and set `publicUrl` plus `proxy.trustedPeers`.

## Dictation (ASR / STT)

Local Yuwp (or any compatible streaming session API):

```bash
oppi config set asr.sttEndpoint http://127.0.0.1:7936
oppi config validate
oppi server restart   # or restart `oppi serve`
```

xAI/Grok, using existing Pi/Oppi provider auth (same as models: `pi auth`, Settings login, or `XAI_API_KEY`):

```bash
oppi config set asr.provider xai
oppi config validate
oppi server restart
```

- Set `asr.provider` to `xai`, or set a non-empty Yuwp-compatible `asr.sttEndpoint`, to enable server dictation. Unset those to disable.
- Yuwp and xAI stream real partials. OpenAI batch dictation is not supported; replace old `openai` / `openai-codex` ASR config with Yuwp/http or xAI. Invalid provider config disables dictation on startup. Codex LLM/auth/quota behavior is unchanged. See [Dictation / ASR](../server/docs/asr.md).
- Leftover `asr.backend: pi-extension` and `asr.extension` values are ignored on load.
- The Apple app learns dictation availability from the server identity payload after pairing.

Inspect:

```bash
oppi config get asr
oppi config get asr.sttEndpoint
oppi config get asr.provider
```

## Dictation Dictionary

The paired server stores short vocabulary hints in **All Workspaces** and **This Workspace** lists. Edit the same lists in iPhone Server Settings, a workspace's settings, or the CLI:

```bash
oppi dictionary list
oppi dictionary add --phrase 'Project name'
oppi dictionary add --workspace <id> --phrase 'Workspace term'
oppi dictionary list --workspace <id>
```

Agents can inspect past sessions and add selected phrases with `oppi dictionary`; conversations are not harvested automatically. The lists are hints, not guaranteed corrections. On-device dictation can use them without sending phrases to server ASR. For server dictation, the iPhone has a separate, default-off consent to send selected phrases to the paired server and its configured speech provider. Use `oppi dictionary --help` for batch input, removal, and workspace cleanup.

## Voice / TTS

TTS is not a single built-in endpoint. Extensions provide synthesis. Common server-side pieces:

| Setting                           | Purpose                                                                |
| --------------------------------- | ---------------------------------------------------------------------- |
| `runtimeEnv.TTS_BASE_URL`         | Runtime env passed into the Oppi/Pi host process for a voice extension |
| `extensions.voice.defaultVoiceId` | Saved default voice id for the voice extension                         |

```bash
oppi config set runtimeEnv.TTS_BASE_URL http://127.0.0.1:7937
oppi config set extensions.voice.defaultVoiceId my-voice-id
oppi config validate
oppi server restart
```

Use `oppi config get runtimeEnv` and `oppi config get extensions.voice` to inspect. Extension-specific auth and models stay in the extension docs or its settings, not in core Oppi config.

## Extensions

Server-global Skills and Extensions are managed from the Apple app (**Skills** / **Extensions** destinations) and follow Pi user-scope resource rules. Read [extensions.md](extensions.md) for:

- how managed sessions discover Pi extensions
- the server-scoped Mobile Output Guide
- native extension UI expectations

Useful companion docs:

- [extension-native-ui.md](extension-native-ui.md) — mobile-safe extension UI surfaces
- [onboarding.md](onboarding.md) — install, pair, LAN vs Tailscale, and `oppi status` / `oppi doctor`

Provider API keys use `pi auth`, not Oppi config.

## MCP servers, codemode, and tool search

Pi 0.99 ships built-in MCP, `codemode`, and `tool-search` extensions. Managed sessions load all three by default, like a Pi CLI session; sandbox sessions load only the MCP servers you pick for them (see [MCP servers in a sandbox](sandbox.md#mcp-servers-in-a-sandbox)). There is no Oppi config flag for this. Sessions pick the built-ins up when they start.

Oppi follows Pi's own setup:

- Servers come from Pi's global `~/.pi/agent/mcp.json` (and a project `.pi/mcp.json` once Pi trusts the project). Credentials live in Pi's `~/.pi/agent/mcp-auth.json`. Oppi keeps no second store.
- Tools are named `mcp__<server>__<tool>` and follow each server's `exposure` setting (`codemode` by default, so tools are reached through the `codemode` tool). Every call, including calls made from codemode scripts, goes through the normal tool pipeline, so permission extensions apply.
- `"extensions": ["-builtin:mcp"]` (or `-builtin:codemode`, `-builtin:tool-search`) in Pi settings turns one off in discovery mode. An exact-selection Agent that explicitly selects a built-in overrides this exclusion.
- `codemode` and `tool_search` are registered off. MCP servers turn them on when their exposure needs them. To keep one on in every session, switch it on under **Pi → Tools → Optional Pi Tools** in the app, which writes Pi's `defaultTools` (`["+codemode"]` while Pi's standard tools are in use). That section lists every tool the loaded extensions register off, so a built-in turned off with `-builtin:<name>` disappears from it.
- Stdio servers run as processes on the host with your authority. Configure only servers you trust. A normal session stop closes its stdio servers. If another extension's shutdown handler hangs past five seconds, Oppi force-disposes the session and Pi does not get to close MCP servers, so a stdio server can outlive the session; stop it from a host shell.

Limits:

- **Sandbox workspaces** load only the global servers ticked for them. HTTP servers connect from the host only to Allowed Hosts; stdio servers run inside the VM and never receive host secrets. See [MCP servers in a sandbox](sandbox.md#mcp-servers-in-a-sandbox).
- Terminal-owned Pi mirror sessions are untouched.
- For phone MCP sign-in, open **MCP Servers** in the iOS sidebar (global servers) or in **Edit Workspace** (that workspace's servers), select a server, and choose **Sign In**. Open the authorization page in Safari and paste the full loopback callback into Oppi; see [MCP Servers view](#mcp-servers-view). Oppi does not open a host browser for phone sign-in. You can also sign in from a host shell with `pi mcp login <server>`; a running session picks up the new credentials on its next turn. In-session `/mcp login <server>` shows the authorization URL in a phone notification and accepts a pasted redirect URL through an input dialog. It holds that session's prompt while waiting. Pi's five-minute callback timeout ends the wait and aborts the paste dialog; the input itself has no separate timeout and can be dismissed. This fallback has not been tested against a live OAuth provider.
- A saved Agent with an exact Extension selection loads a built-in only if it selects `builtin:mcp`, `builtin:codemode`, or `builtin:tool-search` in `resources.extensionIds` (for example `oppi agent create --extensions builtin:mcp,builtin:codemode`).

### Project trust in managed host sessions

Before loading protected project resources, Oppi checks user-level `project_trust` extension handlers, then Pi's saved decisions in `~/.pi/agent/trust.json` (the closest parent wins), then the agent-directory `defaultProjectTrust` setting. `always` allows and `never` declines when no earlier decision applies.

An Agent with an exact Extension selection runs only its selected user-level handlers in the trust bootstrap. Project extensions cannot run until trust is resolved. Agent launch preflight checks Extension availability without executing factories or installing missing packages, using project settings as if trusted. This is an availability check, not a trust grant: start resolves trust and rejects unavailable project selections before loading them. Such a launch fails closed, but its error can arrive after preflight.

With `ask`, the phone shows **Trust (remember)**, **Trust this session**, or **Don't trust (remember)**. Remembered choices use Pi's store, shared with the CLI. Dismissal or no answer within 15 seconds allows this session without saving a decision.

Only a start that has a phone attached before the runtime starts can prompt: opening a new or stopped session through the focused stream. Every other start is headless and uses a remembered decision, or allows without prompting when none exists. That covers Resume (`POST /sessions/:id/resume`, including the phone Resume button), Resume after a server restart, and scheduled and `oppi session` starts. A headless allow is not remembered.

Session-only decisions persist through `/reload`, and a new runtime resolves trust again. A project with no protected resources needs no decision. If an agent or you add one during a session (for example `.pi/mcp.json`), the next `/reload` resolves trust before loading it.

Trust protects `.pi/settings.json`, `.pi/mcp.json`, `.pi/extensions`, `.pi/skills`, `.pi/prompts`, `.pi/themes`, `.pi/SYSTEM.md`, `.pi/APPEND_SYSTEM.md`, and project `.agents/skills`. A bare `.pi` folder does not trigger the prompt. Context files such as `AGENTS.md` still load. Oppi creates or reopens the session file before resolving trust; it does not use the project's `sessionDir` setting for that lookup. Trust controls resource loading, not tool permissions or filesystem confinement. Sandbox and terminal-owned mirror behavior is unchanged.

**Edit Workspace** shows the same answer once under **Project Trust**, from the saved decision and `defaultProjectTrust` (it cannot predict a `project_trust` handler): **Trusted**, **Asks at session start**, or **Not trusted**. Pi Skills, Pi Extensions, and MCP Servers for that workspace all follow it. With **Asks at session start**, project items are listed as loading, because an unanswered prompt allows the session. With **Not trusted**, project skills and extensions are not listed and their toggles are off (the server refuses them with `409`). Change a remembered **Don't trust** in Pi on the host.

Pi's host MCP commands (`pi mcp list`, `login`, `logout`), which the MCP Servers view uses for live status and sign-in, read a project `.pi/mcp.json` only after a remembered **Trust**. They ignore `defaultProjectTrust` and session-only answers. Without a remembered Trust, project MCP servers show **Needs remembered trust** and sign-in is off, even when the workspace shows **Trusted** through `defaultProjectTrust: "always"` and sessions load them. Choose **Trust (remember)** when a session asks, or trust the project in Pi on the host.

## Common operator keys

| Key                                     | Notes                                                               |
| --------------------------------------- | ------------------------------------------------------------------- |
| `port` / `host`                         | Listen address (restart)                                            |
| `tls.mode`                              | `disabled`, `self-signed`, `tailscale`, `manual` (restart)          |
| `publicUrl`                             | Phone-facing HTTPS origin, independent of the listener (restart)    |
| `proxy.trustedPeers`                    | Immediate proxy peer CIDRs as Oppi sees them; rate-limit identity including TLS origins (restart) |
| `asr.sttEndpoint`                       | HTTP/Yuwp dictation STT base URL (restart)                          |
| `asr.provider`                          | `http` or `xai` (restart)                          |
| `asr.sttModel`                          | HTTP/Yuwp STT model id (restart)                                      |
| `runtimeEnv.<NAME>`                     | Host runtime env, including TTS URLs (restart)                      |
| `extensions.voice.defaultVoiceId`       | Default voice id                                                    |
| `images.autoResize`                     | Client image preprocessing preference                               |
| `providerQuotas.openaiUseCodexPlan`     | Opt in to legacy Codex plan-wide usage on the OpenAI row; same account required (default `false`; restart; see [provider quotas](provider-quotas.md)) |
| `autoTitle.enabled` / `autoTitle.model` | Automatic session titles                                            |

After config changes that need a restart:

```bash
oppi server restart
# or stop/start a foreground `oppi serve`
```

`oppi server restart` is operator-only. A Pi Control session runs with host-user authority, so inspect the current state before changing configuration and tell the user when a restart is required.

### Running sessions across a restart

Sessions that were running when the server stopped come back when it starts again. This covers a normal stop or restart, an in-app update, and a crash or kill.

- Every running Oppi session is resumed, one at a time, after the server is listening.
- A session that was in the middle of a turn also gets a short message saying the server restarted and asking the agent to continue. Tool calls and background jobs that were running at the time were stopped, so the agent is told to re-check them.
- Opening a session, or the app reconnecting to it, does not cancel the continue message. Sending the session a message or stopping it does: your message or stop wins.
- The continue message is best effort. If the session is already running a turn, or refuses the message, it is queued as a follow-up instead.
- A session that was being stopped when the server went down stays stopped. Incognito sessions and Pi TUI mirror sessions are not resumed. A session whose workspace was deleted is skipped.

The pending list lives in the `session_restart_resume` table of `session-state.db` until each session is resumed, so a crash during the resume keeps the rest. `server.log` records `session_restart.recorded`, `session_restart.resumed`, `session_restart.resume_failed`, and a `session_restart.resume_complete` summary, which is logged even when nothing was queued.

## MCP Servers view

MCP servers are managed where they load, like Pi extensions:

- **MCP Servers** in the iOS workspace sidebar lists Pi's global `~/.pi/agent/mcp.json`. Global servers load in every host workspace.
- **Edit Workspace → MCP Servers** lists that workspace's own `.pi/mcp.json` in the folder its sessions use, then, read-only under **From Global**, the global servers that also load there. A global server that a same-name project server replaces shows **Replaced by project**. Project servers follow the workspace's [project trust](#project-trust-in-managed-host-sessions); live status and sign-in need a remembered **Trust**. A host workspace without a folder uses the server home folder like its sessions, so its project file is `~/.pi/mcp.json`, shared by every workspace without a folder. In a sandbox workspace, this section instead lists the global servers with a tick for each one the sandbox may load and a reason for any that cannot run there; the ticks save with **Save**.

Each list runs one live probe in its own folder (`GET /mcp/scopes/{scopeId}/servers`, where `scopeId` is `global` or a workspace id). Pull to refresh for a live probe.

Select a server to see its tools and errors, enable or disable it, change exposure, sign in or out, or remove it. Use **+** to add a URL or command server to the list you are viewing. Use `${NAME}` references for headers, environment variables, and client secrets; literal values and URL query values are redacted when read back. Command arguments are shown as stored: keep secrets in `${NAME}` environment references, not arguments. Adding an existing name in the same scope is rejected; remove it first to add a replacement. Configuration changes apply to new sessions or `/reload`.

For OAuth, open the sign-in page in Safari. After approval, Safari might fail to load the loopback callback. Copy the full `http://127.0.0.1:<port>/callback?...` URL from Safari and paste it into Oppi. Oppi sends it only to this flow's waiting host listener. **Close**, returning from the server detail, and opening another sidebar item and coming back keep the flow available through **Continue Sign-in** and **Cancel Sign-in** on any MCP Servers list: the host reports its active sign-in with every scope's list. While a sign-in is active the list shows the last live probe (Refresh does not probe, so it cannot disturb the credential file the sign-in is writing) and add, remove, enable, exposure, and sign-out changes are refused until the sign-in ends. **Cancel Sign-in** stops it. A browser on the host can also complete the callback directly. OAuth credentials stay in Pi's host-side credential store.

## Updating the server

A global npm install can be updated from iPhone **Server** settings or with `oppi update`. See [Server settings](usage.md#server-settings). Git checkouts still use `git pull && npm install && npm run build`.

## What not to put in config

- Owner tokens and pairing secrets (use `oppi pair` / `oppi token`)
- Provider credentials (use `pi auth`)
- Per-workspace Agent/Skill content (use Agents, Skills, and workspace flows)

When unsure about a flag or subcommand, run nested help first:

```bash
oppi help config
oppi config set --help
oppi help
```
