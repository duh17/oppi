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

Keep one top-level product changelog for coordinated client/server releases. Use component scopes inside bullets instead of duplicating the same release across multiple files. If `oppi-server` or an Apple client starts releasing on a truly independent cadence, add a component changelog at that artifact root and include it in that artifact's package/release.

An entry tells someone who runs Oppi what is different after they update. Write it for the people using the app and server, not for a reviewer of the diff.

- **Include** what a user, operator, or extension author can notice: new or changed behavior, noticeable performance changes, fixes for bugs that reached a shipped build, security and privacy fixes, removals, and anything that needs action on update.
- **Leave out** refactors, renames, test and CI work, contributor scripts, internal storage layout, and bugs that appeared and were fixed in the same unreleased cycle. When a refactor changes what users see, describe only that change.
- **One bullet per feature or fix, one or two sentences.** Say what changed and where (screen, setting, command, or API), not how it works. Edge cases, limits, and wire details belong in `docs/` or the commit message; link the doc.
- **Update, don't append.** When later work changes an unreleased feature, rewrite its bullet so `[Unreleased]` describes the current state. No bullet may contradict a later one.
- **Migration notes** hold whatever needs action or breaks a mixed-version setup: version requirements, breaking protocol changes, irreversible data migrations, and config changes.

Use these component scopes:

- **Client:** iOS/macOS app changes, UI, onboarding, app settings, TestFlight-facing behavior.
- **Server:** CLI, pairing, session runtime, policy, storage, telemetry, extensions, npm package behavior.
- **Protocol:** wire-contract changes that require both server and Apple updates.
- **Docs:** README, setup, security, release, and troubleshooting docs.
- **Build:** requirements for building Oppi from source.

Example:

```markdown
### Changed

- **Client:** **Settings → Chat → Style** picks Full, Compact, or Chat. It replaces the Compact Turns toggle.

### Fixed

- **Client:** Tapping a notification while another chat is open shows the tapped session instead of an empty timeline.

### Migration notes

- **Compatibility:** Build 55 requires `oppi-server@0.52.0`; update the app and the server together.
```

## [Unreleased]

### Added

- **Client:** Quick Session has an **Incognito** pill beside the workspace. Leaving an incognito chat ends the session and deletes it, so it no longer lingers in Your Turn. The workspace list's long-press Incognito Session menu is gone.
- **Client/Server:** The chat **Context** panel breaks the context window down in request order: system prompt, AGENTS files, Skills, messages, tool declarations, MCP tools, and the compaction reserve, plus the tools loaded on demand that cost nothing yet. Collapsible sections list each AGENTS file, Skill, tool source, MCP server, and extension with its size. An extension's page shows its tools and offers **View Source** and **Edit with Oppi**, which starts a session that changes the extension.
- **Client/Server:** **Server Metrics** in the host pill menu shows the server's CPU, memory, and disk and the Oppi server process's CPU, memory, and sessions over the last 30 days. The menu item appears only while sampling is on. On macOS and Linux it reads the machine; in Docker or another container it reads the container's own usage against its limits. The Server section moved there from Usage, and **Server Settings → Server Metrics** turns sampling on and adds the menu item. It is off until you turn it on, and off costs nothing. See [Server configuration](docs/server-configuration.md#server-metrics).
- **Client/Server:** Read aloud: a speaker under a finished assistant reply reads it with the server's text-to-speech provider, an OpenAI-compatible server such as Yuwp or Grok voice, set with `oppi config set tts` and a server restart. Grok voice also needs an xAI sign-in or API key before the speaker appears. Playback starts after the first sentence while the rest is synthesized. See [Read aloud](docs/server-configuration.md#read-aloud).
- **Client:** Usage adds 1y and All ranges for token and cost history.
- **Client:** SSH Terminal: touch and hold the terminal, then lift, to paste. A pasted image is saved on the host and its path pasted, so Claude Code and pi in direct typing get the image. Hold and drag still selects. The terminal keyboard's bar has two rows of keys that scroll together, with the chat button and ⌄ (hide keyboard) pinned at the right on a tinted dock. The input bar's key strip scrolls too, instead of paging. See [SSH Terminal](docs/ssh-terminal.md#input-bar-touch-and-keyboard).
- **Client:** SSH Terminal keyboard: the keyboard's mic dictates into the shell as you speak, each revision replacing the last, the space-bar trackpad moves the shell's cursor, held Delete speeds up to whole words after a second, and a hardware keyboard adds ⌘C, ⌘K, and ⌘. (Esc), Option as Meta, and Shift-Return and Option-Return for apps that read them. See [SSH Terminal](docs/ssh-terminal.md#hardware-keyboard).
- **Client/Server:** Live Voice (experimental): long-press the composer mic in a chat and choose Live Voice to talk to that session hands-free, with its model, tools, and history. What you say arrives as your message, and the agent answers out loud with a `speak` tool it has only during a call and is asked to acknowledge each request before it starts working; if it never speaks, the start of its reply is read. Long-press the mic in Quick Session to start a new session straight into a call. During a call the chat input bar is the call: the dictation indicator moves with your voice and the agent's (tap it to mute), what you say shows in the field until it is sent, End takes the place of Send, and you can still type and send; a draft from before the call comes back when it ends. `asr.liveVoiceBackend` picks the voice: `yuwp` listens with local ASR, sends one message each time you pause, and speaks with the read-aloud `tts` voice; `grok-voice` listens and speaks with Grok Voice and the server's xAI sign-in. A call keeps going past the app's 10-minute sign-in refresh and rejoins after a server restart, and Live Voice settings apply to the next call without a restart. Approvals during a call are answered on screen. See [Server configuration](docs/server-configuration.md).
- **Client:** SSH Terminal stays connected when you leave its screen and keeps running for about 25 seconds after Oppi goes to the background, so short trips no longer drop the shell. A reconnect within 5 minutes of your last Face ID, Touch ID, or passcode approval for that host signs in without asking again. See [SSH Terminal](docs/ssh-terminal.md#keeping-a-terminal-open).
- **Client/Server:** SQLite explorer (Durable Sessions experiment): durable sessions can open a `.sqlite` file in the workspace, list its tables, and run read-only queries, shown in a Data widget. A database another program closed in WAL mode opens as a snapshot. It needs the `sqlite3` command on the server; the Docker image includes it.
- **Client/Server/Relay:** End-to-end-encrypted push through Oppi's relay at `push.oppi.chaosdonkey.dev` ([spec](protocol/push/spec.md)): turn on **Server Settings → Notifications** (Push Notifications) after the server sets `push.mode relay`. You get Needs you (approvals, questions, sign-ins) showing the question or approval it waits on, Session Failed when a top-level run stops with an error, and messages the agent sends on purpose with the new `notify` tool when it has finished something for you to read or you asked to be told ("notify me when the tests finish"); there is no alert for every finished run. Top-level sessions get `notify` only while push is on, and failed-run and agent alerts show even with Oppi open unless you are in that chat. The app icon badge counts sessions that need you or have an unseen result, each once, and counts down as soon as you open one, which also clears its notifications. The server sends a phone only the alert types its app can open, and opening Oppi clears any "You have a new notification" alerts it could not read. Each device gets at most 100 alerts a day and 10 a minute, with room always kept for approvals. App Store and TestFlight builds need App Attest to turn push on, and each phone holds one relay registration. Before push turns on, the app says the relay and Cloudflare see the push token and alert timing, and that App Attest tells Apple this install uses push, with a Privacy Policy button. See [Push notifications](docs/server-configuration.md#push-notifications) and the updated [Privacy Policy](docs/privacy.md#push-notifications).
- **Client/Server/Relay:** Live Activities: turn on **Live Activities** in Server Settings' Notifications section (off by default) for one Lock Screen and Dynamic Island card per server that shows counts only, such as "3 running · 1 needs you"; each thread counts once, so a lead whose subagents are still working counts as running. With push on for that server, the server starts, updates, and ends the card through the relay while Oppi is closed, at most once a minute and 40 times a day per phone, apart from the alert budget. A dismissed card stays away until nothing is running or waiting. Without push, the card updates only while Oppi is open. Turning Live Activities on with push on, or push on with Live Activities on, first says the card's two counts go to the relay, Cloudflare, and Apple unencrypted. See [Live Activity](docs/server-configuration.md#live-activity) and the [Privacy Policy](docs/privacy.md#push-notifications).

### Changed

- **Client:** The chat screen, composer, Ask card, Session Outline, and every sheet and settings page are rebuilt in UIKit, so opening chats, scrolling, and moving between screens is faster.
- **Client:** Long-press and double-tap on your messages and assistant replies select text instead of opening a Copy menu or copying the whole message. Finished replies no longer have a Copy button under them.
- **Client:** The Ask card keeps Send and Ignore in reach: long options wrap, and a long list scrolls inside the card.
- **Client:** Mermaid diagrams lay out for the width they are shown at, in chat and full screen, instead of one phone-sized canvas that was then shrunk. A diagram that would overflow tightens its spacing, rewraps labels, or turns top to bottom (or, for mindmaps and timelines, switches to an outline or top-down layout), whichever keeps its text largest.
- **Client:** Scrolling up in a chat loads earlier messages before you reach the top, without moving what you are reading. The **Show earlier messages** button is gone.
- **Client:** The chat composer is clear Liquid Glass, like its pills and the app's floating controls, instead of a near-opaque panel.
- **Client:** Durable Sessions experiment: new sessions start Classic; the composer's pill switches one launch to Durable, and **Start Sessions as Durable** makes Durable the default. Durable sessions show ∞ in All Sessions, and the sidebar's Durable list is gone.
- **Server:** Durable sessions run saved Agents (`engine: "durable"` in `oppi session create --agent` and schedules; the app still starts saved Agents Classic). They manage children with one `subagent` tool instead of four `session_*` tools, and list them in a Subagents pill above the composer, as the subagents example extension does; tap a row to open that child.
- **Server:** A durable extension is declared in its Pi package's `package.json` (`"oppi": { "durable": { "entry": "./durable.ts" } }`) and default-exports a plain pi-durable extension. See [Durable extensions](docs/extensions.md#durable-extensions).
- **Client:** The SSH terminal has no navigation bar: Back and a button holding status, Herdr, and … float over the top corners, fade while the keyboard is up, and never resize the remote shell. The chat bar grows over the terminal as you type instead of resizing it, keeping the program's cursor row in view. See [SSH Terminal](docs/ssh-terminal.md#input-bar-touch-and-keyboard).
- **Client:** Sheets follow your light, dark, or system theme, and a sheet opened from a navigation page shows its own title and buttons.
- **Client:** On iPad, Outline, Files, and Context open in a column beside the chat instead of full screen.
- **Client:** A server Skill's files open faster, in the same reader as other host files, so images, PDFs, and images inside Skill Markdown show too. Its file list opens without reloading the Skill.
- **Client:** Back on a pushed screen is a chevron only, so titles and bar buttons keep their room, and search in All Sessions, a workspace, Files, Skills, and Extensions uses the system search bar.
- **Server:** Embedded Pi runtime 1.2.0 → 1.3.0. Durable sessions keep their system prompt and tools after compaction, Claude Opus 5 and Haiku 5.5 can run with thinking off, more provider outages retry, and a tool call with malformed JSON fails instead of running with partial arguments.
- **Client:** Inline Markdown videos show a still frame with a play button and build their player only when you tap play, in chat and the full-screen reader. Scrolling through a chat with many videos no longer starts a player for each one. See [Markdown inline video](docs/attachment-rendering.md#markdown-inline-video).
- **Client:** Every search field matches the same way: the session timeline and tree, Files, `@` file and `/` command suggestions, models, sessions, Skills, Extensions, icons, and time zones. Words can come in any order, case and accents are ignored, and abbreviations such as `wf` for `web_fetch` or `fbv` for `FileBrowserView` work, without matching letters scattered across a paragraph.
- **Server:** In a Git repository, `@` file suggestions and Files search list tracked files and new files no ignore rule matches, and leave out Git-ignored ones like terminal Pi's `@`. They load much faster in large repositories, and source files no longer drop off a list filled with ignored files. Sandbox workspaces and folders outside Git still include ignored files. See [Document viewers](docs/document-viewers.md).

### Fixed

- **Server:** `oppi session send --follow-up` and `--steer` no longer fail with "requires an active streaming turn" when the session is idle or finishes its turn just before the send. An idle session is prompted right away; a busy one queues or steers as before.
- **Client:** Very large Mermaid diagrams, such as a long flowchart chain, a big sequence diagram, or a deep mindmap, render as diagrams in chat and the Markdown reader instead of showing their source.
- **Client:** A running `write` of a Markdown file keeps updating as it streams, in the expanded row and in the full-screen reader opened from it. Before, both stopped after the first few lines.
- **Server:** A scheduled run that fails because its Agent's selected Extensions or Skills are unavailable now says which ones (for example `agent_extensions_unavailable: extension_…`) in the run error and the server log, instead of only the error code.
- **Server:** Opening an older durable session that has no store (created before per-tree stores) no longer logs a server error on every read, and its Threads view shows the launch tree instead of failing.
- **Client:** Pairing by QR code or **Connect Manually** with a server you already paired, whose identity has since changed, now asks you to confirm a trust reset ("Server identity changed"), as invite links, Tailscale, and SSH pairing already did, instead of an ordinary trust prompt.
- **Server:** With `asr.provider` set to `xai` but no xAI sign-in or API key, the app no longer offers server dictation that fails on every take.
- **Client:** A message sent from Quick Session no longer comes back as the draft the next time you open Quick Session.
- **Client:** Leaving a chat right after sending no longer marks the message as failed and puts it back in that chat's composer.
- **Server:** An idle session no longer stops at the idle timeout while it still waits on a background job or a supervised subagent, so the lead now wakes when that work finishes. Extensions can hold the idle timeout the same way; see [Pending wake](docs/extensions.md#pending-wake-extension-api).
- **Server:** A background job killed by a server restart, reload, or Stop is now reported to the agent with its next turn instead of being silently lost. After a server restart or crash, an idle session that was waiting on a job gets the same continuation prompt as a session stopped mid-turn, so it wakes and learns which job died instead of sitting idle until the idle timeout stops it.
- **Server:** Durable sessions now log failures that pi-durable does not hand back to the caller, such as a throwing extension hook or listener, as `durable_store.report` warnings in the server log. Before, they were dropped silently.
- **Server:** `oppi session search` without `--workspace` or `--all` no longer fails with "Worktrees are not available for sandbox workspaces" when any sandbox workspace exists. It infers the workspace from the current directory again.
- **Client:** An open chat whose session changed many files in a dirty checkout no longer keeps the phone's CPU busy. The changed-files bar above the chat matched files far too slowly, and every session update redrew it.
- **Client:** In a long session that is still working, scrolling up loads earlier history all the way to the start, and Session Outline jumps to rows that are not loaded yet land on them. Before, older history stopped loading once new output arrived, a jump to an unloaded row did nothing and left later rows missing, and the chat could stop following new output.
- **Server:** In a mirrored terminal session, a question, confirmation, or other prompt the agent opens while the mirror is reconnecting, such as during a server restart, now appears on the phone once the mirror reconnects. Before, it showed only in the terminal and the phone sat on "Waiting on you" with no way to answer.
- **Client:** Tapping a row in Session Outline, including a search hit, closes the outline so the chat is visible, lands on exactly that row just below the top bar, and keeps it there while rows above it finish loading. After the outline closes, the row lifts slightly with a soft tint and a light tap (the tap follows Settings > Haptic Feedback; Reduce Motion keeps only the tint).
- **Client:** Session timeline search highlights the letters that match what you typed. Before, rows could keep highlights from an earlier keystroke or show none, and equally good matches came back out of order; they now stay in timeline order.
- **Server:** Session Outline rows for assistant replies jump to the reply again. Replies that followed hidden reasoning, a tool call, or split text pointed at a row the chat did not have, so tapping them did nothing.
- **Server:** Commit, Changes, and session file diffs show the fewest changed lines. Before, about a third of file diffs could show a blank line that was not in the file and shift the line numbers after it.
- **Client/Server:** Word highlights in diffs mark only lines that were actually edited, not unrelated lines that happen to sit side by side in a rewrite, and long edited lines highlight the changed words instead of the whole line. Diffs of rewritten prose, such as a trimmed changelog, open and scroll faster, and commit file diffs no longer download both full copies of the file.
- **Client:** Commit file diffs and the Changes review scroll smoothly on long diffs and long lines, and have the same Viewing Options as full-screen diffs: text size and Wrap Text, shared with them.
- **Server:** Sandbox sessions, classic and durable, discover Skills and read `AGENTS.md`, `CLAUDE.md`, and Skill files through the VM, so a symlink can no longer put a file the VM hides, such as `.env`, into the prompt. Classic sandboxes no longer hang at start on `.agents/skills` loop links, and `/skill:name` there reads through the VM instead of failing on the guest path on the host.
- **Client:** The iOS app on a Mac no longer crashes opening New Workspace, Add Server, or Connect through Tailscale.
- **Client:** Several audio cards in one message no longer collapse onto each other.
- **Client:** Choosing an Ask option and sliding your finger off the row no longer sends it, and the expanded Ask follows a theme change.
- **Client:** Blank thinking blocks, such as the ones some local models emit before each tool call, no longer leave empty rows in the chat.
- **Server:** A retried prompt or steer with an attachment is no longer rejected as a conflict after its turn has landed.
- **Client:** SSH Terminal: holding Delete on the on-screen keyboard repeats while typing in the terminal. A dictated phrase with a newline asks first, like a multi-line paste.
- **Client:** Editing a staged review comment shows one Save and one Cancel.

### Removed

- **Client:** The SSH Terminal's migration of the single saved host from before Build 53.
- **Server:** Classic sandbox sessions no longer load your global Skills; they discover Skills inside the workspace, through the VM.

### Migration notes

- **Compatibility:** Build 56 requires `oppi-server@0.53.0` and `oppi-mirror@0.53.0`; update the app and the server together. Against 0.52.0, Live Voice fails to start, read aloud and Server Metrics are hidden, push alerts can show only "You have a new notification", durable chats miss streamed cards and older pages, and **Edit with Oppi** on an extension fails.
- **Compatibility:** After an extension has had an **Edit with Oppi** session in the last 3 days, Builds 53 and 54 cannot load that server's session list or finish pairing from an invite.
- **Server:** Durable extensions found only by the file name `durable.ts`, or exported with `defineDurableExtension`, no longer load. Declare the entry in `package.json` and default-export the extension.
- **Relay:** Deploy the push relay before shipping an app build with Live Activities: the app's Live Activity state upload and the server's Live Activity sends use endpoints an older relay does not have.
- **Server:** Server resource sampling (`server-metrics-*.jsonl`) is now opt-in with `serverMetrics.enabled`, default off. The Grafana Server Health resource panels and the release gate's event-loop stall check have no new data until you turn it on in Server Settings or with `oppi config set serverMetrics.enabled true`.

## [0.52.0] - 2026-10-14

Target: iOS `1.1.2` Build `55`, `oppi-server@0.52.0`, and `oppi-mirror@0.52.0` (Pi 1.2.0).

### Added

- **Client:** App Lock (Settings → Privacy & Security) locks Oppi after a chosen time in the background and unlocks with Face ID, Touch ID, or the passcode. While it is on, the app-switcher snapshot and ask notifications hide session text, and destructive or credential actions ask for authentication first. Audio and video keep playing.
- **Client:** Lock a server, workspace, or session on this device from Server Settings, Workspace Settings, or the session's long-press menu. Opening a locked item from anywhere asks for authentication, and lists, search, and notifications show only its name, time, and status. Incognito sessions are always locked while App Lock is on.
- **Client/Server:** A new device that pairs through Tailscale, an invite longer than 90 seconds, or `auth.module` must be approved within 2 minutes on a device you already paired, with Oppi open. The host's `oppi` CLI cannot approve. A default 90-second invite and the first device pair as before. See [Onboarding](docs/onboarding.md#approving-a-new-device).
- **Server:** `auth.tailscalePairing: false` turns off Tailscale pairing, and `auth.module` loads your own module that can refuse requests or approve pairings. Paired Devices shows how each device paired. See [Server configuration](docs/server-configuration.md#auth-module).
- **Client:** The full-screen audio player has speed (0.75×–2×), chapters from M4B/MP4 files, resume for recordings of five minutes or more, and a sleep timer. `.m4b` files open in the player.
- **Client:** Speaker-tagged WebVTT or ASS sidecars show as a script with a cast, speaker colors, and the current line highlighted; tap a line to jump there. Stage directions such as `[laughs]` show as tags.
- **Client/Server:** Inline audio cards show the clip's length before you press play.
- **Client:** Every session row has one long-press menu: Open, Stop or Resume, Lock, Copy Session ID, and Delete.
- **Client:** The text-selection menu has a microphone that opens a comment draft and starts dictating.
- **Client:** Nerd Font icons show in tool output and the SSH terminal with any code font.
- **Client:** SSH Terminal: text a host program copies (OSC 52) goes on the iPhone clipboard, the terminal reconnects when you return to Oppi, and programs that report status (OSC 7501, such as Pi 1.1.0+) show a status symbol and a card when they need you. Program notifications (OSC 9/777) use the same card. See [SSH Terminal](docs/ssh-terminal.md).
- **Server:** `oppi session wait` reports each session's program status, and `--program-status` shows it in the terminal while waiting.
- **Client/Server:** Experiment: Live Remote Screen plays the Mac window granted to this phone. See [Using Oppi](docs/usage.md#live-remote-screen-experiment).
- **Client/Server:** For a server running from an `npm link`ed checkout, About This Server offers **Rebuild & Restart** when the checkout changed, instead of an npm update.
- **Server:** Durable control conversation (`oppi control open`, `oppi control send`): manage Agents, Schedules, and sessions by chat. Every write waits for a confirm card in the app. See [Extensions](docs/extensions.md).
- **Server:** `--idempotency-key` on `oppi agent create` and `oppi schedule create`, and `--turn-id` on `oppi session send`, make retries safe.
- **Server:** Durable sessions load extensions from Pi packages, and `oppi extensions reload` swaps in new code without a restart. A package that fails to load keeps its previous code.
- **Client/Server:** Messages between durable sessions (a child's task, its report, a sent message) show as a card naming the sending session instead of as your own message.

### Changed

- **Client:** **Settings → Chat → Style** picks Full, Compact, or Chat. Chat is a messaging layout: your prompts are bubbles and each turn's work folds into one pill. It replaces the Compact Turns toggle.
- **Client:** Your prompts are an elevated card that stands apart from replies, and built-in themes set their contrast automatically so prompts, reply cards, and inline code stay readable. See [Custom themes](docs/themes.md).
- **Client:** Custom Themes: describe a theme to have an Oppi session write it, or choose **Edit with Oppi** on an existing one.
- **Client:** Session rows, threads, and the inbox show one status from the server: Working, Needs approval, Question, or Sign-in, then Done or Error until you open the session, then Idle or Stopped. Idle is no longer green.
- **Client:** Extension notifications are a chip above the composer that names the extension, instead of a sheet you must dismiss.
- **Client:** Settings, Server Settings, and Workspace Settings are short indexes with one page per topic. Workspace toggles apply right away, so there is no global Save. Settings → Network is gone, and Customize Rows moved to **Settings → Sessions → Session Rows**. Destructive actions ask first.
- **Client:** "Require Face ID" is now **Confirm New Servers**, and MCP transports are named HTTP and stdio.
- **Client:** Durable Sessions experiment: new sessions start durable, and the composer's **∞ Durable** pill switches one session to Classic. Durable sessions show ∞ in All Sessions, and the sidebar's Durable list is gone.
- **Server:** Durable sessions support share, HTML export, auto-retry, auto-compaction, and sandbox MCP servers.
- **Client/Server:** A host workspace with an empty folder now gets its own folder under `<dataDir>/workspaces/` instead of using your home folder, and a workspace whose folder is the home folder or above it is refused. Existing workspaces without a folder get one when the server starts.
- **Client:** The SSH terminal no longer runs `ps` on the host every two seconds. The chat bar appears when an agent reports itself (OSC 7501) or Run on Connect starts `herdr`; otherwise use **Use Chat Bar**.
- **Client:** Layout follows the window instead of the device. Any regular-width window, including the iPhone Duo inner display, gets the workspace sidebar, readable widths, and side-by-side file lists, and folding or rotating keeps your place and draft. On iOS 27.1, iPhones with a side rail put toolbar controls on it.
- **Server:** Embedded Pi runtime 1.0.4 → 1.2.0.
- **Server:** `npm i -g oppi-server` installs the exact dependency tree Oppi was tested with, so a later Pi release cannot break a fresh install as it did for 0.51.0.
- **Server:** Sandbox runtime Gondolin 0.13.0: long-running sandbox VMs no longer leak file descriptors, and sandboxes no longer need Node.js 23.6.

### Fixed

- **Server:** Sandbox workspaces can no longer run programs on the host through their git config or hooks. As a result, sandbox workspaces no longer support worktrees.
- **Server:** Someone who knew a paired device's id could block its token refresh.
- **Client:** The Linux `/health` check no longer follows redirects, so another host cannot pose as an Oppi server.
- **Client:** Server responses and access tokens are no longer stored in the iOS HTTP cache, and removing a server deletes its cached data on the phone.
- **Client:** Rotating an iPad no longer leaves the open chat without live output, and folding or rotating keeps your place in the chat.
- **Client:** Tapping a notification while another chat is open shows the tapped session instead of an empty timeline.
- **Client:** Opening a thread while Oppi is still connecting no longer leaves a permanent "Server connection is unavailable" error.
- **Client:** Tapping the composer right after a back swipe no longer opens Quick Session.
- **Client:** Long-pressing a wiki link to an image, video, or other file no longer crashes the app.
- **Client:** The first syntax-highlighted tool row no longer freezes the chat for about 0.4 s.
- **Client:** Audio served with a generic type plays, and a clip that cannot play says why.
- **Client/Server:** Messages an extension adds to the transcript appear while the chat is open.
- **Client:** SSH Terminal **Paste** no longer asks "Allow Paste?" every time.
- **Client:** About This Server explains when the server is outdated but no newer version exists yet.
- **Client:** The code mode reader has **Viewing Options** for text size and wrapping.
- **Server:** Session search no longer indexes pasted screenshots, so text later in those sessions is searchable again and the index shrinks by about two thirds. Reindexing after each turn is about 15× faster.
- **Server:** Session lists show a workspace's current name after a rename.
- **Server:** Editor dialogs count as waiting for you in the ask badge, workspace attention, and `oppi session wait`.
- **Server:** A failed durable run shows one error with the real reason, and it stays after reconnect or restart. After a storage error, Oppi reopens the durable store and resumes its sessions instead of failing every action.
- **Server:** Messages between durable sessions are delivered once and only to the intended session.
- **Client/Server:** When a durable provider rewrites streamed text, the live bubble shows the new text instead of appending it.
- **Server:** Durable sessions no longer grow storage with every working-message update or keep a second copy of background job output.

### Removed

- **Server:** Direct APNs push and Live Activity updates from the server.
- **Server:** `GET /sessions/:id/read`; use `/trace`.
- **Server:** The legacy file routes (`/files/raw` and the workspace and session `raw` routes). File reads use `/files/current`.
- **Server:** The goal extension in durable sessions.

### Migration notes

- **Compatibility:** Build 55 requires `oppi-server@0.52.0` and `oppi-mirror@0.52.0` (Pi 1.2.0); update the app and the server together. Against a 0.52.0 server, Builds 53 and 54 cannot finish a pairing that needs approval, and cannot load the session list while a theme session has had activity in the last 3 days.
- **Compatibility:** File reads need iOS Build 53 or later and oppi-server 0.51.0 or later.
- **Server:** On first start, the server backs up `session-state.db` to `<dataDir>/backups` and rebuilds its tables. An older server cannot read the result; to roll back, restore the backup.
- **Server:** If startup cannot create a folder for an existing workspace, the server does not start and names the cause.
- **Server:** Long `oppi pair --ttl` hand-offs, such as App Review, now need someone to approve within 2 minutes of the scan.
- **Server:** Durable extension tools must return `output` instead of `content`; otherwise the model gets an empty result.
- **Server:** Durable sessions now store data per session tree under `durable/sessions/`. The old `durable/harness.sqlite` is no longer read and stays on disk.
- **Build:** Building the Apple apps needs Xcode 27.1; building TailscaleKit needs Go 1.27.1.

## [0.51.0] - 2026-10-05

Target: iOS `1.1.2` builds `53` and `54`, `oppi-server@0.51.0`, and `oppi-mirror@0.51.0`.

Entries labeled **Mac** describe work on `main`; the Mac app is not part of the iOS TestFlight build or its server release.

### Added

- **Client/Server/Protocol:** Durable and classic sessions now live side by side. `experimental.serverDurable` only makes durable sessions available; a session is durable only when its create request asks for `engine: "durable"` (`oppi session create --engine durable`), and asking while the flag is off fails with HTTP 409. Session summaries carry `engine: "durable"` and `/server/info` advertises `capabilities.durableSessions`. On iOS, Settings → Experiments → **Durable Sessions** is a temporary playground that may change or be removed in a later build. It adds a **Durable** item under Terminal: All Sessions narrowed to the server's durable sessions (including older stopped ones), whose quick session bar starts durable sessions through Quick Session; durable chats show a small Durable label. All Sessions and workspace lists still show every session. Saved Agents cannot start durable sessions yet: the Agent launch route answers HTTP 400 before saving a session, and a durable Quick Session hides the Agent picker.
- **Client:** A tool call whose input has a code-role field expands as a notebook cell: the source sits in an inset code cell, and nested calls and the result attach underneath, instead of a markdown note with fenced blocks. The collapsed row shows the first line of that code when the server did not send a title, skipping directive comments such as `// @options:`. Other generic tools (not terminal, file, media, or interactive) use the same cell: the card shows their arguments as YAML-style `name: value` lines, and printed output stays plain monospaced text, as a terminal shows it; only a result that is one JSON object, array, or string, or producer `expandedText`, is formatted. Like other tool rows, a tap expands the cell and a double-tap or pinch opens the full-screen reader; inline text no longer selects on double-tap. Inline, long code and output are trimmed with a "+N more lines" note and at most six calls show, so calls and output stay visible; the reader shows everything with text selection and review comments. Calls read as values (`git log -5`, `path: A.md`) with status icons and durations, and the cell no longer repeats the row's language, status, or call count.
- **Server/Protocol:** `outputPresentation.statusHeader` declares a pattern for a status preamble at the start of a tool's output. The registry declares Pi's codemode `Script completed / Wall time / Output:` header, and iOS hides it from the notebook output because the row already shows status and duration; copy keeps the raw text. A result cannot declare its own header. Older servers send no pattern and the header stays visible.
- **Client/Protocol:** Extension activity rows can carry `blocks`, making them disclosure rows: tap shows or hides the content, which is built only while open and stays open across widget updates. A row with both `blocks` and a `link` keeps the link on a trailing button. `terminal` blocks can carry raw `text` (colors, carriage returns, cursor motion) that iOS resolves with the bash-output VT engine; other clients show a plain projection. The background-jobs extension uses both: tap a job in the jobs drawer to see its live output tail. Requires an updated app; older apps show the rows without output.
- **Client/Server:** Full-screen extension surfaces stay live: the reader follows updates to the same surface and keeps the last one after the widget clears. The server now throttles repeated `setWidget()` replacements with the same 250 ms per-widget limit as redraw requests (newest content wins, clears are immediate), so in managed sessions no extension can push widget snapshots faster than that.
- **Client:** Pairing choices on first run and in Add Server include **Connect through Tailscale**, beside Scan QR and Enter manually. It opens the in-app Tailscale screen without a QR code; signing in is still yours to start.
- **Client:** Tailscale → Check a Mac for Oppi can pair this phone. When Oppi answers HTTPS on the machine's own loopback address, **Pair** mints a one-time invite over the SSH session and enrolls with it. A `*.ts.net` name is never dialed on the system network while the in-app Tailscale node is off.
- **Client:** Experiment, off by default: SSH Terminal (Settings → Experiments). Settings → Network → SSH Terminal, and Terminal below MCP Servers, open a host list saved on this device. Add and Edit open the setup form for host, port, username, and password or per-device Secure Enclave key sign-in. Tap a row to connect and open the shell; opening the list never dials or reads the Keychain. An existing host moves into the list without a Face ID prompt, and its password stays in this phone’s Keychain until the next connect. Swipe delete removes that host and its saved password only. Two rows can use the same machine with different Run on Connect commands. Tap the terminal to show or hide the keyboard. Add the public key to `~/.ssh/authorized_keys` yourself. Saved passwords stay in this device’s private Keychain and require user presence; Secure Enclave signing also requires approval. Trusted host keys use the same this-device-only Keychain store as Check a Mac: first connect asks you to verify the fingerprint, and changed keys block credentials. The accessory bar has Esc, Tab, Ctrl, arrows, and Paste; multi-line paste asks first; remote output cannot read or write the clipboard. SSH liveness probes, bounded waits, and a network-change hint make disconnects explicit. Staying in the background past a 25-second grace closes the shell; Reconnect opens a fresh shell without replaying input. Run `tmux attach` or `herdr session attach <name>` to continue remote work. When a coding agent (pi, Claude Code, Codex, and others) runs in the foreground, the terminal shows Oppi's chat input bar with dictation: Send pastes the text as one prompt and presses Enter. The key strip offers Esc, Tab, one-shot Ctrl and Alt, and a hold-and-drag arrow control, plus buttons for the program in front that send the key it binds; Ctrl-C is Ctrl then C, or that program's Stop button. When the host has `herdr`, a toolbar overview lists its workspaces and agents. No private-key import or keyboard-interactive. See [SSH Terminal](docs/ssh-terminal.md).
- **Client:** Experiment, off by default: Thread rows draw a small horizontal lane graph spaced by event order, not clock time. Children branch from the session that launched them and merge back at their last recorded activity once stopped (a start-to-latest-activity summary, not exact execution time), and working sessions pulse at the right edge. The saved Agents in the thread appear below as icons with counts (for example 🛠️×15 🔬×12). Swipe or long-press a thread row to stop any session that isn't stopped (idle included) or resume a stopped one. Thread detail has a **New session in thread** bar that opens Quick Session in the root's workspace and checkout; the new session (plain Pi or a saved Agent) joins the thread as a child of the root, and a thread pill in Quick Session shows the link — tapping it starts a standalone session instead.
- **Client/Server:** Pi → Tools has an Optional Pi Tools section with a switch for each tool Pi's extensions register off, such as `codemode` and `tool_search`. The server discovers them from the loaded built-in and user extensions, so `-builtin:codemode` hides codemode and a new opt-in extension tool appears on its own. The screen reads `defaultTools` the way Pi does: `["+codemode"]` shows Pi defaults with codemode on, and other `+name`/`-name` lists show their resolved tools. Turning a tool on with Pi defaults writes `+name`; with chosen tools it adds the name to the list.
- **Client:** Siri and Shortcuts can start a session with a prompt and open that live chat: say "Start session in Oppi", "Open session in Oppi", or "New session in Oppi", optionally "in <workspace>"; Siri asks "What should Pi do?" when no prompt is given. Before anything is sent, Siri, Shortcuts, and text chained from another Shortcut all show the exact prompt and the workspace (plus the server when several are paired) for confirmation, and the dialog shows the same text that is sent, with invisible formatting characters removed. A prompt over 280 characters or 12 lines is not previewed or sent; Siri says to open Oppi instead. Canceling creates no session and sends nothing.
- **Client:** The composer attaches photos and videos from Photo Library in one mixed pick. Photos stay annotatable image chips; videos are file-backed uploads rather than model image inputs, and they survive draft reopen, session switch, and a failed-send retry.
- **Client/Server:** Model Providers can show your ChatGPT plan's quota on official OpenAI models. It is opt-in: Oppi first confirms that the retained OpenAI Codex sign-in and the OpenAI sign-in share an account and workspace. The quota is labeled plan-wide, its app cap is unknown, and inference stays on official OpenAI.
- **Server:** Globally loaded Pi provider extensions can supply on-demand quota data to the native quota screens. Stream-only wrappers keep the built-in provider's quota; extensions that replace a provider's auth, endpoint, or catalog do not inherit it, and an extension's own quota source always wins.
- **Server:** Experiment, off by default: a durable backend for managed host and sandbox sessions, made available by the server flag `oppi config set experimental.serverDurable true` and a restart; a session uses it only when started as durable (see the side-by-side bullet above). It persists each turn in a conversation store and resumes interrupted work without sending a second user prompt. Durable sessions show extension UI from conversation state, page and outline history, keep goals (with decision cards in the transcript) and background jobs as durable conversation state, and show working words as activity plus elapsed time. They load AGENTS files, Skills, and host MCP servers (with the same project-trust prompt as SDK sessions), fork before a user message, spawn child sessions that the parent owns, and are found by search through their user text, assistant text, and tool names. A session already bound to a durable conversation keeps working, and keeps resuming after a restart, when the flag is turned off. Sandboxes reuse their workspace VM, provide guest coding/search tools and image reads, and kill the guest process group on Stop. The default remains the SDK. Durable sessions do not support classic extensions, selected sandbox MCP servers (these are rejected), Pi resource discovery, tree navigation, export, or reload, and compaction and retry detail parity is not complete.
- **Client:** Generic tool calls carry an Input / Calls / Output document with highlighted code inputs, recorded nested calls, and readable JSON forms and tables; iOS paints the notebook cell above from the same facts, inline and in the full-screen reader. Copy output still copies raw tool text. The Calls section opens with a summary such as "3 calls · 1 failed", lists each call with its status, name and duration, and puts arguments and a failure's error under that call; the collapsed row shows the same summary, and lists over 256 calls say how many were omitted. Nested live calls update their parent's Calls instead of appearing as extra timeline rows, completed grandchildren survive a late-starting intermediate parent, and an incomplete notice stays when live calls were dropped. Tool calls can show producer-resolved names such as `coros · Get activity detail`, with the raw identity kept in Input/Raw; MCP-provided titles are not shown yet because Pi drops them before its public session boundary, so display uses definition labels, result metadata, or MCP name conventions, and no icons are carried or fetched. Interactive inspection stays independent of the answer receipt, media keeps Input/Calls beside native attachments, empty generic output renders structured details without running Pi TUI hooks, and Raw identifies previews and loads full output from an available sidecar.
- **Client/Server:** Bash, file, diff, and interactive tool rows are drawn from facts the server sends with each tool call, not from the tool's name. Any tool with command-input and terminal-output facts gets the bash command panel, streamed tail previews, server summary title, and full-output paging. Read/write/edit and equivalent extension tools get the file and diff viewers: requested write content and args-derived edit diffs are labeled Requested, result diffs drive both the viewer and change counts, and collapsed file titles use server summaries. Interactive tools declare `outputPresentation.kind: "interactive"`, which drives question counts, automatic-expansion policy, and one answer receipt per call, live and after reload. Compact turns, Session Outline, Live Activity (`Running <title>`, no tool-name verbs), and copy output use the same facts; quiet edit counts use result diffs when available, otherwise labeled requested edits, and arbitrary interactive tools stay visible. Voice-mode changes require a registry-declared setting effect, so unrelated tools cannot change preferences by returning a voice-mode-shaped result. With an older server that sends neither input nor output facts, exact built-in bash/read/write/edit/ask keep native inspection through one OppiCore fallback, producer facts always win, and aliases and custom tools without facts stay generic.

[Showing lines 1-252 of 801 (50.0KB limit). Use offset=253 to continue.]