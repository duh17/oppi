# Server configuration

Operator guide for the Oppi server: config CLI, dictation, read aloud, push, MCP, project trust, and the auth module.

- Config file: `~/.config/oppi/config.json`
- Data directory: `~/.config/oppi/` (override with `OPPI_DATA_DIR` or `--data-dir`)

## Config CLI

```bash
oppi config show
oppi config get asr.sttEndpoint
oppi config set asr.sttEndpoint http://127.0.0.1:7936
oppi config validate
oppi config set --help
```

- Paths use dot notation (`tls.mode`, `runtimeEnv.TTS_BASE_URL`).
- `oppi config set` without enough arguments lists supported keys and current values. Run `oppi help config` or `oppi <command> --help` before an unfamiliar command.
- Unknown keys are ignored at startup and reported by `oppi config validate`.
- Keys marked *restart* below take effect only after `oppi server restart` (or stopping and starting a foreground `oppi serve`).

`oppi server restart` interrupts running sessions, which resume afterward ([Running sessions across a restart](#running-sessions-across-a-restart)). A setup session (Edit with Oppi) runs with host-user authority: inspect the current state before changing configuration, and tell the owner when a restart is required instead of restarting unasked.

Do not put these in config: owner tokens and pairing secrets (use `oppi pair` and `oppi token`), provider credentials (use the app's **Model Providers** screen, or, for a foreground `oppi serve` only, a provider API key environment variable such as `ANTHROPIC_API_KEY`), or per-workspace Agent and Skill content (use Agents, Skills, and workspace flows).

## Common operator keys

| Key | Notes |
| --- | --- |
| `port` / `host` | Listen address (restart) |
| `tls.mode` | `disabled`, `self-signed`, `tailscale`, `manual` (restart). `cloudflare` is not supported: terminate TLS at the proxy ([Reverse proxy](reverse-proxy.md)) |
| `publicUrl` | Phone-facing HTTPS origin, independent of the listener (restart) |
| `proxy.trustedPeers` | Immediate proxy peer CIDRs as Oppi sees them; rate-limit identity, including TLS origins (restart) |
| `asr.provider` / `asr.sttEndpoint` / `asr.sttModel` | Dictation backend (restart; see [Dictation](#dictation-asr--stt)) |
| `asr.liveVoiceBackend` | Live Voice: `yuwp` (local ASR from `asr.sttEndpoint`, speech from `tts`) or `grok-voice` (Grok uses the xAI `tts.voice`, else `eve`). No restart: each call reads `asr` and `tts` from disk. The app offers Live Voice only while this backend is ready ([Voice backend health](#voice-backend-health)) |
| `tts.provider` / `endpoint` / `model` / `voice` / `language` | Read aloud (restart; see [Read aloud](#read-aloud)) |
| `runtimeEnv.<NAME>` | Host runtime env, including TTS URLs (restart) |
| `extensions.voice.defaultVoiceId` | Default voice id for a voice extension |
| `push.mode` / `push.relays` | Push (restart; see [Push notifications](#push-notifications)) |
| `images.autoResize` | Phones resize images over 2000 px before upload (default `true`; `false` keeps originals and leaves resizing to Pi on the server) |
| `providerQuotas.openaiUseCodexPlan` | Opt in to legacy Codex plan-wide usage on the OpenAI row (default `false`; restart; see [Provider quotas](provider-quotas.md)) |
| `auth.tailscalePairing` | Same-user Tailscale pairing; `false` turns it off (default `true`; restart; see [Onboarding](onboarding.md#turn-off-tailscale-pairing)) |
| `auth.module` | Absolute path to an owner auth module (restart; see [Auth module](#auth-module)) |
| `autoTitle.enabled` / `autoTitle.model` | Automatic session titles |
| `serverMetrics.enabled` | Server and host samples behind **Server Metrics** (default `false`; the Server Settings toggle applies at once; see [Server Metrics](#server-metrics)) |
| `experimental.serverDurable` | Offer durable sessions (restart; [Using Oppi](usage.md#durable-sessions-experiment)) |

## Dictation (ASR / STT)

Server dictation needs `asr.provider: xai` or a non-empty Yuwp-compatible `asr.sttEndpoint`. Unset both to disable it.

```bash
# Local Yuwp (or any compatible streaming session API)
oppi config set asr.sttEndpoint http://127.0.0.1:7936
oppi config validate
oppi server restart

# xAI/Grok, using existing provider auth (Model Providers sign-in in the app, or XAI_API_KEY)
oppi config set asr.provider xai
oppi server restart
```

- Yuwp and xAI stream real partials. OpenAI batch dictation is not supported; replace old `openai` or `openai-codex` ASR config with Yuwp/http or xAI. Invalid provider config disables dictation at startup. Leftover `asr.backend: pi-extension` and `asr.extension` values are ignored. See [Dictation / ASR](../server/docs/asr.md).
- The app uses server dictation only while the server advertises it: an `http` backend must answer, and `xai` needs an xAI credential. Otherwise the mic records on-device ([Voice backend health](#voice-backend-health)).

## Dictation Dictionary

The server stores short vocabulary hints in **All Workspaces** and **This Workspace** lists. Edit them in iPhone Server Settings, a workspace's settings, or the CLI:

```bash
oppi dictionary list
oppi dictionary add --phrase 'Project name'
oppi dictionary add --workspace <id> --phrase 'Workspace term'
oppi dictionary list --workspace <id>
```

The lists are hints, not guaranteed corrections, and conversations are not harvested automatically; agents can inspect past sessions and add chosen phrases. On-device dictation can use them without sending phrases to the server. For server dictation, the iPhone has a separate, default-off consent to send selected phrases to the server and its speech provider. `oppi dictionary --help` covers batch input, removal, and workspace cleanup.

## Read aloud

The speaker under an assistant reply reads it aloud through the server and becomes a stop button while it plays. It appears once `tts` is configured, the server restarts, and the backend is ready ([Voice backend health](#voice-backend-health)).

| Key | Value |
| --- | --- |
| `tts.provider` | `yuwp` (Yuwp's `POST /v1/audio/speech` with `stream: true`; audio starts about 0.1 s after the request), `http` (OpenAI-compatible `POST /v1/audio/speech` returning WAV), or `xai` (Grok voice). Omitted: `xai` for an `api.x.ai` endpoint, else `http`. |
| `tts.endpoint` | Base URL. Required for `http` and `yuwp`; `xai` defaults to `https://api.x.ai`. |
| `tts.model` | Model id for `http` and `yuwp`. Omitted lets the backend choose. |
| `tts.voice` | Voice id, such as a saved Yuwp voice or a Grok voice like `eve`. Omitted uses the backend default. |
| `tts.language` | `xai` only: BCP-47 code or `auto` (default). |

```bash
# Local Yuwp server
oppi config set tts '{"provider":"yuwp","endpoint":"http://127.0.0.1:7938","voice":"elena"}'
# Grok voice, using the xAI credentials already set up for models or dictation
oppi config set tts '{"provider":"xai","voice":"eve"}'
oppi server restart
```

Code blocks, images, and URLs are skipped; link labels and list items are read. The server synthesizes a short first passage, then paragraph-sized ones, so playback starts before the reply is complete. Live Voice on the local backend speaks with this same engine and voice. Without `tts`, a local call listens and shows replies on screen but stays silent.

## Voice backend health

The app shows a voice feature only while its backend can serve it. `GET /server/info` reports one state per feature in `voiceBackends` and advertises the capability only when the state is `ready`.

| Feature | Capability | Backend |
| --- | --- | --- |
| Dictation (server engine) | `dictationStream` | `asr`, loaded at start |
| Read aloud | `speech` | `tts`, loaded at start |
| Live Voice | `liveVoice` | `asr.liveVoiceBackend` and `tts`, read from disk for each call, so no restart |

| State | Meaning |
| --- | --- |
| `not_configured` | Config names no backend. |
| `needs_credentials` | An xAI backend has no sign-in, stored API key, or `XAI_API_KEY`. |
| `checking` | An HTTP backend has no reachability result yet. |
| `unreachable` | An HTTP backend did not answer: connection refused, DNS failure, no answer within 1.5 s, or the last real request could not connect. |
| `ready` | Configured, credentialed, and (for HTTP) answering. |

- **xAI** backends are cloud services: a credential makes them `ready` and the server does not probe them.
- **HTTP** backends get one `GET` to the endpoint origin, and any HTTP response counts as reachable, so a wrong path (404) looks `ready` and a wrong port reads `unreachable`. Results are cached per origin for 15 seconds. `/server/info` never waits for a probe: it answers from the cache and starts one background probe when a result is missing or stale. The server also probes every configured origin once at start.
- A failed request reports back: one that cannot connect marks its origin `unreachable` at once, and a success marks it `ready`. An HTTP error from a backend that answered keeps it `ready` and sets `detail` to the status (for example `Last request failed: TTS backend returned 404`) until a request succeeds.
- Local Live Voice (`yuwp`, the default) needs `asr.sttEndpoint` reachable and, when `tts` is configured, a ready voice. Without `tts`, a call runs silent. `grok-voice` needs an xAI credential.
- An endpoint that is not an `http` or `https` URL reads `unreachable` with no `target`, so a string with credentials in it is never shown.

The app reads `/server/info` when it connects, on each return to the foreground, and after a failed read aloud. If any entry says `checking` or `unreachable`, it reads once more 2 seconds later, after the probe settles. The speaker disappears after a failure, and the failed reply keeps the reason until the next read aloud or until it scrolls away. The mic always works: with Engine set to Server, a take uses server dictation only while `dictationStream` is advertised and otherwise records on-device. **Server Settings → About This Server → Voice** lists each entry with its state, target, and detail. A server that omits a capability (one older than 0.53.0, for example) shows no matching control.

## Voice extensions

Voice extensions synthesize speech for their own tools.

```bash
oppi config set runtimeEnv.TTS_BASE_URL http://127.0.0.1:7937
oppi config set extensions.voice.defaultVoiceId my-voice-id
oppi config validate
oppi server restart
```

`runtimeEnv.TTS_BASE_URL` is passed into the host process for a voice extension, and `extensions.voice.defaultVoiceId` is the saved default voice. Inspect with `oppi config get runtimeEnv` and `oppi config get extensions.voice`. Extension-specific auth and models stay in the extension's own settings.

## Push notifications

The server sends end-to-end-encrypted lock-screen alerts to paired iPhones and iPads through a push relay and Apple Push Notification service (APNs), once a phone turns push on. The server holds no Apple key and never talks to APNs. It encrypts each alert to a key only the phone holds, so the relay and Apple see ciphertext, never titles, session names, or questions. Design and threat model: [protocol/push/spec.md](../protocol/push/spec.md).

Push needs no server setup. The server offers it through Oppi's relay by default and sends nothing until a phone opts in (**Server Settings → Notifications → Push Notifications**, off by default). The first time a session on the server finishes or needs an answer, All Sessions on the phone offers a one-time card that runs the same turn-on. With `push.mode` set to `off`, the switch and the card are both hidden.

| Key | Value |
| --- | --- |
| `push.mode` | `relay` (default) or `off`. `off` hides the phone's Push Notifications switch for this server. |
| `push.relays` | `[primary]` or `[primary, standby]` origins: `https`, or `http` on loopback for local testing; no path. Default `["https://push.oppi.chaosdonkey.dev"]`. |

Restart after changing `push`. `push.oppi.chaosdonkey.dev` is the only relay that reaches App Store and TestFlight builds, because a relay needs the APNs key of the team that signs the app. Set `push.relays` only if you build and sign Oppi yourself; then run the relay from `relay/` (Node or Cloudflare Workers) with your team's key ([relay/README.md](../relay/README.md)). Pushes go to the primary; network errors, timeouts, and `5xx` move to the standby, which must accept the primary's send tokens.

**Alerts.** Three kinds, each at most once a minute per session. A device with an open app or session stream is skipped for a Needs-you alert, because it already shows the question.

| Alert | When | Notes |
| --- | --- | --- |
| **Needs you** | A session, subagents included, starts waiting on an approval (**Needs Approval**), a question (**Question**), or a sign-in (**Sign-in Needed**) | The body is the question or the first line of the approval or dialog title, never the command or tool input. Plays a sound and is Time Sensitive, so it can break through a Focus. |
| **Failed** | A top-level session's run stops with an error after automatic retries | Plays a sound. |
| **Agent message** | The agent calls its `notify` tool with a finished result for you to read | Title up to 80 characters, body up to 200. Top-level sessions get `notify` only while a device has push on for this server; a session picks up a change when it starts, resumes, or reloads. The tool tells the agent to use it only for a finished result, a decision outside a question, or something you asked to be notified about, never progress. |

Agent messages, Failed alerts, and new-device notices are ordinary notifications and wait behind a Focus. A new device's pairing approval is Time Sensitive. A run that simply finishes or is stopped, a failed model call that retry recovers, a subagent finishing (its lead hears about it), and a session ending do not push. The session name is capped at 40 characters. App Lock and scoped locks hide the session name, question, and agent words on the phone.

**Badge.** The number on Oppi's icon counts sessions waiting on you (approval, question, or sign-in, subagents included, on every paired server), each once. It drops when one stops waiting, at once while Oppi is open and otherwise at the next open. Failed runs and agent messages do not add to it. The [Live Activity](#live-activity) counts per thread instead, so a lead and its subagent both waiting are 2 on the badge and 1 on the card.

**Registration and limits.** A device that opts in registers its push public key and relay send token, signed by its pairing key, together with the alert types its app can open; the server sends it nothing else. The server stores it with that device in `config.json` (`pushRegistrations`; `oppi config show` redacts it). Revoking the device or rotating the owner token removes it and asks the relay to release the send token, and a `410` from the primary relay removes it too. A device with no push key gets nothing, with no unencrypted fallback. Each device gets at most 100 pushes a UTC day from this server (alerts and Live Activity updates together) and 10 alerts a minute; Live Activity updates stop at 70 so 30 stay for alerts, and Failed, agent, and new-device alerts stop at 90 a day and 8 a minute so approvals and questions always have room. These limits are preliminary and may change. A relay `429`, or `503 relay_capacity` with `Retry-After`, pauses that device until the time it names; pushes over a limit are dropped and logged as `push.device_budget_exhausted`, and the budget restarts with the server.

### Live Activity

Unless push is off, the server also keeps each opted-in phone's Live Activity current while Oppi is closed. The card shows counts only, per thread (a top-level session with its subagents): threads that need you and threads running. A lead that idles while its subagents work counts as running, once. Users turn it on per server in **Server Settings → Notifications → Live Activities** (off by default); with push off for that server the card updates only while Oppi is open. The phone decides which servers may update its card, and the relay answers any other server `409 no_activity`. There is no server setting beyond `push`.

- **Sent:** the event (`start`, `update`, or `end`) and the two counts, in plain text to the relay, which fills a fixed ActivityKit template. No session names, IDs, or text. Apple and the relay can read the counts and their timing ([spec](../protocol/push/spec.md#36-live-activity)).
- **When:** only when the card's counts change, at most once a minute per device, and only while the device holds no app-event or session stream. Work starting with no card starts one (with Apple's required alert, "Oppi: Agents are working."), and nothing running or waiting ends it within about 30 seconds. Apple ends a card after 8 hours, so the server ends and restarts it before then while work continues. The relay refuses a start for a dismissed card or an unlisted server, and the server then sends no start until nothing runs.
- **Stop and restart:** stopping the server (`oppi server stop`, `oppi server uninstall`, or Ctrl-C in a foreground `oppi serve`) sends one best-effort `end` to each away device whose card is up, waiting at most 3 seconds in all. Revoking a device does the same for it. A restart (`oppi server restart`, the in-app update, launchd, or Docker restarting) keeps the cards, and a minute after start the server reconciles each device once.
- **Limits (preliminary):** Live Activity pushes share the device's 100 a day with alerts, which come first. Starts and updates stop at 70, and a start needs two free slots so its end fits. An end is never refused for the daily 100 and has an overdraft of 8.

## MCP servers, codemode, and tool search

Managed host sessions load Pi's built-in MCP, `codemode`, and `tool-search` extensions by default, like a Pi CLI session. Sandbox sessions load only the MCP servers you pick for them ([MCP servers in a sandbox](sandbox.md#mcp-servers-in-a-sandbox)). No Oppi config flag controls this, and sessions pick the built-ins up when they start.

- **Servers** come from Pi's global `~/.pi/agent/mcp.json` (and a project `.pi/mcp.json` once Pi trusts the project). Credentials live in Pi's `~/.pi/agent/mcp-auth.json`; Oppi keeps no second store.
- **Tools** are named `mcp__<server>__<tool>` and follow each server's `exposure` setting (`codemode` by default, so tools are reached through the `codemode` tool). Every call, including calls from codemode scripts, goes through the normal tool pipeline, so permission extensions apply.
- **Turn one off** with `"extensions": ["-builtin:mcp"]` (or `-builtin:codemode`, `-builtin:tool-search`) in Pi settings. An Agent with an exact extension selection loads a built-in only if it selects `builtin:mcp`, `builtin:codemode`, or `builtin:tool-search` in `resources.extensionIds` (for example `oppi agent create --extensions builtin:mcp,builtin:codemode`); that overrides the exclusion.
- **Keep one on:** `codemode` and `tool_search` are registered off, and MCP servers turn them on when their exposure needs them. To keep one on in every session, switch it on under **Pi → Tools → Optional Pi Tools**, which writes Pi's `defaultTools` (`["+codemode"]` with Pi's standard tools). The list shows only tools the loaded extensions register off, so a built-in turned off with `-builtin:<name>` is not listed.
- **Stdio servers** run as host processes with your authority; configure only servers you trust. A normal session stop closes them. If another extension's shutdown handler hangs past five seconds, Oppi force-disposes the session without closing MCP servers, so a stdio server can outlive it; stop it from a host shell.
- Sandbox workspaces load only the global servers ticked for them, and terminal-owned Mirror sessions are untouched.

**Sign in from the phone.** Open **MCP Servers** in the sidebar (global servers) or **Workspace Settings → MCP Servers** (that workspace's servers), select a server, and choose **Sign In**. Open the authorization page (it follows **Settings → Open Links**) and paste the full loopback callback into Oppi. You can also run `pi mcp login <server>` on the host; a running session picks up the new credentials on its next turn. In-session `/mcp login <server>` shows the authorization URL in a phone notification and takes a pasted redirect URL through an input dialog, holding that session's prompt while it waits; Pi's five-minute callback timeout ends the wait. This fallback has not been tested against a live OAuth provider.

### Project trust in managed host sessions

Before loading protected project resources, Oppi checks user-level `project_trust` extension handlers, then Pi's saved decisions in `~/.pi/agent/trust.json` (the closest parent wins), then the `defaultProjectTrust` setting (`always` allows, `never` declines).

Trust protects `.pi/settings.json`, `.pi/mcp.json`, `.pi/extensions`, `.pi/skills`, `.pi/prompts`, `.pi/themes`, `.pi/SYSTEM.md`, `.pi/APPEND_SYSTEM.md`, and project `.agents/skills`. A bare `.pi` folder does not prompt, and context files such as `AGENTS.md` still load. Trust controls resource loading, not tool permissions or filesystem confinement. A project with no protected resources needs no decision; if one appears mid-session (for example `.pi/mcp.json`), the next `/reload` resolves trust first.

With `ask`, the phone shows **Trust (remember)**, **Trust this session**, or **Don't trust (remember)**. Remembered choices use Pi's store, shared with the CLI. Dismissing, or no answer within 15 seconds, allows this session without saving. Session-only decisions persist through `/reload`, and a new runtime asks again.

Only a start with a phone attached before the runtime starts can prompt: opening a new or stopped session. Every other start is headless and uses a remembered decision, or allows without prompting when none exists (and does not remember that). That covers Resume (including after a server restart), scheduled starts, and `oppi session` starts.

An Agent with an exact extension selection runs only its selected user-level handlers in the trust bootstrap; project extensions cannot run until trust is resolved. Launch preflight checks extension availability without executing factories or installing packages, treating project settings as trusted. That is an availability check, not a trust grant: start resolves trust and fails closed on an unavailable project selection, so its error can arrive after preflight.

**Workspace Settings** shows the answer as **Project Trust**, from the saved decision and `defaultProjectTrust` (it cannot predict a `project_trust` handler): **Trusted**, **Asks at session start**, or **Not trusted**. Skills, Extensions, and MCP Servers follow it. With **Asks at session start**, project items show as loading, because an unanswered prompt allows them. With **Not trusted**, project skills and extensions are not listed and their toggles are off (the server refuses them with `409`). Change a remembered **Don't trust** in Pi on the host.

Pi's host MCP commands (`pi mcp list`, `login`, `logout`), which the MCP Servers view uses for live status and sign-in, read a project `.pi/mcp.json` only after a remembered **Trust**. They ignore `defaultProjectTrust` and session-only answers. Without a remembered Trust, project servers show **Needs remembered trust** and sign-in is off, even when sessions load them. Choose **Trust (remember)** when a session asks, or trust the project in Pi on the host.

## MCP Servers view

MCP servers are managed where they load:

- **MCP Servers** in the workspace sidebar lists Pi's global `~/.pi/agent/mcp.json`. Global servers load in every host workspace.
- **Workspace Settings → MCP Servers** lists that workspace's `.pi/mcp.json`, then, read-only under **From Global**, the global servers that also load there. A global server that a same-name project server replaces shows **Replaced by project**. Project servers follow the workspace's [project trust](#project-trust-in-managed-host-sessions). A host workspace created without a folder gets one under `<dataDir>/workspaces/<name>`. In a sandbox workspace the page lists the global servers with a toggle for each one the sandbox may load, and a reason for any that cannot run there.

Each list runs one live probe in its own folder; pull to refresh to probe again. Select a server to see its tools and errors, enable or disable it, change exposure, sign in or out, or remove it. **+** adds a URL or command server to the list you are viewing. Use `${NAME}` references for headers, environment variables, and client secrets, because literal values and URL query values are redacted when read back and command arguments are shown as stored. Adding an existing name in the same scope is rejected; remove it first. Changes apply to new sessions or `/reload`.

For OAuth, choose **Open Sign-In Page**. After approval the browser might fail to load the loopback callback; copy the full `http://127.0.0.1:<port>/callback?...` URL and paste it into Oppi, which sends it only to this flow's waiting host listener. Leaving the screen keeps the flow available through **Continue Sign-In** and **Cancel Sign-In** on any MCP Servers list. While a sign-in is active, the list shows the last probe, and add, remove, enable, exposure, and sign-out changes are refused until it ends. A browser on the host can also complete the callback. Credentials stay in Pi's host-side store.

## Server Metrics

**Server Metrics** in the host pill menu shows the server's CPU, memory, and disk (the volume holding the data directory) and the Oppi process's CPU, memory, sessions, and connections over the last hour, 24 hours, 7 days, or 30 days. Press and drag a chart to read a past value.

Sampling is opt-in and off by default; off runs nothing (no timer, reads, or files) and the menu item is hidden. Turn it on with the **Server Metrics** switch in Server Settings (applies at once) or `oppi config set serverMetrics.enabled true` (applies at restart).

When on, the server takes one sample every 30 seconds (about 1 ms of work) and keeps 30 days of samples, about 1.2 MB a day (`OPPI_SERVER_METRICS_RETENTION_DAYS` changes it). Samples stay in the `diagnostics/telemetry/` directory and also feed the optional Grafana dashboards. The app reads samples only while the page is open: the 1-hour and 24-hour views refresh every 30 seconds, and the 7-day and 30-day views load once and refresh when pulled. Turning sampling off stops new samples; files already written stay until they pass retention, and expired files are removed when you turn it off and at each server start.

| Server runs on | Section | CPU | Memory |
| --- | --- | --- | --- |
| macOS | Host | All cores, with load average | Activity Monitor's Memory Used (app, wired, compressed) |
| Linux | Host | All cores, with load average | Total minus available, like `free` |
| Linux container | Container | The container's CPU limit, or every CPU without one | Usage minus file cache against the memory limit, like `docker stats` |

In a container, disk is the volume mounted at the data directory. Docker Desktop bind mounts from a Mac can report the shared folder's size wrongly; a named volume reports the VM disk.

## Running sessions across a restart

Sessions that were running when the server stopped come back when it starts again. This covers a normal stop or restart, an in-app update, and a crash or kill.

- Every running Oppi session resumes, one at a time, after the server is listening.
- A session that was mid-turn also gets a short message saying the server restarted and asking the agent to continue. Tool calls and background jobs that were running were stopped, so the agent is told to re-check them.
- Opening a session, or the app reconnecting, does not cancel that message. Sending the session a message, or stopping it, does: your message or stop wins.
- The message is best effort. If the session already runs a turn or refuses it, it is queued as a follow-up.
- A session that was being stopped stays stopped. Incognito and Pi TUI mirror sessions are not resumed, and a session whose workspace was deleted is skipped.

`server.log` records `session_restart.recorded`, `session_restart.resumed`, `session_restart.resume_failed`, and a `session_restart.resume_complete` summary, logged even when nothing was queued.

## Auth module

`auth.module` names an ES module, by absolute path, that adds owner policy to network access. It exports at least one of these functions; each can be async:

```js
// Admit or refuse every network request (HTTP, including /health and pairing, and every
// WebSocket upgrade) before the device token is checked. The owner Unix socket skips it.
export function gate(req) {
  // req: { transport: "http" | "ws", method, path, headers, clientIp? }
  return req.headers["cf-access-jwt-assertion"] ? { allow: true } : { allow: false, status: 403, reason: "Forbidden" };
}

// Approve a pairing that has no invite: POST /pair with { devicePublicKey, deviceName, credential }.
export async function approvePairing(req) {
  // req: { method: "custom", deviceName, devicePublicKey, keyThumbprint, credential, clientIp?, headers }
  return req.credential === process.env.MY_PAIRING_SECRET
    ? { allow: true, source: "my-sso" }
    : { allow: false, reason: "bad credential" };
}
```

- A refused gate answers `status` (default `403`) with `{"error": reason}` (default `Forbidden`). A gate that throws answers `403`.
- An `approvePairing` that throws or does not return `{ allow: true }` denies with `403`. An allowed custom pairing still alerts the other devices and, once another device is paired, waits for approval on one of them ([Onboarding](onboarding.md#approving-a-new-device)).
- The module loads once at startup; restart to change it. If it cannot load (missing file, import error, a relative path, no `gate` or `approvePairing`, or a non-function export), the server keeps running but every network request answers `503 {"error":"auth_module_unavailable"}` and the log shows `auth.module_load_failed`. It never falls back to running without the module. The owner Unix socket and the `oppi` CLI keep working, so you can fix the path.
- Device keys, access tokens, refresh, revocation, and owner Unix-socket auth are not pluggable.

## Updating the server

A global npm install updates from iPhone **Server Settings → About This Server** or with `oppi update` ([Using Oppi](usage.md#server-settings)). Git checkouts use `git pull && npm install && npm run build`; a checkout linked with `setup.sh --install` can also be rebuilt and restarted from About This Server.
