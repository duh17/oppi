# Server configuration

Operator guide for the local Oppi server: config CLI, dictation (ASR), voice/TTS runtime settings, push notifications, and extensions.

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
- The Apple app uses server dictation only while the server advertises it: an `http` backend must answer, and `xai` needs an xAI credential (sign-in, stored API key, or `XAI_API_KEY`). Otherwise the mic records on-device. See [Voice backend health](#voice-backend-health).

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

## Read aloud

The speaker button under an assistant reply reads it aloud through the server; it turns into a stop button while that reply plays. It appears once `tts` is configured, the server restarts, and the backend is ready: an `http` or `yuwp` backend must answer, and an `xai` provider needs an xAI credential (sign-in, stored API key, or `XAI_API_KEY`). See [Voice backend health](#voice-backend-health).

| Key            | Value |
| -------------- | ----- |
| `tts.provider` | `yuwp` (Yuwp's `POST /v1/audio/speech` with `stream: true`: audio starts about 0.1 s after the request instead of after the whole passage), `http` (OpenAI-compatible `POST /v1/audio/speech` returning WAV), or `xai` (Grok voice). Omitted: `xai` for an `api.x.ai` endpoint, else `http`. |
| `tts.endpoint` | Base URL. Required for `http` and `yuwp`; `xai` defaults to `https://api.x.ai`. |
| `tts.model`    | Model id sent to an `http` or `yuwp` backend. Omitted lets the backend choose. |
| `tts.voice`    | Voice id, such as a saved Yuwp voice or a Grok voice like `eve`. Omitted uses the backend's default. |
| `tts.language` | `xai` only: BCP-47 code or `auto` (default). |

```bash
# Local Yuwp server, for example Fish Audio Drama 3
oppi config set tts '{"provider":"yuwp","endpoint":"http://127.0.0.1:7938","voice":"elena"}'

# Grok voice, using the xAI credentials already set up for models or dictation
oppi config set tts '{"provider":"xai","voice":"eve"}'

oppi server restart
```

Code blocks, images, and URLs are skipped; link labels and list items are read. The server synthesizes a short first passage and then paragraph-sized ones, so playback starts before the whole reply is ready. With `yuwp`, each passage's audio also streams while it is synthesized.

Live Voice on the local backend (`asr.liveVoiceBackend` `yuwp`) speaks with this same engine and voice. Without `tts`, a local call listens and shows the agent's replies on screen but stays silent.

## Voice backend health

The app shows a voice feature only while its backend can serve it. For each feature, `GET /server/info` reports one state in `voiceBackends` and advertises the matching capability only when that state is `ready`:

| Feature | Capability | Backend |
| ------- | ---------- | ------- |
| Dictation (server engine) | `dictationStream` | `asr` the server loaded at start |
| Read aloud (speaker under replies) | `speech` | `tts` the server loaded at start |
| Live Voice (long-press on the composer mic, in a chat and in Quick Session) | `liveVoice` | `asr.liveVoiceBackend` and `tts` on disk, read again for each request and each call, so `oppi config set` applies without a restart |

| State | Meaning |
| ----- | ------- |
| `not_configured` | Config names no backend. |
| `needs_credentials` | An xAI backend has no sign-in, stored API key, or `XAI_API_KEY`. |
| `checking` | An HTTP backend has no reachability result yet. |
| `unreachable` | An HTTP backend did not answer: connection refused, DNS failure, no answer within 1.5 s, or the last real request could not connect. |
| `ready` | Configured, credentialed, and an HTTP backend answered. |

How the server decides:

- **xAI** backends are cloud services. A credential makes them `ready`; the server does not probe them.
- **HTTP** backends get one `GET` to the endpoint origin. Any HTTP response counts as reachable, so a wrong path (404) looks `ready` and a wrong port reads `unreachable`. Results are cached per origin for 15 seconds; dictation and local Live Voice share the `asr.sttEndpoint` result.
- `/server/info` never waits for a probe. It answers from the cache and, when an origin's result is missing or older than 15 seconds, starts one background probe that concurrent requests share. The server probes every configured origin once at start and runs no timer.
- Read aloud and Live Voice replies report back. A request that cannot connect marks its origin `unreachable` at once. A successful request marks it `ready`. An HTTP error from a backend that answered keeps it `ready` and sets `detail` to the failure's status (for example `Last request failed: TTS backend returned 404`, without the backend's error body) until a request succeeds.
- Local Live Voice (`yuwp`, the default) needs `asr.sttEndpoint` reachable. When `tts` is configured, the voice must also be ready, and `detail` names the voice backend when it is not. Without `tts`, a call runs silent, so only `asr` counts. `grok-voice` needs an xAI credential.
- A read aloud that cannot reach its backend returns `Read aloud backend at <endpoint> is not reachable`.

What the app does:

- It reads `/server/info` when it connects, each time it returns to the foreground, and after a read aloud fails. Because `/server/info` does not wait for a probe, the read that starts one can still say `checking` or `unreachable`; when any `voiceBackends` entry says so, the app reads once more 2 seconds later, after the probe has settled. That follow-up read never schedules another, so a backend that stays down costs one extra request. A backend that comes back therefore shows its features on the same foreground.
- The speaker disappears after a failure. The reply whose read failed keeps the reason, without the speaker, until the next read aloud or until it scrolls off screen.
- An endpoint that is not an `http` or `https` URL reads `unreachable` with no `target`, so a string with credentials in it is never shown.
- The mic always works. With Engine set to Server, a take uses server dictation only while `dictationStream` is advertised; otherwise it records with on-device dictation. `stream_connected.serverDictationAvailable` only says dictation is configured; the app does not route by it.
- **Server Settings → About This Server → Voice** lists each `voiceBackends` entry with its label, state, target, and detail. The section is hidden for a server that sends no `voiceBackends`. A server that omits a capability, such as one older than 0.53.0, shows no matching control.

## Voice extensions

Voice extensions synthesize speech for their own tools. Common server-side pieces:

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

## Push notifications

The server sends end-to-end-encrypted lock-screen alerts to paired iPhones and iPads through a push relay and Apple Push Notification service (APNs), once a phone turns push on for it. The server never talks to APNs and holds no Apple key: the relay does. Content is encrypted on your server to a key that only the phone holds, so the relay and Apple see ciphertext, never titles, session names, or questions. [protocol/push/spec.md](../protocol/push/spec.md) is the full design, including what the relay can see.

The server needs no setup: it offers push through Oppi's relay by default, and sends nothing until a phone opts in (**Server Settings → Notifications**, **Push Notifications**, off by default). Only then does the app register with APNs and the relay, ask for notification permission, and send this server its push key. `/server/info` advertises `capabilities.pushNotifications` with the primary relay unless push is off.

| Key | Value |
| --- | --- |
| `push.mode` | `relay` (default) or `off`. `off` hides the phone's Push Notifications switch for this server. |
| `push.relays` | `[primary]` or `[primary, standby]` origins: `https`, or `http` on loopback for local testing. No path. Default: `["https://push.oppi.chaosdonkey.dev"]`. |

Restart the server after changing `push`.

`https://push.oppi.chaosdonkey.dev` is Oppi's relay, and the only one that reaches App Store and TestFlight builds: a relay needs an APNs key from the Apple Developer team that signs the app. Set `push.relays` only if you build and sign Oppi yourself; then run the relay in `relay/` (Node, or Cloudflare Workers) with your team's key. See [relay/README.md](../relay/README.md).

What the server does:

- **Registrations:** each paired device that opts in sends its X25519 push public key and a relay send token, signed by its pairing key, plus the alert types its app can open (`PUT /me/push-registration`). The server sends a device no other type, so an app that does not know an alert never gets a push it could show only as "You have a new notification." The server stores them with that device (`pushRegistrations` in `config.json`; `oppi config show` redacts them). Revoking the device or rotating the owner credential removes them and asks the relay to release the send token. A relay `410` from the primary removes them too.
- **Encryption:** each push is a fixed-size envelope (HPKE with X25519, ChaCha20-Poly1305, built on Node's `crypto` module with no third-party crypto package) signed with the server's Ed25519 identity key, with a timestamp. The phone checks the signature and the timestamp, and rejects a repeat of any push it accepted in the last 70 minutes. The server keeps no per-push state and does not write `config.json` to send. A device without a push key gets nothing; there is no unencrypted fallback.
- **Limits (preliminary, may change):** each device gets at most 100 pushes a UTC day from this server, alerts and [Live Activity](#live-activity) updates together, and 10 alerts a minute, the same as the relay's per-phone quota. Live Activity updates stop at 70, so 30 always stay for alerts. Failed-run, agent, and new-device alerts stop at 90 a day and 8 a minute, so approvals, questions, and sign-ins always have room. A relay `429`, or a `503 relay_capacity` with a `Retry-After` in whole seconds (at most a day; the relay itself is at capacity), pauses that device's pushes until the time it names; any other `503` counts as unreachable. Pushes over the limit are dropped and logged as `push.device_budget_exhausted`; the budget restarts with the server. Why the relay's limits are what they are: [Limits](../relay/README.md#limits-and-why-they-are-set-this-way).
- **Relays:** pushes go to the primary. Network errors, timeouts, and `5xx` move to the standby. A standby must accept the primary's send tokens, for example the same Worker on a second hostname.
- **Events:** two alerts from a session's status, and one the agent sends on purpose. `SessionPushNotifier` decides all three.
  - **Needs you:** **Needs Approval**, **Question**, or **Sign-in Needed** when any session, subagents included, starts waiting on you. The body is what it waits on: the question, or the first line of the approval or dialog title (never the command, diff, or tool input shown below it). Plays a sound and is a Time Sensitive notification, so it can break through a Focus unless you turned Time Sensitive Notifications off for Oppi in iOS Settings.
  - **Failed:** **Session Failed** when a top-level session's run stops with an error after any automatic retries. Plays a sound.
  - **Agent message:** the agent's own title and one or two sentences, from the `notify` tool, when it has finished something for you to read. Top-level sessions get the tool only while at least one device has push turned on for this server; a session picks up a change when it starts, resumes, or reloads. The tool's instructions tell the agent to call it only for a finished result, a decision outside a question, or something you asked to be notified about ("notify me when the tests finish"), never for progress. Plays a sound. Agent messages, Failed alerts, and new-device notices are ordinary notifications: the agent cannot mark one Time Sensitive, so they wait behind a Focus. A new device's pairing approval is Time Sensitive, like Needs you.

  Each alert sends at most once a minute per session; a `notify` call inside that minute tells the agent it was not sent. Nothing else pushes: not a run that simply finishes or is stopped (the agent sends a message when there is something to read), not a failed model call that an automatic retry recovers, not a subagent finishing or failing (its lead hears about it), and not a session ending or timing out.
- **Presence:** Needs you skips any device that holds an open app-event or session stream, because that device already shows the question. Other devices still get the push, so an open Mac or iPad does not silence the phone. A stream that was never closed, because the app was suspended or lost its network, keeps its device present until the server's ping timeout drops it, up to about 90 seconds. A Needs you that arrives while a device is present is pushed to it when it stops being present, if the session blocked within the last two minutes and the device was not already alerted for it. A running, backgrounded app shows its own alert for a question or a confirm, input, or select dialog, so for those the push goes out only when the connection drops (not when the app closes the stream) and the session blocked after the last thing the device sent. A session waiting on an editor dialog, which the app does not alert for, is pushed whenever the device leaves. Failed and agent alerts go to every device; with Oppi open, the app shows them unless that session's chat is on screen.
- **Content:** a title, the session name, and a body, all inside the envelope. A Needs you body is the question or the dialog title's first line, and a Failed body is fixed text; an agent message carries the agent's words (title up to 80 characters, body up to 200; the agent is told when its body is shortened). The session name is capped at 40 characters and the body shortened, never the name, when they do not fit. On the phone, App Lock and scoped locks hide the session name, the question, and the agent's words. Logs record only outcomes such as `push.not_delivered` and `push.registration_pruned`.
- **App icon badge:** the number on Oppi's icon counts the sessions waiting on you — an approval, a question, or a sign-in, subagents included, on every paired server, each once. It drops as soon as one stops waiting (you answer, approve, or cancel), not when you open it; a failed run and an agent message do not add to it, so it is the same number as the Needs you alert and the [Live Activity](#live-activity)'s needs-you count.

### Live Activity

Unless push is off, the server also keeps each opted-in phone's Live Activity current while Oppi is closed. The card shows counts only, one per thread (a top-level session with all its subagents): how many threads need you (any session in it waits on an approval, question, or sign-in) and how many are running (any session in it is working). A lead that idles while its subagents work counts as running, once. Users turn it on per server on the phone (**Server Settings**, **Notifications**, **Live Activities**, off by default); with push off for that server the card updates only while Oppi is open. The phone, not the server, decides which servers may update its card: it tells the relay, and the relay answers any other server `409 no_activity`, which costs nothing from the budget below. There is no server setting beyond `push`.

- **What is sent:** the event (`start`, `update`, or `end`) and the two counts, in plain text to the relay, which puts them into a fixed ActivityKit template. No session names, IDs, or text. Apple and the relay can read these counts and their timing; see the [spec](../protocol/push/spec.md#36-live-activity).
- **When:** only when the counts on the card would change, at most once a minute per device (the latest counts win), and only while the device holds no app-event or session stream; an open app updates its own card. Work starting while the phone has no card starts one (with Apple's required alert, "Oppi: Agents are working."); nothing running or waiting ends it within about 30 seconds. Apple ends a card after 8 hours; while work continues the server ends it and starts a new one by then, counting from the earliest the card can have started (for a card the app started, from when work last began). The server starts a card only when it knows there is none, or when updates keep finding no card to update (work that began while the app was backgrounded but still connected has none, since the app cannot start one then): it then tries one start. The relay refuses that start for a dismissed card and for a server the phone did not list; the card is then left alone until nothing runs, and no start is sent again until then. The server keeps each device's card start time in `live-activity-state.json` in the data directory. A minute after the server starts it reconciles each device once: a card the last process started, under 7.5 hours old, is updated (no alert) or ended when nothing runs; an unknown or older card ends, or is restarted while work continues. When you stop the server (`oppi server stop`, `oppi server uninstall`, or Ctrl-C in a foreground `oppi serve`) it sends one `end` to each away device whose card is up, waiting at most 3 seconds in all, and it does the same for a device when you revoke it; both are best effort. A restart (`oppi server restart`, the in-app update, launchd restarting a crashed server, a Docker restart) keeps the cards: the CLI marks an explicit stop with a `server-stop-requested` file in the data directory, and a server that finds none treats the stop as a restart.
- **Limits (preliminary, may change):** Live Activity pushes share the device's 100 a UTC day with [alerts](#push-notifications), which come first: starts and updates stop at 70, and a start needs two free slots under 70 so its end fits. An end is never refused for the day's 100 but has an overdraft of 8 (so 108), and waits out only its own relay `429`, not one for a start or update. Only sends the relay counted use it: delivered ones, ones APNs failed after the relay took them (`502`), and `429`s; an unreachable relay uses nothing. A `409` is not counted either, but the relay charges its own quota before it asks APNs, so a `409` for a card APNs has retired still uses one of the phone's relay slots; the relay can run a little ahead of this count. A relay `503 relay_capacity` with `Retry-After` is waited out like a `429`; any other `503` counts as unreachable. Over the limit they are dropped and logged as `push.device_budget_exhausted` with `alert: live_activity_*`.

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
- For phone MCP sign-in, open **MCP Servers** in the iOS sidebar (global servers) or in **Workspace Settings → MCP Servers** (that workspace's servers), select a server, and choose **Sign In**. Open the authorization page (it follows **Settings → Open Links**) and paste the full loopback callback into Oppi; see [MCP Servers view](#mcp-servers-view). Oppi does not open a host browser for phone sign-in. You can also sign in from a host shell with `pi mcp login <server>`; a running session picks up the new credentials on its next turn. In-session `/mcp login <server>` shows the authorization URL in a phone notification and accepts a pasted redirect URL through an input dialog. It holds that session's prompt while waiting. Pi's five-minute callback timeout ends the wait and aborts the paste dialog; the input itself has no separate timeout and can be dismissed. This fallback has not been tested against a live OAuth provider.
- A saved Agent with an exact Extension selection loads a built-in only if it selects `builtin:mcp`, `builtin:codemode`, or `builtin:tool-search` in `resources.extensionIds` (for example `oppi agent create --extensions builtin:mcp,builtin:codemode`).

### Project trust in managed host sessions

Before loading protected project resources, Oppi checks user-level `project_trust` extension handlers, then Pi's saved decisions in `~/.pi/agent/trust.json` (the closest parent wins), then the agent-directory `defaultProjectTrust` setting. `always` allows and `never` declines when no earlier decision applies.

An Agent with an exact Extension selection runs only its selected user-level handlers in the trust bootstrap. Project extensions cannot run until trust is resolved. Agent launch preflight checks Extension availability without executing factories or installing missing packages, using project settings as if trusted. This is an availability check, not a trust grant: start resolves trust and rejects unavailable project selections before loading them. Such a launch fails closed, but its error can arrive after preflight.

With `ask`, the phone shows **Trust (remember)**, **Trust this session**, or **Don't trust (remember)**. Remembered choices use Pi's store, shared with the CLI. Dismissal or no answer within 15 seconds allows this session without saving a decision.

Only a start that has a phone attached before the runtime starts can prompt: opening a new or stopped session through the focused stream. Every other start is headless and uses a remembered decision, or allows without prompting when none exists. That covers Resume (`POST /sessions/:id/resume`, including the phone Resume button), Resume after a server restart, and scheduled and `oppi session` starts. A headless allow is not remembered.

Session-only decisions persist through `/reload`, and a new runtime resolves trust again. A project with no protected resources needs no decision. If an agent or you add one during a session (for example `.pi/mcp.json`), the next `/reload` resolves trust before loading it.

Trust protects `.pi/settings.json`, `.pi/mcp.json`, `.pi/extensions`, `.pi/skills`, `.pi/prompts`, `.pi/themes`, `.pi/SYSTEM.md`, `.pi/APPEND_SYSTEM.md`, and project `.agents/skills`. A bare `.pi` folder does not trigger the prompt. Context files such as `AGENTS.md` still load. Oppi creates or reopens the session file before resolving trust; it does not use the project's `sessionDir` setting for that lookup. Trust controls resource loading, not tool permissions or filesystem confinement. Sandbox and terminal-owned mirror behavior is unchanged.

**Workspace Settings** shows the same answer once as **Project Trust**, from the saved decision and `defaultProjectTrust` (it cannot predict a `project_trust` handler): **Trusted**, **Asks at session start**, or **Not trusted**. Pi Skills, Pi Extensions, and MCP Servers for that workspace all follow it. With **Asks at session start**, project items are listed as loading, because an unanswered prompt allows the session. With **Not trusted**, project skills and extensions are not listed and their toggles are off (the server refuses them with `409`). Change a remembered **Don't trust** in Pi on the host.

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
| `tts.provider` / `tts.endpoint` / `tts.model` / `tts.voice` / `tts.language` | Read aloud (restart; see [Read aloud](#read-aloud)) |
| `asr.liveVoiceBackend`                  | Live Voice ears and voice for a call on a session: `yuwp` (local ASR from `asr.sttEndpoint`, speech from `tts`) or `grok-voice` (no restart: each new call reads `asr` and `tts` from disk; Grok uses the xAI `tts.voice`, else `eve`). The app offers Live Voice only while this backend is ready; see [Voice backend health](#voice-backend-health) |
| `runtimeEnv.<NAME>`                     | Host runtime env, including TTS URLs (restart)                      |
| `extensions.voice.defaultVoiceId`       | Default voice id                                                    |
| `images.autoResize`                     | Phones resize images over 2000 px before upload (default `true`; `false` keeps originals and leaves resizing to Pi on the server) |
| `providerQuotas.openaiUseCodexPlan`     | Opt in to legacy Codex plan-wide usage on the OpenAI row; same account required (default `false`; restart; see [provider quotas](provider-quotas.md)) |
| `auth.tailscalePairing`                 | Same-user Tailscale pairing (`POST /pair/tailscale`); `false` turns it off (default `true`; restart; see [onboarding](onboarding.md#turn-off-tailscale-pairing)) |
| `auth.module`                           | Absolute path to an owner auth module (restart; see [Auth module](#auth-module)) |
| `autoTitle.enabled` / `autoTitle.model` | Automatic session titles                                            |
| `serverMetrics.enabled`                 | Server and host CPU, memory, and disk samples behind **Server Metrics** (opt-in, default `false`; restart; the Server Settings toggle applies immediately; see [Server Metrics](#server-metrics)) |

After config changes that need a restart:

```bash
oppi server restart
# or stop/start a foreground `oppi serve`
```

`oppi server restart` is operator-only. A Pi Control session runs with host-user authority, so inspect the current state before changing configuration and tell the user when a restart is required.

### Server Metrics

The host pill's **Server Metrics** page shows the selected server's CPU, memory, and disk (the volume that holds the Oppi data directory), and the Oppi server process's CPU, memory, sessions, and connections, over the last hour, 24 hours, 7 days, or 30 days. Press and drag on a chart to read a past value. The server still records event-loop delay for Grafana and the release gate; the phone page does not show it.

The menu item appears only while sampling is on. Turn sampling on in Server Settings and **Server Metrics** joins the host pill menu; turn it off and the item leaves.

What the first section measures depends on where the server runs:

| Server runs on | Section | CPU | Memory |
| --- | --- | --- | --- |
| macOS | Host | All cores, with load average | Activity Monitor's Memory Used (app, wired, and compressed) |
| Linux | Host | All cores, with load average | Total minus available, like `free` |
| Linux container (Docker, Podman, Kubernetes) | Container | The container's CPU limit, or every CPU when it has none | The container's usage minus file cache against its memory limit, like `docker stats` |

In a container, disk is the volume mounted at the data directory. Docker Desktop's bind mounts from a Mac can report the shared folder's size wrongly; a named volume reports the VM disk.

Sampling is opt-in and off by default. Off runs nothing: no timer, no reads, no files. Turn it on with the **Server Metrics** switch in Server Settings or `oppi config set serverMetrics.enabled true` (CLI changes apply at restart).

When on, the server takes one sample every 30 seconds, about 1 ms of work (measured on a Mac Studio and in a Docker container), and keeps 30 days of samples, about 1.2 MB a day (`OPPI_SERVER_METRICS_RETENTION_DAYS` changes it). The app reads the setting once per server connection, and reads samples only while the page is on screen with sampling on: the 1-hour and 24-hour views refresh every 30 seconds, and the 7-day and 30-day views load once (about 0.1 s of server time for 30 days) and refresh when pulled. Samples stay in the server's `diagnostics/telemetry/` directory and also feed the optional Grafana dashboards.

Turn it off the same way. Off stops new samples. Files already written stay until they pass retention; while sampling is off, expired files are removed when you turn it off and at each server start.

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
- **Workspace Settings → MCP Servers** lists that workspace's own `.pi/mcp.json` in the folder its sessions use, then, read-only under **From Global**, the global servers that also load there. A global server that a same-name project server replaces shows **Replaced by project**. Project servers follow the workspace's [project trust](#project-trust-in-managed-host-sessions); live status and sign-in need a remembered **Trust**. A host workspace created without a folder gets one Oppi creates under `<dataDir>/workspaces/<name>`, so its project file is `.pi/mcp.json` there. In a sandbox workspace, this section instead lists the global servers with a toggle for each one the sandbox may load and a reason for any that cannot run there; each toggle saves as soon as you flip it.

Each list runs one live probe in its own folder (`GET /mcp/scopes/{scopeId}/servers`, where `scopeId` is `global` or a workspace id). Pull to refresh for a live probe.

Select a server to see its tools and errors, enable or disable it, change exposure, sign in or out, or remove it. Use **+** to add a URL or command server to the list you are viewing. Use `${NAME}` references for headers, environment variables, and client secrets; literal values and URL query values are redacted when read back. Command arguments are shown as stored: keep secrets in `${NAME}` environment references, not arguments. Adding an existing name in the same scope is rejected; remove it first to add a replacement. Configuration changes apply to new sessions or `/reload`.

For OAuth, open the sign-in page with **Open Sign-In Page** (it follows **Settings → Open Links**). After approval, the browser might fail to load the loopback callback. Copy the full `http://127.0.0.1:<port>/callback?...` URL from the browser and paste it into Oppi. Oppi sends it only to this flow's waiting host listener. **Close**, returning from the server detail, and opening another sidebar item and coming back keep the flow available through **Continue Sign-In** and **Cancel Sign-In** on any MCP Servers list: the host reports its active sign-in with every scope's list. While a sign-in is active the list shows the last live probe (Refresh does not probe, so it cannot disturb the credential file the sign-in is writing) and add, remove, enable, exposure, and sign-out changes are refused until the sign-in ends. **Cancel Sign-In** stops it. A browser on the host can also complete the callback directly. OAuth credentials stay in Pi's host-side credential store.

## Auth module

`auth.module` names an ES module, by absolute path, that adds owner policy to network access. It exports at least one of these functions; each may be async:

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
- An `approvePairing` that throws or does not return `{ allow: true }` denies with `403`. An allowed custom pairing still alerts the other devices and, once another device is paired, waits for approval on one of them ([onboarding](onboarding.md#approving-a-new-device)).
- The module loads once at startup; restart to change it. If it cannot load (missing file, import error, a relative path, no `gate` or `approvePairing`, or an export that is not a function), the server keeps running but every network request answers `503 {"error":"auth_module_unavailable"}` and the error log shows `auth.module_load_failed`. It never falls back to running without the module. The owner Unix socket and `oppi` CLI keep working, so you can fix the path.
- Device keys, access tokens, refresh, revocation, and owner Unix-socket auth are not pluggable.

## Updating the server

A global npm install can be updated from iPhone **Server Settings** (About This Server) or with `oppi update`. See [Server settings](usage.md#server-settings). Git checkouts still use `git pull && npm install && npm run build`; a checkout linked with `setup.sh --install` can also be rebuilt and restarted from About This Server after it changes.

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
