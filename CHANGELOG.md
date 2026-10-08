# Changelog

All notable changes to Oppi will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Oppi uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html) for public releases.

## Versioning policy

- **Major** versions include incompatible client/server protocol changes or other user-visible breaking changes that require manual migration.
- **Minor** versions include backward-compatible features, new app/server capabilities, and additive protocol extensions.
- **Patch** versions include bug fixes, performance improvements, hardening, documentation updates, and dependency updates.
- TestFlight build numbers, Apple build numbers, and internal tags are not SemVer releases.

When a release includes multiple artifacts, the release heading uses the public tag/version. The entry notes component versions that differ, such as the iOS marketing version, macOS marketing version, or npm `oppi-server` version.

## Changelog style

Keep one top-level product changelog for coordinated client/server releases. Use component scopes inside bullets instead of duplicating the same release across multiple files.

If `oppi-server` or an Apple client starts releasing on a truly independent cadence, add a component changelog at that artifact root and include it in that artifact's package/release.

Use these component scopes:

- **Client:** iOS/macOS app changes, UI, onboarding, app settings, TestFlight-facing behavior.
- **Server:** CLI, pairing, session runtime, policy, storage, telemetry, extensions, npm package behavior.
- **Protocol:** wire-contract changes that require both server and Apple updates.
- **Docs:** README, setup, security, release, and troubleshooting docs.

Example:

```markdown
### Added

- **Client:** A tool's Calls section now opens with a summary such as "3 calls · 1 failed", lists each call with its status, name and duration, and puts arguments and a failure's error under that call. The collapsed row shows the same summary. Lists over 256 calls say how many were omitted.
- **Client:** Added the workspace browser deep link flow.
- **Server:** Added import support for stopped local sessions.
- **Protocol:** Added `workspace_session_list` pagination fields.
```

## [Unreleased]

Entries labeled **Mac** describe work on `main`; the Mac app is not part of the iOS TestFlight build or its server release.

### Added

- **Server/Protocol:** Every session carries a server-derived program status (OSC 7501 vocabulary) as `programStatus` on `Session` and `SessionSummary`: `state` (`idle`, `working`, `done`, `blocked`, `error`), `kind` for blocked (`permission`, `question`, `auth`), a one-line `message` (the session name, a dialog title, or the first line of an error; never prompts or model output), and `since`. Mirrored Pi sessions use the same derivation, and a stopped session keeps its last done/error outcome across a server restart. Apple models decode it, and decode a state or kind added later without dropping the row; no screen reads it yet. Lifecycle `status` is unchanged and still drives stop, resume, and open.
- **Server:** Editor dialogs now count as pending user replies everywhere (ask badge, workspace attention, `--auto-stop`, `oppi session wait --for attention`).
- **Server:** Push alerts when a session needs you or finishes: **Needs Approval** / **Question** / **Sign-in Needed** on entering `blocked`, and **Session Done** on entering `done` (top-level sessions only; a delegated session still pushes when it is blocked). They are sent only while no Apple client is connected and at most once a minute per session and kind. The body is fixed text (for example "Waiting for your approval."), never a dialog title, question, error, or prompt; the subtitle is the session name. Ended and error alerts are unchanged.
- **Server:** `oppi session wait` reads a session's program status (idle means idle, done, or error) and adds `program_status` to its JSON. New `--program-status` writes OSC 7501 reports to the terminal while waiting (one id is the root record; several ids are child records), and clears them on exit.

- **Client:** App Lock (Settings → Privacy & Security): Off, Immediately, or after 1, 5, or 15 minutes in the background, timed on a clock that changing the date and time cannot move. A locked Oppi shows an opaque cover above every screen and sheet and asks for Face ID, Touch ID, or the device passcode once; cancel leaves it locked with an Unlock button. Oppi never locks while it is open. While App Lock is on, the app-switcher snapshot is covered (the keyboard is dismissed first), Oppi's own ask notifications and Live Activities never show session text (turning it on removes ask notifications already delivered), the Share sheet asks for Face ID every time before it lists workspaces, Picture in Picture is off, and Remove Server, Revoke Device, Delete Workspace, Set/Replace API Key, Remove Credential, provider Sign In, turning off Confirm New Servers, and changing App Lock itself ask for device authentication first. When Oppi locks, audio and video playback stops (also when a timed lock becomes due while audio keeps Oppi running), and no voice reply plays or resumes until it is unlocked. While Oppi is locked, the latest `oppi://` link, notification tap, or Quick Session request waits for unlock (a cancelled unlock drops it), Ask Pi and Start Session open Oppi to unlock before sending, and Shortcuts lists no servers or workspaces. Server push notifications are unchanged. Devices without a passcode cannot turn it on.
- **Client:** Lock a server, workspace, or session on this device. Server Settings and Workspace Settings have a Lock toggle; a session locks from its long-press menu or a swipe. Opening a locked item, from any list, the iPad sidebar, search, Thread view, the server switcher, an `oppi://` link, a notification, or Siri, asks for Face ID, Touch ID, or the device passcode first; cancel stays where you were. Starting a session in a locked server or workspace (Quick Session, Ask Pi, Start Session) asks before anything is created or sent; when Siri cannot bring Oppi forward to ask, nothing is sent. A locked server covers everything on it, and a locked workspace covers its sessions; unlocking one covers what is under it until Oppi locks again, or, with App Lock off, until you leave Oppi. A screen whose unlock ended, including a reader opened from a locked chat, shows a lock cover with Unlock (a locked server's cover can also switch servers). With App Lock off, leaving Oppi while something is unlocked covers the app-switcher snapshot and stops playback. Locked items show their name, time, and status only: no question text, search snippet, model, cost, or Thread totals (a thread with a locked member shows no cost totals), and a content search never matches them. Oppi's ask notifications and the Live Activity hide text from anything locked. A small lock (`lock.fill`, or `lock.open.fill` while unlocked) follows the name on session rows, Thread rows and links, workspace rows, the sidebar, the workspace title, server rows, the server switcher, and Server Settings. Incognito sessions are always locked while App Lock is on. Turning a lock on never asks; turning it off always does. Locks never leave the device and are removed with their server, workspace, or session.
- **Client:** Every session row (All Sessions, workspace lists, Thread view) has one long-press menu: Open, Stop or Resume, Lock or Unlock, Copy Session ID, and Delete for stopped sessions. Swipes work like Mail: swipe left stays Stop (full swipe), or Resume and Delete on a stopped row with no full swipe; swipe right is one action chosen in Settings → Sessions → Swipe Actions (None, Lock, or Stop or Resume; Lock by default).

- **Client:** The SSH terminal answers the OSC 7501 program status support query, so programs such as Pi 1.1.0 start reporting, and keeps each terminal's reported records (nothing shows them yet). It is the only OSC reply the terminal sends; clipboard queries still get none. The terminal engine now bundles libghostty-vt `a4aacd9`.
- **Client/Server:** The durable control conversation shows in All Sessions beside Pi Control sessions, and not in a workspace list or its counts. Open it to read its history and live stream; a confirm card is the existing select dialog, answered with Yes, Yes to all, or No. Pi Control sessions and workspace sessions are unchanged.
- **Server:** With `experimental.serverDurable` on, `oppi control open` and `oppi control send <text|@->` (and `POST /control-conversation`) find or create one durable control conversation per data directory and message it. It runs the `oppi` CLI for you through two tools, `oppi_query` (read-only) and `oppi_script`, as JavaScript in a sandbox with no network, files, or timers. Every `oppi_script` write waits for a confirm card showing the whole request, a diff for an update, and Yes / Yes to all remaining in this script / No; a body too long for the card is refused, and there is no setting that skips the card. You answer a card with your owner or paired-device credentials, over the WebSocket `/control-sessions/<session id>/stream` or `POST /sessions/<id>/command` (find the card with `GET /sessions/<id>/dialogs`); there is no CLI verb for the answer. After a crash, creating an Agent, Session, or Schedule, running a Schedule, and sending to a durable Session are not repeated (a classic Session keeps its turn ids in memory only); other writes can be. A script that makes different calls after a restart fails instead of reusing your earlier approval, and a rerun whose calls finish in a different order can ask you again for a write that already landed; approving repeats it. The conversation survives a server restart and offers no coding tools.
- **Server:** `oppi agent create --idempotency-key <key>` (and `idempotencyKey` on `POST /agents`) makes a retried create return the Agent it already made; a different definition under the same key fails with `AGENT_IDEMPOTENCY_CONFLICT`. `oppi schedule create --idempotency-key <key>` (with `--name`; `idempotencyKey` on `POST /schedules`) does the same for Schedules (`SCHEDULE_IDEMPOTENCY_CONFLICT`, HTTP 409), and `oppi session send --turn-id <id>` makes a resent message the same turn. `oppi session inspect --turns last` selects the newest turn. `session wait` reports a timeout with `code: "wait_timeout"` and a failed `config validate` with `config_invalid`.
- **Client/Server/Protocol:** Durable and classic sessions now live side by side. `experimental.serverDurable` only makes durable sessions available; a session is durable only when its create request asks for `engine: "durable"` (`oppi session create --engine durable`), and asking while the flag is off fails with HTTP 409. Session summaries carry `engine: "durable"` and `/server/info` advertises `capabilities.durableSessions`. On iOS, Settings → Experiments → **Durable Sessions** is a temporary playground that may change or be removed in a later build. It adds a **Durable** item under Terminal: All Sessions narrowed to the server's durable sessions (including older stopped ones), whose quick session bar starts durable sessions through Quick Session; durable chats show a small Durable label. All Sessions and workspace lists still show every session. Saved Agents cannot start durable sessions yet: the Agent launch route answers HTTP 400 before saving a session, and a durable Quick Session hides the Agent picker.
- **Client:** A tool call whose input has a code-role field expands as a notebook cell: the source sits in an inset code cell, and nested calls and the result attach underneath, instead of a markdown note with fenced blocks. The collapsed row shows the first line of that code when the server did not send a title, skipping directive comments such as `// @options:`. Other generic tools (not terminal, file, media, or interactive) use the same cell: the card shows their arguments as YAML-style `name: value` lines, and printed output stays plain monospaced text, as a terminal shows it; only a result that is one JSON object, array, or string, or producer `expandedText`, is formatted. Like other tool rows, a tap expands the cell and a double-tap or pinch opens the full-screen reader; inline text no longer selects on double-tap. Inline, long code and output are trimmed with a "+N more lines" note and at most six calls show, so calls and output stay visible; the reader shows everything with text selection and review comments. Calls read as values (`git log -5`, `path: A.md`) with status icons and durations, and the cell no longer repeats the row's language, status, or call count.
- **Server/Protocol:** `outputPresentation.statusHeader` declares a pattern for a status preamble at the start of a tool's output. The registry declares Pi's codemode `Script completed / Wall time / Output:` header, and iOS hides it from the notebook output because the row already shows status and duration; copy keeps the raw text. A result cannot declare its own header. Older servers send no pattern and the header stays visible.
- **Client/Protocol:** Extension activity rows can carry `blocks`, making them disclosure rows: tap shows or hides the content, which is built only while open and stays open across widget updates. A row with both `blocks` and a `link` keeps the link on a trailing button. `terminal` blocks can carry raw `text` (colors, carriage returns, cursor motion) that iOS resolves with the bash-output VT engine; other clients show a plain projection. The background-jobs extension uses both: tap a job in the jobs drawer to see its live output tail. Requires an updated app; older apps show the rows without output.
- **Client/Server:** Full-screen extension surfaces stay live: the reader follows updates to the same surface and keeps the last one after the widget clears. The server now throttles repeated `setWidget()` replacements with the same 250 ms per-widget limit as redraw requests (newest content wins, clears are immediate), so in managed sessions no extension can push widget snapshots faster than that.
- **Client:** Pairing choices on first run and in Add Server include **Connect through Tailscale**, beside Scan QR and Enter manually. It opens the in-app Tailscale screen without a QR code; signing in is still yours to start.
- **Client:** Tailscale → Check a Mac for Oppi can pair this phone. When Oppi answers HTTPS on the machine's own loopback address, **Pair** mints a one-time invite over the SSH session and enrolls with it. A `*.ts.net` name is never dialed on the system network while the in-app Tailscale node is off.
- **Client:** Experiment, off by default: SSH Terminal (Settings → Experiments). Settings → Network → SSH Terminal, and Terminal below MCP Servers, open a host list saved on this device. Add and Edit open the setup form for host, port, username, and password or per-device Secure Enclave key sign-in. Tap a row to connect and open the shell; opening the list never dials or reads the Keychain. An existing host moves into the list without a Face ID prompt, and its password stays in this phone’s Keychain until the next connect. Swipe delete removes that host and its saved password only. Two rows can use the same machine with different Run on Connect commands. Tap the terminal to show or hide the keyboard. Add the public key to `~/.ssh/authorized_keys` yourself. Saved passwords stay in this device’s private Keychain and require user presence; Secure Enclave signing also requires approval. Trusted host keys use the same this-device-only Keychain store as Check a Mac: first connect asks you to verify the fingerprint, and changed keys block credentials. The accessory bar has Esc, Tab, Ctrl, arrows, and Paste; multi-line paste asks first; remote output cannot read or write the clipboard. SSH liveness probes, bounded waits, and a network-change hint make disconnects explicit. Backgrounding closes the shell; Reconnect opens a fresh shell without replaying input. Run `tmux attach` or `herdr session attach <name>` to continue remote work. When a coding agent (pi, Claude Code, Codex, and others) runs in the foreground, the terminal shows Oppi's chat input bar with dictation: Send pastes the text as one prompt and presses Enter. The key strip offers Esc, Tab, one-shot Ctrl and Alt, and a hold-and-drag arrow control, plus buttons for the program in front that send the key it binds; Ctrl-C is Ctrl then C, or that program's Stop button. When the host has `herdr`, a toolbar overview lists its workspaces and agents. No private-key import or keyboard-interactive. See [SSH Terminal](docs/ssh-terminal.md).
- **Client:** Experiment, off by default: Thread rows draw a small horizontal lane graph spaced by event order, not clock time. Children branch from the session that launched them and merge back at their last recorded activity once stopped (a start-to-latest-activity summary, not exact execution time), and working sessions pulse at the right edge. The saved Agents in the thread appear below as icons with counts (for example 🛠️×15 🔬×12). Swipe or long-press a thread row to stop any session that isn't stopped (idle included) or resume a stopped one. Thread detail has a **New session in thread** bar that opens Quick Session in the root's workspace and checkout; the new session (plain Pi or a saved Agent) joins the thread as a child of the root, and a thread pill in Quick Session shows the link — tapping it starts a standalone session instead.
- **Client/Server:** Pi → Tools has an Optional Pi Tools section with a switch for each tool Pi's extensions register off, such as `codemode` and `tool_search`. The server discovers them from the loaded built-in and user extensions, so `-builtin:codemode` hides codemode and a new opt-in extension tool appears on its own. The screen reads `defaultTools` the way Pi does: `["+codemode"]` shows Pi defaults with codemode on, and other `+name`/`-name` lists show their resolved tools. Turning a tool on with Pi defaults writes `+name`; with chosen tools it adds the name to the list.
- **Client:** Siri and Shortcuts can start a session with a prompt and open that live chat: say "Start session in Oppi", "Open session in Oppi", or "New session in Oppi", optionally "in <workspace>"; Siri asks "What should Pi do?" when no prompt is given. Before anything is sent, Siri, Shortcuts, and text chained from another Shortcut all show the exact prompt and the workspace (plus the server when several are paired) for confirmation, and the dialog shows the same text that is sent, with invisible formatting characters removed. A prompt over 280 characters or 12 lines is not previewed or sent; Siri says to open Oppi instead. Canceling creates no session and sends nothing.
- **Client:** The composer attaches photos and videos from Photo Library in one mixed pick. Photos stay annotatable image chips; videos are file-backed uploads rather than model image inputs, and they survive draft reopen, session switch, and a failed-send retry.
- **Client/Server:** Model Providers can show your ChatGPT plan's quota on official OpenAI models. It is opt-in: Oppi first confirms that the retained OpenAI Codex sign-in and the OpenAI sign-in share an account and workspace. The quota is labeled plan-wide, its app cap is unknown, and inference stays on official OpenAI.
- **Server:** Globally loaded Pi provider extensions can supply on-demand quota data to the native quota screens. Stream-only wrappers keep the built-in provider's quota; extensions that replace a provider's auth, endpoint, or catalog do not inherit it, and an extension's own quota source always wins.
- **Server:** Experiment, off by default: a durable backend for managed host and sandbox sessions, made available by the server flag `oppi config set experimental.serverDurable true` and a restart; a session uses it only when started as durable (see the side-by-side bullet above). It persists each turn in a conversation store and resumes interrupted work without sending a second user prompt. Durable sessions show extension UI from conversation state, page and outline history, keep background jobs as durable conversation state, and show working words as activity plus elapsed time. They load AGENTS files, Skills, and host MCP servers (with the same project-trust prompt as SDK sessions), fork before a user message, spawn child sessions that the parent owns, and are found by search through their user text, assistant text, and tool names. A session already bound to a durable conversation keeps working, and keeps resuming after a restart, when the flag is turned off. Sandboxes reuse their workspace VM, provide guest coding/search tools and image reads, and kill the guest process group on Stop. The default remains the SDK. Durable sessions do not support classic extensions, selected sandbox MCP servers (these are rejected), Pi resource discovery, tree navigation, export, or reload, and compaction and retry detail parity is not complete.
- **Client:** Generic tool calls carry an Input / Calls / Output document with highlighted code inputs, recorded nested calls, and readable JSON forms and tables; iOS paints the notebook cell above from the same facts, inline and in the full-screen reader. Copy output still copies raw tool text. The Calls section opens with a summary such as "3 calls · 1 failed", lists each call with its status, name and duration, and puts arguments and a failure's error under that call; the collapsed row shows the same summary, and lists over 256 calls say how many were omitted. Nested live calls update their parent's Calls instead of appearing as extra timeline rows, completed grandchildren survive a late-starting intermediate parent, and an incomplete notice stays when live calls were dropped. Tool calls can show producer-resolved names such as `coros · Get activity detail`, with the raw identity kept in Input/Raw; MCP-provided titles are not shown yet because Pi drops them before its public session boundary, so display uses definition labels, result metadata, or MCP name conventions, and no icons are carried or fetched. Interactive inspection stays independent of the answer receipt, media keeps Input/Calls beside native attachments, empty generic output renders structured details without running Pi TUI hooks, and Raw identifies previews and loads full output from an available sidecar.
- **Client/Server:** Bash, file, diff, and interactive tool rows are drawn from facts the server sends with each tool call, not from the tool's name. Any tool with command-input and terminal-output facts gets the bash command panel, streamed tail previews, server summary title, and full-output paging. Read/write/edit and equivalent extension tools get the file and diff viewers: requested write content and args-derived edit diffs are labeled Requested, result diffs drive both the viewer and change counts, and collapsed file titles use server summaries. Interactive tools declare `outputPresentation.kind: "interactive"`, which drives question counts, automatic-expansion policy, and one answer receipt per call, live and after reload. Compact turns, Session Outline, Live Activity (`Running <title>`, no tool-name verbs), and copy output use the same facts; quiet edit counts use result diffs when available, otherwise labeled requested edits, and arbitrary interactive tools stay visible. Voice-mode changes require a registry-declared setting effect, so unrelated tools cannot change preferences by returning a voice-mode-shaped result. With an older server that sends neither input nor output facts, exact built-in bash/read/write/edit/ask keep native inspection through one OppiCore fallback, producer facts always win, and aliases and custom tools without facts stay generic.
- **Server/Protocol:** Additive input field roles (command, file path, content, edit pair, read range) and output-kind facts (terminal, file content, diff, with requested/result provenance) on tool start/update and trace calls, plus Pi's bounded `nestedCalls` and output availability on tool end and trace results. Mobile-renderer sidecars can declare command fields and terminal output for any exact tool name. Managed sessions, mirrors, and history resolve facts through one registry; Managed and Mirror events forward `parentToolCallId`, and canonical results and reload show the same recorded Calls. Generic output no longer strips invocation-like text based on tool names.
- **Client:** Customize Rows (Settings → Session List) chooses Standard or Compact session rows and turns model, time, context usage, cost, files touched, compactions, and (with Session Threads on) the Thread strip's Agent summary and lane graph on or off, with a preview drawn by the real row. Done saves for this device and applies to Oppi session rows in every session list; Cancel discards; Restore Defaults resets the preview. Status, questions, Incognito, workspace context, and Thread access always show, and hidden cost stays out of the Thread strip total.
- **Client/Server:** iOS manages Pi MCP servers where they load: sidebar **MCP Servers** for global `~/.pi/agent/mcp.json`, and **Edit Workspace → MCP Servers** for a host workspace's `.pi/mcp.json`. Each list probes only its own scope and covers live status, tools and errors, enable/disable, exposure, URL/command add/remove, and OAuth sign-in/out. Phone sign-in accepts the pasted loopback callback; secrets and OAuth credentials stay on the host. A workspace list also shows the global servers that load there, read-only, and marks ones a project server replaces. A host workspace without a folder manages the project file in its sessions' home folder.
- **Client/Server:** Sandbox workspaces can use MCP. Edit Workspace → MCP Servers ticks which global servers a sandbox may load; the agent cannot add any, and the sandbox's own `.pi/mcp.json` is ignored. HTTP servers connect from the host only to Allowed Hosts (a private or local host must be listed exactly), with sign-in and secrets kept on the host. Stdio servers run inside the VM and are blocked if their environment references host secrets. Sandbox MCP never runs agent-written code or MCP-config commands on the host: sandboxes have no codemode (default-exposure servers are reached through `tool_search`), servers with `!command` headers or client secrets, or with `auth.provider` model logins, are refused, and each sandbox logs MCP output to its own file. Saving sandbox settings from the phone also keeps the workspace's sandbox `env`, which it used to drop.
- **Client/Server:** Edit Workspace shows one **Project Trust** state (Trusted, Asks at session start, Not trusted) from Pi's saved decision and `defaultProjectTrust`. Pi Skills, Pi Extensions, and MCP Servers follow it: a distrusted folder no longer lists its project skills and extensions as loaded, and their toggles are off.
- **Client:** Server detail lists paired devices with a "This device" marker and last-used time, and revokes other devices after a confirmation. New pairings send the device name (a generic "iPhone" gets a short per-device suffix such as `iPhone (A3F9)`; names are capped at 64 characters).
- **Docs:** `GET /auth/devices`, `DELETE /auth/devices/:id`, and the `POST /pair` `deviceName` field in Onboarding and pairing.
- **Client:** Experiment, off by default: Session Threads (Settings → Experiments → Session Threads, saved on this device) groups sessions that other sessions launched under the session that launched them, in All Sessions and workspace lists. Off, every session is its own row and Settings has no Layout picker; the All Sessions top bar keeps only the workspaces and server controls. Both lists use the same sections, rows, swipe actions, and Thread strips, and workspace lists keep their worktree picker, importable host sessions, and month-grouped history. Stopped rows offer Resume and Delete on a trailing swipe; a full swipe no longer acts on a stopped row. On, a thread lists one row per launch tree with who is working, a member strip, and total cost, and sits in Working when any member works, even while its root is idle or stopped. A thread is listed in its root's workspace; its strip shows "N workspaces" when members span workspaces, and a member in another workspace or worktree gets an "In thread" link to it. Tapping the root row opens that session's chat; tapping the labelled Thread strip under it opens the thread view (swiping either never navigates), which remembers its Outline, Waterfall, or Timeline mode on this device. Outline folds finished children under their parent behind an "N finished" row that names the Agents inside it, shows each session's Agent icon with a status dot, the model with its provider icon, cache hit rate, and an estimated prompt-cache state (in use, kept warm, warm with minutes left, or cold), and names the workspace of members outside the root's; the header shows the thread's cache rate and the root's cache state. Waterfall lists one row per session on clock time, from launch to its last recorded activity (a summary, not exact execution time), with message arrows between rows, pinch to zoom, and tap to open. Timeline is a lane graph of launches, stops, messages, control commands, and cross-thread messages with filters for each; cross-thread message rows open the other session. A thread strip with no cost data no longer shows `$0.00`.
- **Server:** Records (used by the Session Threads experiment) cross-session primitives in `session_interactions` (`session-state.db`): `prompt`, `steer`, `follow_up`, `abort`, `stop`, and `resume` sent by `oppi session` from inside another session. The CLI attributes calls with an `X-Oppi-Caller-Session` header; the value is display metadata, not authorization. Deleting a session deletes its rows.
- **Server/Protocol:** `GET /sessions/:id/thread` adds `promptCache` per session (`retention`, `ttlMs` from the model's cache tier, `lastRequestAt`, and Pi's live `warmer` state) and `workspaceId`/`model` on counterparts.
- **Protocol:** Additive `parentSessionId` on session summaries and owner `GET /sessions/:id/thread` (`rootSessionId`, `sessions`, `interactions`, `counterparts`).
- **Server:** Managed host sessions load Pi's MCP, codemode, and tool-search built-ins by default, with no config flag. `-builtin:<name>` in Pi's `extensions` setting turns one off. Terminal-owned mirror sessions never load them. Managed host sessions also resolve Pi project trust before loading project resources, with a phone prompt and CLI-shared remembered decisions. Unanswered prompts allow the session after 15 seconds. Sandbox and terminal mirror trust behavior is unchanged.
- **Mac:** Help → Client Script runs `focus`, `command`, and `catalog` steps by name. The accessibility value `mac.clientScript.snapshot` reports focus, section, session, tool row, and document so computer use can check a shortcut against the same action. Sidebar sections are `mac.sidebar.*`. Timeline rows are `mac.timeline`, `mac.timeline.userMessage`, and `mac.timeline.assistantMessage`.
- **Mac:** Keyboard-first commands. ⌘N opens a new session, ⌘K opens a command palette over every command and session (⌘↩ opens a session in a split), ⌘P jumps to a session, ⌘{ / ⌘} step through sessions, ⌘L / ⌘J focus the composer or timeline, ⌘⇧M toggles dictation, ⌘1–6 switch sidebar sections, and ⌘/ shows the shortcut sheet. Every command appears in the menu bar with its current shortcut.
- **Mac:** Settings → Keyboard rebinds any command (a taken chord moves, system shortcuts are refused) and picks a timeline preset: Mac Standard, Vim (j/k, h/l, g/G, i or Tab to the composer, Esc back), or Emacs (⌃N/⌃P, ⌃F/⌃B, ⌥< / ⌥>, ⌃G, ⌃O).
- **Mac:** ⌘+, ⌘-, and ⌘0 resize timeline, tool, and document text in place without losing scroll position.
- **Mac:** Clicking a tool row header expands or collapses it; double-clicking opens it in the document column.
- **Client:** Server settings can ask a globally installed `oppi-server` to update itself, then reconnect. A single All Sessions notice points at Server when the paired host is older than this app build (0.51.0). End-to-end behavior on a real npm-global update has not been verified; do not rely on it yet.
- **Server:** `GET /server/info` reports install kind and a cached latest npm version. `POST /server/update` installs that exact version for global npm installs, then restarts the process (in-place `execve`, or a non-zero LaunchAgent exit so KeepAlive brings it back).
- **Protocol:** Additive `update` object on `GET /server/info` and owner `POST /server/update`.
- **Docs:** In-app server update on the Server settings usage page and README upgrade section.
- **Client/Server:** A Dictation Dictionary can be edited on iPhone or through `oppi dictionary`. All-workspace and per-workspace lists share short vocabulary hints; agents can curate them from past sessions through the CLI.
- **Client:** Pick HTML elements and Mermaid objects for review comments, with readable target descriptions and contextual Comment controls in full-screen viewers.
- **Client/Server:** Host videos show adjacent `clip.srt` and `clip.<lang>.srt` captions in chat and the file browser, with the same language picker as workspace video.
- **Protocol:** Servers report `capabilities.currentFiles` and serve every workspace, session, and host file read through `GET/HEAD /files/current?origin=…`, plus bounded same-stem caption discovery at `/files/current/sidecars`. iOS switches only when the server reports the capability; the legacy workspace `raw`, session-raw, and `/files/raw` routes stay for older iOS builds.
- **Client:** Edit existing workspace text files (Markdown, code, JSON, plain text up to 1 MiB, selected worktree included) on iPhone and iPad. Edit is explicit from the reader; typing stays local in one UIKit text view, saves after 1 second idle, and keeps a protected on-device draft. Preview shows the current draft. If the file changed on the server, autosave stops and offers Review Changes, Use Disk Version, or Replace Disk Version; a deleted file is never recreated. Bytes are saved exactly as typed, with no line-ending, BOM, Unicode, or JSON normalization.
- **Client:** Edit is reachable wherever a workspace file opens: the iPad file tree (Edit in the toolbar), chat file pills, Chat Files (All and Changed), and the git context bar's file review. Readers opened from a chat use that session's worktree, and the editor names a worktree checkout (or warns "Main checkout" when the chat runs on a worktree). In file review, Changes stays the default; the File tab and new files show current bytes with Edit, deleted files stay diff-only, and Changes reloads after the save. Uploaded-file pills open the session's copy read-only.
- **Client:** In the Markdown editor, Return continues bullet, numbered, and task lists (CRLF kept, one undo), and Return on an empty item ends the list.
- **Server/Protocol:** `capabilities.workspaceFileEditing` (`version`, `maxBytes`). Eligible workspace-origin `GET/HEAD /files/current` responses carry a strong `ETag`. `PUT /files/current?origin=workspace` requires one concrete `If-Match` and returns `200 {etag,size,mtimeMs}`, `412`, `404`, `413`, `415`, or `428`; it never creates files. Host and session origins and the legacy raw routes stay read-only. Rename is not compare-and-swap against other same-host writers.
- **Client:** iOS Settings → Network → Tailscale joins your tailnet from inside Oppi with the official userspace TailscaleKit, without the Tailscale VPN app or a VPN profile. Sign in through the Tailscale login page; the screen lists online machines from LocalAPI, and paired `*.ts.net` servers connect through the embedded node while it runs. Building the iOS app now requires `clients/apple/scripts/build-tailscalekit.sh` once per checkout (Go and Xcode).
- **Client/Server:** From Tailscale → Online Machines, Pair with Oppi asks the Mac for a 90-second invite when `tailscale whois` `UserProfile.LoginName` matches the server's Tailscale login, then enrolls through the existing pairing flow and trust sheet. The server must use `tls.mode=tailscale` MagicDNS names (SOCKS only matches `*.ts.net`). The endpoint returns 404 when `publicUrl` is set, and 403 for forwarding headers, the server's own node, tagged nodes, and other tailnet members. Pairing waits for the embedded node's SOCKS proxy, not only `.running`.
- **Client:** Tailscale → Check a Mac for Oppi signs in to a Mac's Remote Login (SSH) through the embedded node with a password and reports macOS, Node.js, npm, git, and whether Oppi is installed. Oppi shows the Mac's SSH key fingerprint and asks you to trust it before the password is sent, and warns if the key changes. Only the trusted key is saved. Nothing is installed.
- **Client:** Tailscale → Online Machines shows what each machine can do instead of offering Pair with Oppi everywhere. Machines already paired show Paired and open their server; machines that answer Oppi's health check offer Pair with Oppi; machines that refuse or time out show Oppi not reachable, and ones that present a certificate this iPhone rejects show Oppi needs Tailscale HTTPS, both with Check this Mac, which opens the SSH check with that machine selected. iPhones, iPads, and Android devices are not listed. Check a Mac for Oppi now also reports the `tailscale` CLI and whether Oppi's server uses Tailscale HTTPS (from `oppi status --json`), and offers Pair in the same screen when Oppi serves HTTPS on that machine; otherwise it ends with "Ready — go back and tap Pair" when everything else passes.
- **Server:** `oppi pair --ttl <duration>` issues a single-use invite that lasts from 1 second to 30 days, for hand-offs like App Review notes where a 90-second invite would expire. Pair output now shows when the invite expires, and `--json` includes `expiresAt`.
- **Protocol:** Additive `expiresAt` (ISO time) on the `POST /pair/tailscale` invite response.

### Changed

- **Client:** On iPhones with a side rail, the chat's back, session, Files, Outline, and context controls sit on the rail and the top title strip is gone; the session button opens Rename, Copy Session ID, and Share. On a wide rail screen, Files, Outline, and Context slide in from the right beside the timeline instead of rising as sheets, one at a time; narrow screens keep the sheets. Usage, Server Settings, and Model Providers show the server switcher on the rail as one status-colored icon instead of a pill that ran off the screen.
- **Client:** Session Threads experiment: a Thread strip no longer has its own "Thread · N sessions" header row; the chevron moves to the totals line, and "N workspaces" joins the totals. The Agent summary and working/done totals now count the root session too, so they match the lane graph.
- **Server:** Updated embedded Pi runtime packages to `@earendil-works/pi-coding-agent@1.1.0` (with `pi-ai`, `pi-tui`, `chord`, `pi-codemode`, `pi-durable`, and `pi-server` at 1.1.0). Pi 1.1.0 adds `aborted` to `agent_settled`, so a cancelled run can be told from a finished one.
- **Client:** Write tool rows no longer show a "Requested" label; the written content is exactly what the tool asked for. Edit rows still say Requested when their diff comes from the arguments rather than the tool result.
- **Client:** The remaining settings pages follow the same layout as App, Server, and Workspace Settings: Tailscale, Check a Machine, SSH Terminal hosts and setup, Share Session redaction, MCP Servers (list, detail, Add, Sign In), Quick Comments, Auto-Name, Import Theme, Dictionary, the Skills and Extensions catalogs and details, and New Workspace. Descriptions sit in section footers, labels are Title Case, and destructive actions (Disconnect from Tailscale, Delete Saved Password, Forget This Workspace) sit alone in the last section and now ask first. Skills and Extensions both say Enabled and Disabled, and a detail page's switch is **Enabled**. MCP lists show Code Mode, Deferred, Direct, or Hidden instead of the raw `codemode` value. MCP and model providers share Sign In, Sign In Again, Cancel Sign-In, and Sign Out. New Workspace uses the same folder check as Workspace Details, and its Show Changes in Chat is a footer-described toggle.
- **Client:** The Privacy & Security toggle "Require Face ID" is now **Confirm New Servers**, which says what it does: ask for device authentication before trusting a new server or a server whose identity changed. Its setting carries over. The Face ID permission text now describes App Lock, server confirmation, and protected actions instead of agent-action approvals that no longer exist.
- **Client:** Workspace Settings (was Edit Workspace) is now a short index: a summary row that opens Details (name, description, icon, folder), then Instructions, Skills, Extensions, MCP Servers, Dictionary, and, for a sandbox, Network Access, with Project Trust, Show Changes in Chat, and Delete Workspace below. There is no global Save: Skills, Extensions, sandbox MCP servers, and Show Changes in Chat are toggles that apply as you flip them and revert with the error on failure, and only Details, Instructions, and Allowed Hosts have their own Save. Saving Details returns to Workspace Settings instead of closing it.
- **Client:** Server Settings is now a short index: a summary of the server, then Model Providers, Workspaces, Dictionary, Paired Devices, About This Server (uptime, versions, update), and Badge Icon, each on its own page, with Mobile Output Guide and Remove Server below. Add Server lives in Settings only. Settings → Network is gone: Tailscale is its own row in Settings, and SSH Hosts has a row while the SSH Terminal experiment is on.
- **Client:** The starter prompt of a Pi Control session no longer says the `oppi` command's native confirmation is the only approval gate; it tells the agent to summarize the change and wait for your explicit approval before invoking the command.
- **Compatibility:** Build 53 requires `oppi-server@0.51.0` and `oppi-mirror@0.51.0`, and the app's server-update notice now fires for older hosts. Message queue commands changed (`remove_queued_message` and `take_queue` replace `set_queue`), so mixed versions lose queue controls. A Build 53 app on a 0.50.0 server stops a turn only while nothing is queued: Stop, Remove, and Edit in composer with queued messages fail with "Unsupported command type". A Build 52 app on a 0.51.0 server cannot remove, reorder, or save queued messages; sending, steering, follow-ups, and Stop still work. A 0.50.0 `oppi-mirror` cannot remove or withdraw queued messages from the phone on a 0.51.0 server.
- **Client/Server/Protocol:** The message queue is remove-and-restore. Each queued message has a trash button, and **Edit in composer** moves every queued steering and follow-up message, with its attachments, back into the composer. Stop first moves queued messages into the composer, then stops the turn, so nothing queued is lost; with nothing queued, Stop runs at once. Servers add the `remove_queued_message` and `take_queue` commands.
- **Client:** Tailscale setup checks are no longer Mac-only. Online Machines still says Check this Mac on a Mac, and says Check this Linux machine on Linux. Check a machine for Oppi signs in over SSH to either, reports the Linux distro from `/etc/os-release`, and does not require the Xcode Command Line Tools there. Pairing over SSH still needs HTTPS, and reads loopback `/health` with curl, Node, or wget when curl is missing. Other systems are reported as unsupported. Nothing is installed.
- **Client:** Extension widget drawers and full-screen surfaces now draw their content with the chat's own UIKit renderers. Code blocks are syntax highlighted by their `language` with copy and wrap controls, Markdown matches chat Markdown (including wiki links), terminal and widget lines keep alignment and scroll sideways (keeping their position when the extension sends an update). Plain widget text in the drawer now scrolls inside the same capped viewport as native surfaces.
- **Client:** iOS prefers verified LAN connections on Wi-Fi or Ethernet, with a bounded LAN attempt before remote fallback. An enabled in-app Tailscale node gets a bounded startup wait before the system VPN/resolver. LAN promotion happens on Bonjour arrival or the next foreground and never while a turn, send, or dictation is active, and the host badge stays connected during routine route preparation and refresh when connection evidence remains.
- **Client:** The host switcher's connection row is the Retry button while the server is not connected. Connection status names Tailscale, in-app Tailscale (only when its SOCKS proxy is published), and local network instead of HTTPS/WSS.
- **Client:** Missing Markdown media reports HTTP 404 instead of a generic playback failure, and shared messages, including unresolved file links, use a neutral Notice title.
- **Client:** Session status uses one palette everywhere: working is blue, done or idle is green, needs you (a question) is orange, stopped is grey, and errors are red. Question pills were blue, the same as Working. Thread graphs color each lane by its session's status, and cross-thread links are purple.
- **Mac:** The Oppi server runs on a signed Node worker bundled in the app (`dev.chenda.OppiMac.server`, universal, SHA-256-pinned Node 24.11.1) instead of Homebrew Node. An existing LaunchAgent that still runs Homebrew Node is reinstalled on the bundled Node at app launch. Full Disk Access must be granted to the worker when launchd runs the server. `oppi server install` from a terminal keeps using system Node, and `oppi doctor` warns when an installed Oppi.app will migrate the LaunchAgent. Debug builds have no bundled Node and only attach to a server you start.
- **Client:** New orbs animate for dictation and the agent's thinking/working indicator, adapted from Thinking Orbs designs by Jakub Antalik and a Swift port by Haplo LLC. The dictation orb responds to voice. On-device dictation prefers Apple's DictationTranscriber, which accepts Dictionary phrase hints and gave better results than SpeechTranscriber in our normal-path use; SpeechTranscriber remains the fallback.
- **Server:** The server now runs on Pi `1.0.4` (Build 52 shipped Pi 0.87.1). Codemode scripts can generate images with `models.generateImages()`, and `image()` also saves each image to a temp file and names its path in the result. `tools.read()` on an image file returns an image block. MCP OAuth registration sends `application_type`, so OpenID Connect servers accept the loopback redirect. A script that patches JavaScript built-ins no longer crashes the host. The Azure provider is renamed from `azure-openai-responses` to `azure` and also serves Foundry Chat Completions deployments such as `azure/deepseek-v4-pro`; rename the key in `auth.json`, `models.json`, and `settings.json` (or sign in again), because sessions on the old provider fall back to another model when resumed. MCP OAuth sign-ins are stored per server name and URL. The OpenAI provider adds Sign in with ChatGPT, which uses a ChatGPT subscription; the older ChatGPT provider is now listed as "OpenAI Codex (legacy)". MCP servers without `direct` tools no longer delay the first prompt, and MCP tool names replace `-` with `_` (`mcp__my-server__x` becomes `mcp__my_server__x`).
- **Client:** MCP server Exposure offers Pi 0.99.2's four modes: `codemode`, `deferred`, `direct`, and `hidden`. The `codemode` description now says scripts find the tools and the model doesn't see them.
- **Mac:** New Session uses the same mic, plus, model, and thinking pills as the session composer. Code fences use the iPhone card: an 11 pt language header, wrap, and copy, over a shorter code body.
- **Mac:** The session timeline reads like the iPhone one on a desktop column: user, assistant, thinking, and tool rows are tinted cards in one centered reading column that widens with text zoom, and the composer sits in the same column. At 100% zoom message text is 15 pt (was 13 pt) and code is 13 pt (was 12 pt); inline code follows the message size with a highlight wash. Assistant messages and the composer model pill show the model's provider mark. Command bars and diff lines (timeline and document column) are syntax-highlighted. The tool row's document button is gone: click the header to expand, double-click to open the document column, or use the row's "Open in Document View" accessibility action.
- **Server:** The Node.js requirement is 22.19.0 or newer, matching Pi. Sandbox workspaces still need Node.js 23.6+.
- **Mirror:** Mirrored Pi `turn_end` frames omit duplicate message bodies and tool results.
- **Client:** Everything the iOS app and Share extension store on disk now uses iOS Data Protection class _Complete unless open_: timeline cache, message drafts, file-browser cache, HTTP cache, and shared-file inbox. Closed files cannot be opened or read while locked; files already open remain accessible until closed. New files can be created after lock until they are closed. Before, files were readable from the first unlock after a reboot. Start Session prompts stay out of preferences: an unsent prompt is stored in a protected file, and an existing one moves there on first launch. Review comment drafts are still stored in preferences. The first launch after updating upgrades files that are already stored.
- **Client:** Ask Pi now requires the device to be unlocked and authenticated before it runs.
- **Server:** On a new host, the first `oppi serve`, `oppi pair`, or `oppi init` uses Tailscale TLS and a `*.ts.net` invite when `tailscale cert` can issue a certificate for the machine (the command runs during that first check, and `OPPI_TAILSCALE_BIN` selects a Tailscale binary that is not on PATH, for certificates, status, and the same-user pairing check; set it in the environment or under `runtimeEnv`, which is the way to give it to the LaunchAgent, whose plist carries only `PATH` and `OPPI_DATA_DIR`; it is trusted like `PATH`). Otherwise it uses self-signed TLS, as before. All three look for `tailscale` through the configured `runtimePathEntries`, and only the first of several concurrent first-run commands sets the mode. New configs store `tls.mode=disabled` until that first choice, so `oppi config get tls.mode` prints `disabled` and `oppi doctor` says TLS is not chosen yet on a host that has never served. An existing `self-signed`, `tailscale`, or `manual` mode is never replaced, including by `oppi init`, and `disabled` stays behind a trusted private-HTTP reverse proxy or when `tls.allowInsecureNetworkHttp=true` explicitly opts into plaintext on first run. `oppi init` leaves a paired host's TLS block unchanged, including `disabled` or an invalid block. A paired config saved before `tls` existed still loads as `self-signed`. **Behavior change:** any validation error in a paired host's `tls` block (retired `cloudflare`, unknown mode, not an object, or an invalid field) now makes the whole block load as `disabled`, without an insecure-HTTP opt-in. The server refuses to start on a non-loopback bind, even behind a trusted proxy, with a message pointing at `oppi config set tls.mode ...`; before, it could silently serve self-signed TLS or plaintext HTTP. Other config writes keep the invalid block so the startup message stays until you fix it. **Breaking for scripts:** `oppi init` now prints `TLS mode set to <mode>` (no `(cert generated on first serve)` suffix), and `oppi pair` before the first serve prints `First run — TLS mode set to <mode>` (to stderr with `--json`). The `serve` line is unchanged for self-signed.

### Fixed

- **Client:** Long-pressing a wiki link to an image, video, audio, PDF, or other non-text file no longer crashes the app. The file icon now sits outside the link, so tap the file name to open it. The same rule keeps inline math inside a markdown link out of the link.
- **Client:** Removing a server also deletes this iPhone's cached copies of its data: session traces and lists, workspaces, skills, file-browser indexes, and the HTTP response cache (which held response bodies and request headers with access tokens). Unsent composer and file-edit drafts stay. Nothing on the server changes.
- **Client:** Server responses and bearer tokens are no longer written to the iOS HTTP cache (`Cache.db`). The app deletes a `Cache.db` left by earlier builds on launch, and Clear Local Cache now also clears the file-browser index and any leftover HTTP cache.
- **Server:** A durable run that ends without an answer stays in the session after reconnect or a server restart. A model error, or a faulted or orphaned task, shows once as an error card in the trace and is not sent to the model. The card is written before a prompt sent immediately after the failure. Crash recovery reads the harness storage the server already has open; if that read fails, the session does not attach. A later attach does not rescan terminal tasks it has already examined. Stopping or withdrawing a turn stays quiet.
- **Server/Protocol/Client:** When a durable provider rewrites in-flight assistant text or thinking so it is no longer an extension of what was already streamed, the live bubble shows that current partial instead of appending it. A rewrite of an earlier block updates that row and does not split the later open bubble. Older apps ignore the new `replace` field and keep today's append behavior.
- **Server:** Session search no longer indexes pasted screenshots and other inline base64 media. Image data had filled the per-session text cap in about 500 sessions, hiding the text after it from search, and made up about 88% of the index's distinct terms. Those sessions are re-read once in the background after upgrade, then the index is compacted (about 100 MB of index data drops to about 37 MB on an 11k-session server). Reindexing a session after each turn no longer scans the whole index to find its old row (about 30 ms on that server, now about 2 ms).
- **Client:** In the SSH terminal, a tap while the direct keyboard is up is a click when the remote app asked for mouse input, so Herdr controls such as switch work without dismissing the keyboard. Hide that keyboard with ⌄ on the keyboard bar. A tap with the keyboard down still opens it.
- **Client:** When the only available route keeps returning temporary server errors (such as 503), the app keeps retrying the session connection instead of leaving the session with no retry.
- **Client:** Sending no longer intermittently bounces the message back into the composer: leaving and reopening a chat can't drop its live connection, a chat that missed its first connection frame reopens its stream, and Send shows Connecting… and reconnects first when the connection is down. The composer clears as soon as the message appears in the timeline, and the draft returns if the send fails. Re-pairing a server from an invite returns to the session inbox.
- **Server:** The phone's context meter no longer collapses after a codemode helper call. Pi records the usage of `models.classify()` and `models.generateImages()` on the tool result, and the server copied that small request into the session's context size (a 152k meter fell to about 900 after one generated image). Only the session's own assistant turns set the context size now; cost and token totals still count every billed call.
- **Client:** Returning to an open file, after native full-screen video or a Back from a linked file, re-reads it and rebuilds the viewer only if the text changed. Before, every return rebuilt the viewer, so every inline video in a Markdown file was recreated: the watched clip lost its position and each player started loading again. If the re-read fails because the file was deleted or moved (404), or access was lost (401/403), the load error replaces stale text. Offline, timeout, and temporary server failures keep the existing reader and its inline players.
- **Client:** Links in thinking blocks and other timeline text follow Settings → Open Links (in-app browser or Safari) instead of always opening outside the app.
- **Client:** `@` file mentions in Quick Session search the selected checkout like chat does.
- **Client:** Dictation keeps the screen awake while it captures voice, so auto-lock can't fire mid-sentence.
- **Client:** Inline GIFs and APNGs keep their aspect ratio and no longer leave a blank embed after full screen. Inline Markdown SVG stays painted after scrolling away and back.
- **Client:** Provider sign-in survives an expired flow, dismissing the sheet, and a host switch, rejects unsafe sign-in URLs, and lets you retry a failed server browser launch. Before, an expired flow broke every later provider-auth call and dismissing the sheet cancelled a live login.
- **Client:** An unreachable paired server stays selectable, so Settings, Retry, and removing it remain available while it is offline.
- **Server:** Agents link files in other repos with `~/` or absolute paths. The mobile output guide now says relative wiki links resolve from the session's workspace checkout root, not the shell's cwd. Before, a session in one workspace could link a file in another repo with a path relative to that repo, and tapping it showed "Could not resolve".
- **Client:** Mermaid diagrams in chat are readable on a phone. Diagrams are laid out for a 360pt screen instead of 800pt: flowchart labels wrap, gaps are tighter, disconnected parts and unlinked subgraphs stack, and charts (XY, sankey, quadrant, journey, kanban) fit the bubble. A diagram that is still taller than the bubble is scaled to fit, so the whole chart stays visible; tap opens it full screen. Flowcharts keep the author's node order, so a retry loop no longer puts the fix step above the flow, chains stay straight, and loops back to an earlier step run along the side instead of over the main line. Two subgraphs whose titles start with the same word (`subgraph Server metadata` / `subgraph Server readers`) no longer crash the app.
- **Server:** A session pinned to a model (for example, one launched with `--model`) resumes as long as that model's provider is still signed in, even after Pi's `enabledModels` drops it. Before, narrowing `enabledModels` (such as moving `openai-codex/*` to `openai/*`) left those sessions failing every open with "Required model … refusing model fallback".
- **Client/Server:** You can switch the model of a session that cannot start. When the session's runtime never comes up, iOS sends the switch over HTTP and the server updates the stored model so the next open starts on it. Saving the choice as the default still needs a running session. `POST …/sessions/:id/command` with a `requestId` now returns the live runtime's `command_result` (for example, a rejected model switch) instead of an empty list.
- **Server:** Removing a large worktree no longer freezes the server. `git worktree remove` used to block every request and session stream for the whole delete (about a minute for a 23 GB tree) and was killed after 60 seconds, which could leave a half-deleted checkout. Removal now runs in the background with a 30-minute bound. A worktree being removed is hidden from worktree lists so no session can start in it, and it reappears if removal fails.
- **Server:** Sessions that were running when the server stopped, restarted, updated, or crashed now resume on the next start, instead of all showing Stopped. A session that was mid-turn also gets a message asking the agent to continue; that is a normal billed turn and can repeat unfinished work. See [Running sessions across a restart](docs/server-configuration.md#running-sessions-across-a-restart).
- **Server:** A second `oppi serve` for the same data directory that fails to start no longer marks the running server's sessions stopped. Startup now touches session state only after it owns the data directory.
- **Server:** `oppi session get|send|wait|…` and `oppi schedule --session` no longer download every stored session to resolve one id. The CLI asks `GET /sessions?idPrefix=<target>` for matching ids only. With about 10,000 stored sessions, each lookup had cost the server roughly 0.4 s of CPU, and a handful of parallel subagent calls could push its memory up by 500 MB.
- **Client:** In a control session, a Markdown file opened full screen from a tool now loads its host images and its links open, instead of doing nothing.
- **Client:** A finished thinking block no longer looks stuck while the model is still writing the next tool call or reply. The row closes when the next block starts instead of waiting for the whole message. GPT models could leave it as a tall, unformatted, still-streaming bubble for tens of seconds.
- **Mac:** Timeline scrolling and streaming no longer stall under an imported custom theme. Theme-aware paint decoded the stored custom-theme JSON on every render (about a quarter of main-thread time while scrolling); the resolved palette is now memoized until the stored theme changes. Timeline rows also skip re-rendering when a token lands in another row, and syntax highlighting is cached.
- **Mac:** The top of the timeline no longer shows a toolbar-height blurred band over the first rows, and the composer no longer grows to a tall empty capsule when the pane has room.
- **Server:** Sandbox workspace file reads and listings no longer follow symlinks out of the mount. Every byte read comes from a handle verified against the checked path, so a symlink swapped in after the check returns 404.
- **Server:** An aborted media Range request (common when a player seeks) closes its file handle instead of crashing `oppi serve` on Node's DEP0137 garbage-collection close.
- **Client:** Video sidecar captions keep following playback in native fullscreen for chat embeds and the file browser instead of freezing on the last inline caption.
- **Server:** First `oppi serve` keeps `tls.mode=disabled` when `publicUrl` and `proxy.trustedPeers` configure a trusted private-HTTP reverse proxy, instead of switching to self-signed TLS and breaking the proxy's HTTP upstream. Direct installs choose Tailscale or self-signed TLS on the first run.

### Removed

- **Client/Server/Protocol:** Message queue editing is gone on every server. You can no longer edit a queued message in place, reorder queued messages, move a message between steering and follow-up, or save a queue edit, and the refresh and conflict banners are gone. The `set_queue` command is removed from the server, the mirror contract, and the app. The Mac queue editor is removed the same way.
- **Client:** The MCP Exposure mode `codemode-deferred` is gone. Pi treats it as `codemode`, and servers whose `mcp.json` still says `codemode-deferred` show as `codemode`.
- **Client/Server:** The iOS app and Share extension drop the App Transport Security exception for `ts.net`, which allowed plain HTTP and a self-signed certificate on Tailscale names. A `*.ts.net` pairing host now requires `tls.mode=tailscale`: `oppi pair` refuses one in `self-signed` or `manual` mode, auto-detection uses the Tailscale IP there, and the app rejects a pinned Tailscale-name invite with the fix. **Breaking:** an existing self-signed pairing on a `*.ts.net` name stops connecting after the app update. Run `oppi config set tls.mode tailscale`, restart, and pair again.

## [0.49.1] - 2026-09-18

Target: iOS `1.1.2` build `51`, `oppi-server@0.49.1`, and `oppi-mirror@0.49.1`.

### Added

- **Client:** USDZ wiki links, files, and Markdown embeds render with RealityView.
- **Client:** GeoJSON and TopoJSON wiki links, files, and fenced blocks open as MapKit maps with a JSON source toggle. Fenced maps are tap-to-open.
- **Server:** Same `Session.id` resumes on the workspace Main checkout when an Oppi-managed worktree is gone, with a live notice. Requires `oppi-server@0.49.1`.
- **Server:** Saved Agent create/update accepts first-class CLI flags. JSON remains for bulk/round-trip. Requires `oppi-server@0.49.1`.

### Changed

- **Compatibility:** Build 51 requires `oppi-server@0.49.1` and `oppi-mirror@0.49.1`.
- **Client:** Pi sessions and the pinned Pi agent always use the official Pi mark, labeled Pi.
- **Client:** Rendered maps and diagrams hide Viewing Options until Source; Source keeps the code reader.
- **Client:** Expanding a tool call to full screen slides in from the right instead of a sheet.
- **Mirror:** Smaller connected indicator in the terminal footer. Requires `oppi-mirror@0.49.1`.

### Fixed

- **Client:** Completed megabyte terminal logs index off-main and mount visible chunks only, instead of hanging or jetsamming one giant text view.
- **Client:** Large full-screen code files index off-main and mount visible highlighted chunks only.
- **Client:** Large unified diffs index off-main and mount visible chunks with horizontal overflow.
- **Client:** Streaming thinking traces virtualize chunk growth instead of replacing the whole text view on every delta.
- **Client:** Wrapped markdown reader code blocks grow with the wrapped height so remaining command text is not clipped.
- **Client:** Large bash output opens from a ranged sidecar window instead of waiting on the entire JSON; tap-expand uses that first window as preview, copy still fetches the complete sidecar.
- **Client:** Wrapped terminal chunks split at 64 visual rows so a long wrapped log does not stall the main thread.
- **Client:** Wrapped full-screen edit diffs paint on first open instead of empty chrome until wrap is toggled.
- **Client:** File reader Viewing Options no longer overlap previous/next. Documents use one leading prev/next pill; audio and video keep split corners.
- **Client/Server:** Host-workspace wiki links outside the session workspace open through an explicit real path, including in-tree symlink targets.
- **Client:** All Sessions and workspace session search keep Results after opening a hit.
- **Client:** Long unfocused Ask cards scroll inside the expanded-surface cap instead of filling the chat.
- **Client:** Staged review comments show on git-context and commit file views.
- **Server:** File browser follows in-tree symlink directories even when the target is outside the workspace or home.

### Removed

- **Client:** Removed Grid π and the assistant avatar setting. Saved Agent and workspace icons are unchanged.

## [0.49.0] - 2026-09-11

Target: iOS `1.1.2` build `49`, `oppi-server@0.49.0`, and `oppi-mirror@0.49.0`.

### Added

- **Client/Server:** Completed text writes, including empty files, open through the current session file reader instead of a tool-output sheet. Relative control-file reads require the matching 0.49.0 server.
- **Client:** Session lists put Message (with a leading mic, matching the composer) on the left and Files on the right. On iPhone and compact width, Message is long enough to cover session titles. Regular iPad stays compact.
- **Client:** Review comments stay available from the chat timeline and full-screen document views, with a tighter pill and drawer.
- **Client:** CSV and TSV files render as fitted read-only tables, with source mode still available.
- **Client:** HEIC and HEIF workspace files open as images.
- **Client:** Tree-sitter syntax highlighting now covers JavaScript, TypeScript, Python, Go, Rust, Java, C-family languages, YAML, TOML, and more.
- **Client:** Wrapped JSON code blocks can be pretty-printed.
- **Client:** Dictation supports AirPods and keeps YouTube and in-app playback going. Brief analyzer backpressure no longer fails the take; sustained overflow fails closed and can be retried. On-device transcription streams SpeechTranscriber volatile partials without fastResults (iOS 26) and uses the iOS 27 speech audio converter, with speech models kept ready between takes. A disconnected-microphone take is discarded and can be retried.
- **Client/Server:** Server dictation can stream through xAI using existing xAI provider credentials.
- **Server:** `oppi session wait` defaults to four minutes and returns the last busy snapshot when it times out. Session list and search accept relative ages.

### Changed

- **Compatibility:** Build 49 requires `oppi-server@0.49.0` and `oppi-mirror@0.49.0`.
- **Client:** Dictation selects an AirPods or speaker-facing microphone, waits less for first live PCM before reporting ready, shows listening chrome on tap, and gives haptic confirmation when capture begins.
- **Client:** Official Pi is the default Pi-agent mark. Stored Classic π migrates on load. Grid π stays selectable.
- **Client:** Server Status reports the embedded Pi SDK and the installed Pi TUI version independently.
- **Mirror:** Terminal diagnostics rotate into UTC daily files, retain 14 days, and delete only exact valid daily filenames.

### Fixed

- **Client:** Ask answers submit once and remain retryable after a delivery failure.
- **Client:** Outline jumps keep the selected row, keep the first row below the navigation bar, and resume live-tail following after returning to the bottom.
- **Client:** Oppi-backed inline images load without an extra tap. Inline video keeps playback controls and authenticated range playback.
- **Client:** Workspace delete is reachable again from Server Settings and Edit Workspace, with confirmation.
- **Client:** Shared and exported files keep their original names.
- **Client:** Timeline file pills no longer crash when no audio player is mounted.

### Removed

- **Client/Server:** Removed unused authentication compatibility code. If pairing fails after an upgrade, update the server and re-pair.
- **Server:** Removed OpenAI batch dictation. Yuwp-compatible HTTP streaming and xAI remain; OpenAI Codex model access, login, and quota reporting are unchanged.
- **Client:** Removed the unused session-list prompt swipe.
- **Client:** Removed Classic π as a Pi-agent avatar.

## [0.48.0] - 2026-09-04

Target: iOS `1.1.2` build `48`, `oppi-server@0.48.0` with bundled Pi runtime `0.85.0`, and `oppi-mirror@0.48.0`.

### Added

- **Client:** One audio player for Oppi-backed Files and chat embeds, with lyrics when a timed-text sidecar exists. Session lists show a Now Playing pill while it plays.
- **Client:** Swipe left on a live workspace session to pick a prompt template and send it without opening chat.
- **Client:** The host pill opens Usage, Model Providers, and Server Settings for the selected server.
- **Client:** README-style Markdown file links such as `[Contributing](CONTRIBUTING.md)` open in the document viewer.
- **Client:** Oppi-backed `![]()` and `![[]]` both embed image, audio, and video after origin checks. Remote HTTPS images stay tap-to-load.
- **Server:** `oppi session`, `wait`, and `schedule` accept an exact `Session.id` or a unique prefix. JSON, HTTP, and `oppi://session` links stay full UUIDs.
- **Server:** `oppi session create --auto-stop` stops the session when the turn settles. Pending Ask/select/confirm keep it alive.
- **Server:** Live Pi `registerEntryRenderer` custom entries can show as the existing system timeline card on HTTP trace. File-only sessions stay hidden; raw entry data is never serialized. Refs #28.

### Changed

- **Compatibility:** Build 48 requires npm latest `oppi-server@0.48.0` and `oppi-mirror@0.48.0`. Bundled and installed Pi is `0.85.0`.
- **Client:** Commit-detail New Session attaches a commit pointer, not every changed file.
- **Client:** The in-chat extension strip is pills only. The full-width glass bar is gone.
- **Server:** Bundled Pi runtime moves to `0.85.0`. In-turn compact remains. Anthropic thinking effort persists for the turn. Built-in tools honor `ctx.cwd`. Skills still load when Bash is the only tool. Session forks keep their compaction boundary. Grok Build 0.1 is removed from the xAI catalog.

### Fixed

- **Server:** `npm pack` clean-builds from current source and fails if packed JS has no matching `server/src` file or if `/server/mobile-output-guide` is missing. npm `0.47.3` shipped stale `dist` (deleted Oppi agent files, and no Mobile Output Guide route), including Cursor Cloud packs.
- **Client:** Leaving Pi Tools writes the Back-time selection and checkbox/mode changes. Nested `NavigationLink.onDisappear` never PUT in Build 47.
- **Client:** Streaming GFM tables no longer leave raw header pipes above the table.
- **Client:** Replayed cache-miss notices stay beside the paying assistant.
- **Client:** iPad composer hides Write with Siri.
- **Client:** Composer turn-ack caption hides after send.
- **Client:** Photo picker presenter stays mounted so a second pick can complete.
- **Client:** Expanded Markdown in tool cards stays inside the card, and expanded row height republishes so the card does not clip.
- **Client:** Annotate Add to Chat attaches the PNG only. PaperKit OCR text is not dumped into the composer.
- **Client/Server:** Expired short-lived `at_` closes live streams with `4001` and refreshes without logout or a new `dt_`. Dictation delivers `dictation_final` before that close; leftover `dt_` is migrate-only.
- **Server:** `oppi server install` uses `gui/<uid>` when available and falls back to `user/<uid>` for headless macOS. Fixes #31.
- **Docs/Mirror:** Session-tree navigation in Oppi Mirror works. Fixes #30.

### Removed

- **Client:** Removed last-reply dictation vocabulary extraction, on-device Foundation Model hinting, and the related Voice settings. `dictation_start.contextualStrings` remains for a future source.

### Notes

- `oppi-mirror@0.48.0` on npm latest includes the session-tree navigation fix.

## [0.47.3] - 2026-08-27

Target: iOS `1.1.2` build `47`, `oppi-server@0.47.3` with bundled Pi runtime `0.84.3`, and `oppi-mirror@0.47.3`.

### Added

- **Client:** Oppi-backed wiki video embeds play inline at 16:9.
- **Client:** Compact mode keeps live work condensed into compact strips for a quieter timeline.
- **Client:** Composer Canvas and Annotate use PaperKit and attach a PNG to the originating chat.
- **Client:** Mermaid diagrams are more polished: they use the app theme, render clearer nodes, and cover more graph types, including top-down timelines, horizontal XY charts, gitGraph, quadrant, sankey, kanban, and journey.
- **Client/Server:** Tokyo Night and Rosé Pine ship as importable server themes.
- **Client/Server:** Model Providers show remaining percent and pace.
- **Server:** `oppi session list` can filter by activity time. `oppi session wait` polls until idle or attention and can print a compact still-waiting summary.
- **Client:** The composer keeps queued photos and files.
- **Server:** Sandbox sessions can mount a guest `.pi` overlay and keep selected host extension tools on first boot or a recycled VM.

### Changed

- **Compatibility:** Build 47 requires `oppi-server@0.47.3` and `oppi-mirror@0.47.3`. Bundled and installed Pi is `0.84.3`.
- **Client:** Markdown rendering and streaming are refactored for better performance and stability. Live documents settle on one streaming clock and keep your place when a document finishes.
- **Client:** Model and thinking defaults use Pi 0.84.3. The picker star saves the Pi global default. A row tap stays on the current session. Thinking menus list the current model's supported levels and can Save as Default. The default composer and Quick Session pill show the catalog model id and provider icon.
- **Client:** Full-screen diffs were consolidated onto one word-level highlighter so completed views show changed words consistently.
- **Client:** Appearance retints more surfaces when Light/Dark changes.
- **Server:** Bundled Pi runtime packages move from `0.84.2` to `0.84.3` in lockfile, package manifests, and installed `node_modules`.

### Fixed

- **Client:** Compact inbox still scrolls while the sidebar is revealing.
- **Client:** Wiki table links open, and the chat back stack returns to the prior offset.
- **Client:** Wiki-linked files keep Comment and Annotate, and Annotate attaches a PNG to the source chat.
- **Client:** Large Org files virtualize instead of freezing the reader.
- **Client:** Inline LaTeX keeps escaped underscores and common TeX delimiter / iff aliases.
- **Client:** Access-token renewal keeps the same connection. The focused chat recovers its session stream and shows recovering when that stream is down.
- **Client:** Assistant history uses Pi entry ids to reduce duplicate rows.

### Removed

- **Client:** Nearby-Mac pairing is gone from onboarding.
- **Client/Server:** The default Oppi agent and Oppi wrapper extension are gone. Control uses ordinary Pi and the `oppi` CLI.
- **Client:** Quick Session last-model memory and workspace default-model settings. New sessions use the Pi default.

## [0.46.0] - 2026-08-10

Target: iOS `1.1.0` build `45`, `oppi-server@0.46.0` with bundled Pi runtime `0.84.1`, and `oppi-mirror@0.46.0`.

### Added

- **Client/Server:** Agents, schedules, Skills, and workspaces can be created or revised through an Oppi session from their management screens.
- **Client/Server:** Custom provider extensions can contribute models. Server details show Codex and xAI quotas, and Qwen has dedicated presentation.
- **Client:** Full-screen Markdown supports review comments, improved wide-table layout, and guided revisions from selected text.

### Changed

- **Server:** Custom provider extensions appear in the model picker and provider-auth list after install, a detected source edit, or enable/disable without an Oppi server restart. Active sessions still need `/reload`.
- **Protocol/Client/Server:** Agent, schedule, Skill, workspace, model, and session APIs changed incompatibly; Build 45 requires `oppi-server@0.46.0`.
- **Server:** Explicit model selection fails visibly when the requested model is unavailable instead of substituting another provider or model.
- **Client/Server:** Session, tool, Markdown, and cached-content presentation survives navigation, replay, and reconnection more consistently.
- **Server:** Oppi Mirror bootstrap input now expands slash commands, skills, and prompt templates through Pi instead of sending them as literal text.

### Fixed

- **Client/Server:** Kept workspace Skill toggles scoped, patched nested schedule actions correctly, completed cache persistence before follow-up reads, preserved owner themes, and gated navigation swipes on the touched scroll edge.

## [0.44.1] - 2026-07-16

### Notes

- Coordinated release for iOS `1.1.0` (build `42`) and `oppi-server@0.44.1`.
- `oppi-mirror` remains at `0.44.0`; this release does not publish a new mirror package.

### Added

- **Client/Server:** When Pi's `showCacheMissNotices` setting is enabled, live prompt-cache misses render as warning timeline rows with re-billed token and cost details. Notices are intentionally live-only and are not reconstructed after reload.
- **Client/Server:** Workspace rows show tracked, staged, and untracked Git summaries, updated from workspace API responses and app events.
- **Client:** Chat drafts are stored per session and survive navigation, app relaunch, and server switching until sent or cleared.
- **Server:** Local `oppi` commands use a bearer-authenticated Unix socket, so CLI traffic stays local and remains available when the remote TLS listener is offline.

### Changed

- **Server:** Updated the embedded Pi runtime packages to `0.80.8`, bringing cache-friendly dynamic extension tool loading and current provider/session-affinity fixes into Oppi sessions.
- **Client/Server:** The Mac app, terminal users, and managed host sessions use the same `oppi` executable installed by `npm install -g oppi-server`. The Mac app requires the npm package and does not bundle a second server runtime.
- **Server:** The package now requires Node.js 24 and compiles with the TypeScript 7 native compiler.
- **Client:** Internal builds honor the **Send Diagnostics to Server** setting, so device-local diagnostic uploads can be turned off when needed.

### Fixed

- **Client:** Isolated session and timeline caches by server, refreshed mounted views after theme changes, and reduced stream and dense-session navigation work that could stall the UI.
- **Client:** Cold-launch session links now wait for cached or refreshed sessions before routing, so Live Activity and notification links open the intended chat instead of the workspace root.
- **Client:** Kept long ask cards above the keyboard, preserved cross-block Markdown text selection and the dictation caret, and kept the Quick Session composer fitted while dismissing it only after a successful launch.
- **Client:** Preserved workspace scope after editing, kept the configured thinking-level order, showed queued attachment names, and returned edited review comments to the staged list.
- **Server:** Kept local and config commands working without Tailscale or a session database, and prevented managed agent sessions from targeting themselves through `oppi session`.
- **Client/Server:** Branched Pi sessions now open and page the active tree leaf without showing messages from another branch.

### Removed

- **Server:** Removed the unreachable `oppi-admin` extension from the npm server package.

## [0.44.0] - 2026-07-11

### Notes

- Coordinated release for iOS `1.1.0` (build `41`), `oppi-server@0.44.0`, and `oppi-mirror@0.44.0`.

### Added

- **Client:** iPhone and iPad now open to a sessions-first inbox. Sessions needing attention and sessions still working stay prominent, recent stopped sessions remain available, and a workspace sidebar or drawer opens workspace-specific sessions, files, and settings without replacing the inbox.
- **Server:** Expanded the `oppi` CLI for workspace, worktree, and session orchestration. It can create and manage workspaces and worktrees, launch sessions, send or queue messages, answer pending dialogs, watch or wait on session state, and inspect history progressively without loading a full trace.
- **Mirror extension:** Added durable lifecycle evidence for agent, turn, and tool activity in terminal-owned Pi session files.

### Changed

- **Protocol/Client/Server:** Stored attachments and tool-reported external files now load through session-scoped authenticated routes, including exact external paths reported during that session. Apple clients and servers must be updated together for these routes.

### Fixed

- **Client:** Collapsed file tool rows now prioritize showing the full filename before shortening directory paths, including when badges, edit stats, or first-pass layout reduce the available width.
- **Client:** Tool rows now use consistent backgrounds, borders, text colors, and status colors across light and dark themes.
- **Client:** Following the system appearance now loads the correct light or dark theme and recolors existing code, diffs, tool output, and session rows when appearance changes.
- **Client:** Relative images and links in session file previews resolve from the file being viewed, including in full screen.
- **Server:** Skill and extension toggles now write Pi project settings for that workspace, so changing a resource in one workspace no longer mutates global settings for other workspaces.
- **Mirror extension:** Pending blocking dialogs now replay after the bridge reconnects, so an unanswered terminal prompt remains available in Oppi.

### Migration notes

- **Mirror extension:** Install or refresh `oppi-mirror@0.44.0` after publish, then use `/reload` in any already-running interactive Pi session.

## [0.43.1] - 2026-06-30

### Notes

- Server-only npm patch; no Apple client version or protocol changes.

### Changed

- **Server:** Updated bundled Pi support to `0.80.3`.

### Fixed

- **Server:** Fixed session file previews for touched files that resolve through workspace symlinks while keeping outside-workspace paths blocked.

## [0.43.0] - 2026-06-30

### Notes

- Release prep for iOS TestFlight build 40 and npm `oppi-server@0.43.0`.
- This release focuses on a first pass at worktree-aware sessions, lower-resource long-session trace loading, extension widget and working-message rendering, Markdown/Mermaid reliability, and a Pi runtime refresh to `0.80.2`.
- Saved-agent and schedule foundations are included for server/CLI work, including approved automatic schedule runs.
- This release also prepares `oppi-mirror@0.43.0` so mirrored working-message forwarding can ship through the Pi extension package.

### Added

- **Client/Server:** Added a first pass at worktree-aware workspace/session context, including worktree metadata, selected-worktree quick actions, session launch context, and session-row indicators.
- **Client/Server:** Added trace paging and outline data so very long session histories can load in chunks instead of loading the full trace at once.
- **Client:** Added separate Session Outline and Session Files panels, inline file-browser back controls, optional haptic feedback controls, the Icon Composer app icon, and an Oppi docs prompt toggle.
- **Client:** Expanded Mermaid rendering coverage for flowcharts, sequence diagrams, state diagrams, mindmaps, and Gantt charts.
- **Mirror extension:** Added forwarding for extension working messages, working indicators, hidden-thinking labels, and tool-expanded state from terminal Pi sessions.
- **Server:** Added saved-agent, schedule, background schedule-runner, and commit-review launch foundations for CLI/API use.

### Changed

- **Server:** Updated embedded Pi runtime packages to `@earendil-works/pi-coding-agent@0.80.2`, `@earendil-works/pi-ai@0.80.2`, and `@earendil-works/pi-tui@0.80.2`.
- **Server:** Saved-agent updates can clear optional description, instruction, resource, and session-default fields with `null`.
- **Client/Server:** Extension widget/status UI now projects working status, extension-provided working messages, and working indicators natively; renders styled terminal widgets; groups widgets into strips; and throttles widget snapshots.
- **Client:** Stopped workspace previews stay hidden so the workspace home screen focuses on active or actionable sessions.

### Fixed

- **Client:** Fixed read-image attachments, deferred SVG markdown images, ordered markdown lists around code blocks, wrapped detached code blocks, review-comment markdown surfaces, review file chrome, and What's New tracking for TestFlight builds that share a marketing version.
- **Client/Server:** Fixed persistent mirror UI replay after reconnect and reduced noisy turn-lifecycle info logs.
- **Server:** Fixed active trace indexing for session search and tightened session cleanup boundaries.
- **Client:** Fixed nearby-pairing invite delivery acknowledgement before the pairing flow advances.
- **Mac:** Fixed Mac app startup when another owner already manages the server process.

### Migration notes

- **Server:** Update npm installs with `npm install -g oppi-server@0.43.0` after publish. App-managed runtimes update through the Oppi app bundle, not `oppi update`.
- **Mirror extension:** Install or refresh `oppi-mirror@0.43.0` after publish, then use `/reload` in any already-running interactive Pi session.

## [0.42.0] - 2026-06-22

### Notes

- Coordinated release prep for iOS TestFlight build 39 plus npm `oppi-server@0.42.0` and `oppi-mirror@0.42.0` after the `0.41.0` compatibility release.
- This release focuses on grouped session files, extension UI stability, large-output/timeline reliability, and a Pi runtime refresh to `0.79.10`.

### Added

- **Client:** Added directory grouping in Session Files so touched files are easier to scan in large sessions.
- **Client/Server:** Added a redacted app event stream and UX telemetry coverage for live client/session events.
- **Client/Server:** Added extension-surface viewport entry points and replay coverage for scoped widget/status UI.
- **Server/Extensions:** Added first-party Pi extension packages for the existing `ask` flow and browser automation video tool.

### Changed

- **Server:** Updated embedded Pi runtime packages to `@earendil-works/pi-coding-agent@0.79.10`, `@earendil-works/pi-ai@0.79.10`, and `@earendil-works/pi-tui@0.79.10`; this brings Pi extension compaction event metadata (`reason`, `willRetry`) and exact-version `pi update` fixes into future Oppi-seeded runtimes.
- **Packaging:** Bumped coordinated server and first-party Pi extension package metadata to `0.42.0` so the update can publish after npm `0.41.0`.
- **Client:** Session rows and titles now follow generated Pi session names, real completion/unread timing, and server health instead of heartbeat noise.
- **Client:** Large markdown/code/diff tool output and cached timeline rows now use bounded caches, viewport policies, and deferred fullscreen rendering instead of letting release-candidate rows keep growing memory or layout cost.
- **Client/Server:** Extension UI state is grouped by semantic scope, keeps background widgets out of blocking prompt badges, and reconnects permission-gate sessions before sending responses.
- **Client/Server:** Pi settings/resources now live in the workspace resource UI, with loaded resource counts visible in session stats.
- **Server:** Host-backed Oppi SDK sessions now load Pi skills and extensions through Pi's settings/resource resolver instead of separate workspace skill and extension allow-lists, so project `.pi/skills` and `.pi/extensions` follow the same enabled/disabled rules as terminal Pi.

### Fixed

- **Client:** Fixed busy timeline anchoring, top-scroll edge cases, streaming markdown rendering, markdown code-block sizing, escaped inline LaTeX delimiters, and full-screen code font metrics.
- **Client:** Fixed workspace directory listings for dot/generated folders and safe reads for session-created workspace files.
- **Client:** Fixed disabled biometric gates, nearby-pairing callback safety, and redacted push/session event payloads.
- **Client/Server:** Fixed mirrored session heartbeat timestamp churn, compact session-tree payloads, Pi TUI task-record log spam, bridge reuse resilience, and session-catch-up reconnect behavior.
- **Server:** Fixed release diagnostics so WebSocket telemetry avoids raw URL metadata and the mechanical review gate checks the current protocol type file.
- **Dependencies:** Updated direct `ws` usage to `8.21.0` for the Oppi server and `oppi-mirror` package.
- **Dependencies:** Updated Vite/esbuild/tsx lockfile entries, the duplication-scan CLI flag, and the server lockfile's `undici` resolution to `6.27.0`, clearing `npm audit --omit=dev` for production dependencies.

### Migration notes

- **Server:** Update npm installs with `npm install -g oppi-server@0.42.0` after publish. App-managed runtimes update through the Oppi app bundle, not `oppi update`.
- **Mirror extension:** Install or refresh the Pi extension with `pi install npm:oppi-mirror` after publish, then use `/reload` in an already-running interactive Pi session.
- **Compatibility:** `oppi-mirror@0.42.0` requires Oppi server `0.41.0` or newer and an interactive terminal `pi` process.

## [0.41.0] - 2026-06-16

### Notes

- Public server and Pi extension compatibility release for npm `oppi-server@0.41.0` and `oppi-mirror@0.41.0`.
- This release focuses on Pi extension compatibility, mirrored terminal sessions, media playback, long tool output, review tools, and safer server packaging.
- iOS TestFlight build 38 covers the main compatibility release. The build 39 candidate adds grouped Session Files and targeted stability fixes on top of build 38.

### Added

- **Server/Packaging:** Added npm package metadata and validation coverage for `oppi-server@0.41.0`, including packed-install smoke paths for local macOS, Mac Mini, and Linux Docker validation.
- **Packaging:** Added the public `oppi-mirror@0.41.0` Pi extension package, installable with `pi install npm:oppi-mirror` after publish.
- **Protocol/Client/Server:** Added native rendering for Pi extension prompts, replayable widgets, custom trace messages, queued approvals, status/notification requests, tool snapshots, and fallback text.
- **Client/Server:** Added video playback from workspace files, session attachments, and expanded tool rows with authenticated byte-range streaming and system controls.
- **Client:** Added reader controls for text size, line spacing, wrapping, Mermaid state diagrams, markdown code-block wrapping, and full-output viewers for large tool results.
- **Client:** Added review-comment drafts for selected code and tool output, with composer draft restoration before sending.
- **Client:** Added directory-grouped Session Files in the build 39 candidate.

### Changed

- **Client/Server:** Pi extension prompts cover more Pi UI requests in SDK and mirrored sessions, including select, confirm, input, editor, queued approval, status, notification, and widget rendering.
- **Server:** Removed Oppi's custom subagent server implementation from this release path; subagent-style work now goes through Pi extensions or custom agents.
- **Client/Server:** Mirrored terminal sessions can reconnect, replay supported extension UI, queue follow-up messages, and hand control between terminal Pi and Oppi without losing pending prompts.
- **Client:** Expanded tool rows use native or virtualized viewers for long markdown, code, images, video, and media output instead of oversized timeline cells.
- **Client:** Session rows keep completion/unread timing stable when heartbeats, background status, or busy timeline appends arrive.
- **Client:** Workspace file browsing shows real directory entries, including dot directories and generated folders, while protected raw reads remain guarded.

### Fixed

- **Server:** Fixed SDK `/reload` so live Pi extension code reloads in the active session instead of only refreshing resource metadata.
- **Server:** Fixed release diagnostics so WebSocket telemetry avoids raw URL metadata and the mechanical review gate checks the current protocol type file.
- **Server:** Reduced noisy mirror task-record rejection logs for non-openable Pi task records.
- **Client/Server:** Fixed mirrored terminal widget replay, takeover prompts, stale contexts after compaction, concurrent forwarded dialogs, dead `pi-tui` session cleanup, and heartbeat-driven session-row timestamp churn.
- **Client:** Fixed long tool output truncation and timeline instability by loading full output on demand and evicting older cached output under memory pressure.
- **Client:** Fixed review-comment controls hiding behind the keyboard on iPad and duplicate selection actions.
- **Client:** Fixed split file navigation after compact-width rotation, escaped inline LaTeX delimiter rendering, and full-screen code font metrics.
- **Dependencies:** Updated Vite/esbuild/tsx lockfile entries and duplication-scan CLI compatibility.

### Migration notes

- **Server:** Update npm installs with `npm install -g oppi-server@0.41.0` after publish. App-managed runtimes update through the Oppi app bundle, not `oppi update`.
- **Mirror extension:** Install or refresh the Pi extension with `pi install npm:oppi-mirror` after publish, then use `/reload` in an already-running interactive Pi session.
- **Compatibility:** `oppi-mirror@0.41.0` requires Oppi server `0.41.0` or newer and an interactive terminal `pi` process.

## [0.4.0] - 2026-06-01

### Notes

- Release candidate for macOS app `0.2.0`, npm `oppi-server@0.4.0`, and the separate public Pi extension package `oppi-mirror`. The release focuses on Pi terminal mirroring, a mobile bridge for Pi extension UI, broader extension API compatibility, and the adaptive iPad workspace shell.

### Added

- **Server:** Added mirror mode for continuing Pi terminal sessions from mobile.
- **Protocol/Client/Server:** Added an extension UI relay so standard Pi extension input and confirm flows can be shown and answered on Apple clients.
- **Client/Server:** Added persisted MetricKit crash diagnostic upload gated by the Send Diagnostics to Server setting.
- **Client:** Added nearby Apple pairing discovery and an adaptive iPad workspace shell.
- **Client:** Added review-comment selection flows for file and tool output.
- **Packaging:** Added the separate public Pi extension package `oppi-mirror`, installable with `pi install npm:oppi-mirror` after publish.
- **Docs:** Added public deep-link documentation and refreshed setup, security, telemetry, sandbox, mirror, and extension docs.

### Changed

- **Server:** Replaced the custom Oppi approval flow with standard Pi extension permission handling for broader extension compatibility.
- **Client:** App-owned deep links now use only the `oppi://` scheme; retired `pi://` handling was removed.
- **Client:** Model switches now apply immediately without the prompt-cache warning dialog.
- **Client:** Renamed the public diagnostics toggle to “Send Diagnostics to Server” and clarified that it covers performance metrics, client breadcrumbs, and crash diagnostics.

### Fixed

- **Server:** Fixed server-side model switching so requested models are resolved against a refreshed runtime model registry.
- **Client:** Fixed the workspace session-list header wrapping/layout issue in the workspace overview.

### Removed

- **Server:** Removed the retired server approval stack and related routes.
- **Client:** Removed retired Apple permission screens.

### Migration notes

- **Server:** Existing Pi extensions with their own input, confirm, or approval flows can use the mobile extension UI bridge and should mostly behave as they do in terminal Pi. Existing configs with retired approval keys still start, but approval behavior now belongs to Pi extensions.

## [0.1.2] - 2026-03-31

### Notes

- Last public GitHub release before adopting this changelog. See the GitHub release and commit history for details.

[Unreleased]: https://github.com/duh17/oppi/compare/v0.48.0...HEAD
[0.48.0]: https://github.com/duh17/oppi/compare/v0.47.3...v0.48.0
[0.47.3]: https://github.com/duh17/oppi/compare/v0.46.0...v0.47.3
[0.46.0]: https://github.com/duh17/oppi/compare/v0.44.1...v0.46.0
[0.44.1]: https://github.com/duh17/oppi/compare/v0.44.0...v0.44.1
[0.44.0]: https://github.com/duh17/oppi/compare/v0.43.1...v0.44.0
[0.43.1]: https://github.com/duh17/oppi/compare/v0.43.0...v0.43.1
[0.43.0]: https://github.com/duh17/oppi/compare/v0.42.0...v0.43.0
[0.42.0]: https://github.com/duh17/oppi/compare/v0.41.0...v0.42.0
[0.41.0]: https://github.com/duh17/oppi/compare/v0.4.0...v0.41.0
[0.4.0]: https://github.com/duh17/oppi/compare/5c3ba2f4cf23...v0.4.0
[0.1.2]: https://github.com/duh17/oppi/releases/tag/v0.1.2
