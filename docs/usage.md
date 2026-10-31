# Using Oppi

Daily phone and tablet use after you have paired a server. Pairing is in [Onboarding](onboarding.md). Pi slash commands, skills, compaction, and the TUI stay in [Pi's usage guide](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/usage.md).

![Session and search](demo/session-combined.png)

![Timeline and files](demo/timeline-combined.png)

## Screen map

The Workspaces tab opens **All Sessions** for the active server.

- **Your Turn**: sessions waiting on you (a question, an approval, a sign-in, or a result you have not seen). Blocked sessions come first.
- **Working**: sessions that are busy.
- Stopped sessions sit below, grouped by day, each with its workspace name.

Every row and thread shows the same status. **Working** is blue. **Needs approval**, **Question**, and **Sign-in** are orange. **Error** is red. **Done** is green until you open the session on this phone, then it reads **Idle** (grey). **Stopped** is a stopped session you have seen or that ended without a result. Seen state is kept per device and resets when the app restarts.

A workspace's session list has the same sections, rows, and swipe actions. It adds the worktree picker, host Pi sessions you can import, and older stopped history grouped by month.

The sidebar or drawer holds saved Agents and schedules, the workspace list, App Settings, and each workspace's sessions, files, and settings.

Open a session to see the chat timeline. Tap a tool row to inspect its command, output, diff, or file content. If an extension shows a card or sheet, answer it in the app.

### Session Threads

A session that other sessions launched shows as one row, with a **Thread strip** under it. The strip starts on the row's title column and ends where the row's time and status end, and so does the **N Stopped** row under an open thread. It names the child that needs you (**Question · Waiting agent 1**), then shows one dot for each active child (blue and pulsing while it works, orange when it needs you, red when it ended in an error; at most 12, then **+N**), the saved Agents among the children (shown as many as fit), and a count line, such as "1 idle · 102 stopped · $9.18". The count line names only the children the dots leave out, the idle and the stopped ones in that order, so a working, blocked, or erroring child is said once, by its dot; a thread with nothing active draws no dots and its count line names every child. VoiceOver reads the full counts either way, working through stopped, with the cost. The counts use the same split as the open thread: a child counts as **stopped** exactly when it sits behind the thread's **N Stopped** row, and every other child counts as working, needs you, error, or idle, so the stopped count always matches that row. A child that finished counts as idle whether or not you have opened it, and opening a child never changes the strip. Counts, dots, and Agent icons cover the children, not the root, so they add up, and a state with none is left out. Idle and stopped children get no dot. The strip draws a line only while that line has something to say: the blocked child's line while a child is blocked, the dots while a child is working or needs you, and always the counts, the Agents, and the chevron, with nothing active leaving one line. It changes height only when a child becomes blocked, when the thread's first child starts working or needs you, or when its last one settles, never as a child moves between working, idle, and stopped otherwise. The line shows the thread's cost unless the **Cost** row setting is off, the root is locked, or nothing has cost anything yet (a cost of zero is left out, never "$0.00"), and a cross-workspace note when it fits: past the width the note goes first and only then do the counts truncate at the tail beside the cost, so a crowded thread never loses its price. A locked root shows names and counts only. A thread with work in progress stays in **Working**, and one with a blocked session sits in **Your Turn**.

Tap the session row to open its chat. Tap the strip to open the thread in place: its sessions, children and grandchildren, appear as indented rows under the root, with their own status. Tap the strip again to close it. Each row is an ordinary session row: tap it to open that session, swipe or long-press it to stop, resume, lock, or delete it. The strip's chevron turns down while the thread is open, and VoiceOver reads **Expanded** or **Collapsed**.

An open thread lists the sessions that matter first, in the order the list itself uses: the ones in Your Turn (waiting on you first, then the oldest activity), then the working ones (newest launched first). Stopped sessions fold behind one **N Stopped** row at the end of the thread, closed until you tap it; open, it lists them newest first. The strip's stopped count is that row's count. A thread whose sessions have all stopped has nothing live to list first, so it has no second row to tap: opening the strip lists its stopped sessions directly. A session listed under its parent starts one title column further in, so its icon sits where its parent's title starts, and a session whose parent sits in the other group indents under its nearest listed ancestor, or sits at the first level when it has none. A branch sorts by its most urgent session, so a session that needs you keeps its parent directly above it and moves the pair up the list. The **N Stopped** row has its own Expanded or Collapsed state for each thread, settled the first time the thread opens and kept after that: a thread opened while children are still going keeps its stopped ones behind the closed row, and a thread opened with nothing live lists its stopped sessions instead, so a child starting or stopping changes which sessions the thread lists, never whether the stopped ones are folded away. Closing and reopening the thread keeps the state, and it resets when you switch servers or worktrees.

A link `oppi://thread/<session-id>` opens All Sessions with that session's thread open in place and scrolled to its root; for a session inside a thread it opens the root's thread. See [Deep links](deeplinks.md).

A thread lists every session in it, even one that runs in another workspace; that row names its workspace. In that other workspace's own list the session is a row with an **In thread** link under it, and tapping the link opens the root session's chat.

### Session rows

**Settings → Session Rows** (the row shows Standard or Compact) sets **Standard** or **Compact** rows and turns optional details on or off: model, time, context usage, cost, files touched, and compactions. **Agent Summary** controls the Thread strip. Changes save for this device. **Restore Defaults** resets them. A session gets a name from you, or from the optional [`auto-name` extension](extensions.md#auto-name). The title, status, questions, Incognito, workspace context, search matches, and Thread control always show.

## Prompt, steer, follow-up, and stop

When the session is idle, the composer says **Message…** and Send starts a new turn. While the agent works, toggle how to send:

| Mode | Composer | What it does |
| --- | --- | --- |
| **Steering** | Steer agent… | Guides the current turn. |
| **Follow-up** | Queue follow-up… | Queues the next instruction after this turn. |

If an Ask card is visible, the composer answers that prompt instead. With an empty composer during a busy turn, the primary action is **Stop**.

## Siri, Quick Session, and the share sheet

**Siri** starts a session with a prompt and opens that chat. Say "Start a session in Oppi", "Open a session in Oppi", or "New session in Oppi", optionally followed by "in <workspace>". Without a prompt, Siri asks "What should Pi do?". Siri and Shortcuts show the exact prompt, the workspace, and (with more than one server) the server for you to confirm before anything is sent. Invisible formatting characters are removed from the prompt first, so what you confirm is what is sent. Cancel sends nothing. The same confirmation applies when the prompt comes from another Shortcut action. Prompts over 280 characters or 12 lines are too long to confirm; open Oppi and send them from the app.

**Quick Session** opens the composer without creating a session yet. Launch it from Oppi, Control Center, the Action Button, or the Shortcuts **New Session** action.

**The Shortcuts New Session action** reads "Open *Agent* in *Mode* mode". Every field is optional, and an empty one follows Quick Session's own choice:

| Field | Values | Empty |
|---|---|---|
| Mode | Message, Dictation, Live Voice | Message |
| Agent | Any active saved Agent on a paired server | The Agent Quick Session last used, or Pi |
| Workspace | Any workspace on a paired server | The workspace Quick Session last used on the Agent's server |
| Text, Image | Composer text and one image | None |

In Live Voice mode (needs the Live Voice experiment below), text and an image are the call's first message, and an Agent starts without one: what you say first is its first message. The Agent and workspace must be on the same server. Set the Action Button to **Shortcut** and pick this action to put a voice-assistant Agent, with its own model, tools, and extensions, one press away.

**Live Voice** is an experiment, off by default. Turn it on under **Settings → Experiments → Live Voice** (saved on this device; needs a server with a voice backend). Control Center, the Lock Screen, and the Action Button then offer **Live Voice**, which starts a session straight into a call in the workspace and Agent Quick Session last used. Siri: "Talk to Oppi" or "Call Oppi". The call keeps going with the screen locked, in another app, or when you leave its chat for the session list or another session; open that session's chat to see the call again, and end it there with **End**. Every other screen in the app shows the call in a strip at the top: the session, what the call is doing, how long it has run, **Mute**, the audio output (speaker, earpiece, AirPods), and **End**; tap the strip to go back to the session's chat. The session's row in the lists carries a phone mark (a crossed-out mic while muted). On iPhone and iPad the system also shows it as a call with the session's title (status bar, Dynamic Island, Lock Screen, and a paired Apple Watch or CarPlay) with Mute and End, AirPods mute works, and a phone call you answer puts Live Voice on hold until the phone call ends. One call runs at a time: while it is on, dictation and read-aloud are off everywhere in the app. You can keep typing in other sessions; their mic button becomes **Live Voice**, which asks to end the current call and start one there. Quick Session offers no Live Voice during a call. A draft left in Quick Session is saved, not sent into the call. If the workspace, Agent, or voice backend is unavailable, Quick Session opens, says why, and brings the draft back. With the experiment off, Live Voice entries open Quick Session instead.

**Incognito:** tap the eye-slash pill beside the workspace in Quick Session to start one session Incognito. The Pi session lives in server memory only, with no transcript, search entry, or restart resume. Leaving its chat ends it: the server stops and deletes it. Opening Files, a reader, or a fork, switching tabs, or App Lock locking the app does not end it. The pill is not offered with a saved Agent selected.

The iOS share extension accepts text, URLs, images, and files. Choose a workspace in its Quick Session composer, then start the session from the share sheet.

## Files and photos

Attach files from the Files picker, photos and videos from the library, or a camera capture. An attachment uploads with the session turn; canceling before send uploads nothing. Videos upload as files, not as model image input.

Assistant output opens markdown, code, diffs, and other documents in full-screen viewers. See [Document viewers](document-viewers.md).

### Git panel

In a chat whose workspace is a Git repository, **Git** in the top bar's menu (or its button, if you pin it) shows how many files the session changed and opens a panel with the branch, the changed files, and the commit graph (a sheet on iPhone, a column beside the chat on iPad). This is where a chat reviews what changed; a workspace that is not a Git repository has no Git panel and no change list. The graph shows the session's checkout and every local branch, and a ring marks the session's commit. Tap a file for its review or a commit for its detail. **Select** picks files to start a session or a prompt template with.

- A session in its own worktree opens on **This worktree**: every change in that worktree, including ones its shell commands made.
- A session in the main checkout opens on **This session**. **All changes** lists every change in the checkout.
- **This session** is approximate: it lists the files the session's edit and write calls touched, not changes its shell commands made. A file Git can diff opens its review; one Git does not report (already committed, or outside the repository) says **no diff** and opens the session's copy. Its header counts both (**3 touched · 1 with changes**), and **Select** picks only files Git reports.

### Files panel

**Files** in a chat browses the session's checkout (a sheet on iPhone, a column beside the chat on iPad), the same browser as a workspace's Files screen. Search finds files by name or path anywhere in the checkout; below the top folder, the scope bar narrows a search to **Everywhere** or the folder you are in. **View Options** sorts folders by **Name**, **Date Modified**, **Size**, or **Kind** (choose the same one again to reverse it), and turns **Folders First** and **Show Hidden Files** on or off (hidden files stay out of search too); the choice applies to every file browser on the device. A file Git reports changed carries a colored dot (green added, orange modified, red deleted or conflicted, purple renamed) and its line counts, and a folder with changes inside has a gray dot. Changes show only while the session's Git status is loaded; when Git reports more changes than it lists, the folder says how many files show no mark.

A workspace's session list has the same **Git** button in its top bar, listing every change in the selected worktree.

## Voice

**Settings → Voice & Dictation → Dictation Engine** is **On-device** (the default) or **Server**.

- **On-device** uses Apple's speech APIs. Audio stays on the phone; submitting the transcript still sends the prompt to the server.
- **Server** streams audio to the paired server, which forwards it to its configured speech-to-text backend. See [Server configuration](server-configuration.md#dictation-asr--stt).

With the server's read aloud configured, a finished assistant reply has a speaker that reads it aloud (tap again to stop). See [Read aloud](server-configuration.md#read-aloud). Selecting text in a message shows a microphone first in the edit menu, then **Comment**; the microphone starts dictating into the comment draft.

**Settings → Voice & Dictation → Dictation Animation** picks the listening control: **Composing** and **Breathing** (voice-reactive Metal orbs) or **Ring** (the default for new installs). **Settings → Chat → Busy Animation** picks the busy-row animation: **Orbiting** (the default for new installs), **Searching**, **Solving**, **Pi**, or **GoL**. The orbs adapt Thinking Orbs geometry: Jakub Antalik created the original [thinking-orbs](https://github.com/Jakubantalik/thinking-orbs), Haplo LLC made the Swift [ThinkingOrbs](https://github.com/haplollc/ThinkingOrbs) port, and Oppi adds Metal rasterization and voice-reactive motion. The MIT notice is in `clients/apple/Shared/Renderers/Orbs/LICENSE`.

## Chat display

**Settings → Chat → Style** sets how every chat looks, unless the chat's Agent sets its own (see [Agents and schedules](#agents-and-schedules)):

- **Full** (default): every tool call and thinking block.
- **Compact**: each turn's tool calls and thinking fold into one strip you tap to expand, showing **Icons** or **Words**.
- **Chat**: a messaging layout with trailing bubbles for your messages, cards for replies, and a **Worked 9s · 2 steps** pill per turn.

**Settings → Chat → Top Bar** chooses which buttons a chat's top bar shows and their order: **Files**, **Git**, **Outline**, **Context** (the usage ring), and **Terminal**. The default shows only Context; the rest sit in the **…** menu, which always stays and has **Customize Top Bar…**. A button the chat cannot use is not shown: no Files, Git, or Terminal without a workspace folder, no Git outside a Git repository (or with Git status off), no Outline for an empty timeline, and no Terminal for a sandbox or relative-folder workspace. **Terminal** opens a login shell in the session's folder ([Open Terminal here](ssh-terminal.md#open-terminal-here)).

## Appearance

**Settings → Appearance** picks a built-in theme (Dark, OLED, Light, Night) or an imported custom theme, by hand or matching Light and Dark to iOS Display & Brightness. Custom themes are JSON files on the server; see [Custom themes](themes.md).

## Agents and schedules

The sidebar holds saved **Agents** and **Schedules**.

- Agents store reusable definitions and can use one Unicode emoji or SF Symbol as an icon.
- **Edit Agent → Chat Style** picks how that Agent's sessions look on this device: **Full**, **Compact**, **Chat**, or **Settings** to follow **Settings → Chat → Style**. The choice is per device and restyles the Agent's open sessions too.
- Schedules support `at`, `every`, and `cron` triggers. A one-time `at` schedule moves to Archived after its run succeeds; a failed run keeps it active. A `cron` time inside the hour that repeats when daylight saving time ends runs on its first occurrence only. A schedule targets a workspace, a saved Agent, or an existing session. Oppi keeps run history for manual and approved automatic runs.

## Edit with Oppi

Describe a change in a composer: a list's composer to create something, or the **Describe a change…** bar at the bottom of a detail page to change it (the bar shows the model and thinking pills once you tap it). A document offers the same route as **Edit with Session**, in its **…** menu beside the pencil. Each request opens a new **Oppi Control** session in the regular chat. It inspects the current setup, asks if the outcome is unclear, shows the change, and applies it. A change to an Agent, schedule, workspace, or session through Oppi's tools waits for a confirm card: the card says in plain words what changes; tap its button (for example **Apply Change** or **Create Agent**) to send it or **Cancel** to skip it, and the server enforces the card. Files (Skills, extensions, themes, Pi's `SYSTEM.md`) and commands the session runs through its shell (server settings, the dictation dictionary) get no card: the session says what will change and asks first, which is an instruction to the model, not an enforced confirmation. At the end it tells you where to see the change and whether a running session must reload.

Oppi Control sessions work on every server, whether or not [Durable Sessions](#durable-sessions) is on. They use Oppi's own setup prompt, not your global Pi prompt ([Oppi Control sessions](extensions.md#oppi-control-sessions)). Pi Control sessions from before keep working on the classic engine.

| Surface | Create | Change |
| --- | --- | --- |
| Agents | Composer in the Agents list | The bar on an active Agent's page; comments on its definition become the request |
| Schedules | Composer in the Schedules list | The bar on a schedule's page; comments on its prompt become the request |
| Pi's system prompt (`SYSTEM.md`) | | The bar on the Pi entry under Agents; comments on the file |
| Skill files | | The **…** menu on an editable Skill's file holds **Edit with Session**, with your staged comments |
| Extensions | | **Edit with Session** in the chat's context panel, or the bar on an extension's page (single files you own) |
| Custom themes | Composer in **Settings → Appearance → Custom Themes** | Swipe a theme, or touch and hold, then **Edit with Session** |
| Workspaces | **Create with Oppi** in the create sheet | The bar in Workspace Settings (hidden while the workspace is locked) |

## Sandbox, Mirror, and Terminal

- [Sandbox workspaces](sandbox.md) run agent file tools and shell commands in a Gondolin VM.
- [Oppi Mirror](oppi-mirror.md) shows a live terminal Pi session in Oppi.
- [Terminal](ssh-terminal.md) opens a shell on a host saved on this device (**Settings → Terminal**, or **Terminal** below **MCP Servers**). A workspace's or chat's **Terminal** button opens that folder on the saved host.

## Durable Sessions

Durable sessions run on the server's durable engine instead of the classic Pi session. The server saves each turn as it happens and resumes interrupted work after a restart without sending your message again. They do not match terminal coding agents feature for feature: they run only extensions that ship a durable entry, have no session tree, export, or reload, and cannot be incognito.

Turn on **Server Settings → Durable Sessions** (off by default). It is a setting of the server, for every device paired with it, and it applies at once: the server starts offering durable sessions to new sessions without a restart. From the host, `oppi config set experimental.serverDurable true` does the same at the next restart. Turning it off stops new durable sessions; sessions that are already durable keep working and keep resuming.

While it is on, Quick Session shows a **Classic** pill beside the workspace; tap it to start that one session **∞ Durable**. **Start Sessions as Durable**, under the switch, is this device's choice: it makes durable the default, and the pill switches one session to Classic. A saved Agent follows the same default. Incognito sessions are always Classic.

Durable sessions appear in All Sessions with a small **∞** after the title and follow **Settings → Chat → Style**. A durable session has no tree, so Outline lists the timeline and you fork from a message to branch. A fork keeps the session's Agent setup (Extensions, MCP, Skills, and instructions), including a fork at the first message.

A durable session runs only extensions that ship a durable entry ([Durable extensions](extensions.md#durable-extensions)), plus MCP when the Agent selects it. It offers Pi's own tools as **Pi → Tools** sets them, as a classic session does: `read`, `bash`, `edit`, `write`, and the optional `grep`, `find`, `ls`, `codemode`, and `tool_search`, in host and sandbox workspaces. A running session picks up a tool you turn on there the next time it attaches; one you turn off stays until the session ends. MCP servers follow their exposure as in classic: a server on the default `codemode` exposure turns codemode on, and scripts call its tools; `tool_search` loads them for direct calls. When a saved Agent selected extensions that have no durable entry (or that `oppi extensions disable` turned off), the session shows a warning that names them.

From the CLI, `oppi session create --workspace <id> --prompt <text> --engine durable` starts a durable session (it fails while Durable Sessions is off). Add `--agent <name>` for a saved Agent, or use `oppi schedule create --engine durable`.

A durable session can start helper sessions with its `subagent` tool. Each child opens from the tool row or the **Subagents** pill above the composer and is listed in All Sessions. The pill's title counts every child and its subtitle says how many are working or need you. It shows up to eight children as Working, Needs attention, Done, or Error, with model and context use (those that need you first, then the working ones, then the newest done ones); expand it to see what each child is doing now, and tap its last row, **All N in thread**, to open the whole thread. A child reports each answer back to its parent as a card that names the sender and kind (report, task, or message), folded to its first lines; tap the card to read it all, or the sender's name to open the child. A child can start its own children only when its parent allows it, and can work in a git worktree of its own on a branch named after it, so an editing child never touches its parent's checkout.

## Models and quota

Pick models from the in-app picker. Remaining provider quota and pace are under **Server Settings → Model Providers**, in `oppi quota`, and in `oppi models`. See [Provider quotas](provider-quotas.md).

## Workspace settings

**Workspace Settings** (a workspace's slider button, or Server Settings → Workspaces) opens with the workspace's icon, name, and folder. Tap it for **Details**: name, description, icon, and **Workspace Folder**. A new folder is checked on the server first, and Oppi offers to create one missing directory. Details has its own **Save**; going back discards edits.

Below it: **Instructions** (its own editor and **Save**), **Skills** and **Extensions** (each row counts how many are enabled, such as "5 of 8"), **MCP Servers**, and **Dictionary**. A sandbox workspace also has **Network Access** (Allowed Hosts, with its own **Save**). **Project Trust** is read-only. Toggles (Skills, Extensions, sandbox MCP servers, **Show Changes in Chat**) apply as you flip them and flip back with the error if the server refuses. **Delete Workspace** is last and asks first.

## Server settings

**Server Settings** (host switcher → Server Settings, or Settings → your server) opens with the server's name and connection status, then **Model Providers**, **Workspaces**, **Dictionary**, **Paired Devices**, **About This Server**, and **Badge Icon**. On the same screen: **Mobile Output Guide** ([what it does](extensions.md#mobile-output-guide)), **Server Metrics** (off by default; see [Server Metrics](server-configuration.md#server-metrics)), **Durable Sessions** (off by default; see [Durable Sessions](#durable-sessions)), **Notifications** (push and Live Activities, per server), **Lock Server**, and **Remove Server**. Add another server from Settings.

**About This Server** shows connection, uptime, the Pi SDK, Pi TUI, and server versions, and the **Voice** backend states. Its row reads **Update Available** when a newer `oppi-server` is on npm.

- **Global npm install:** an **Update** button names the version and warns that running sessions will be interrupted. Oppi installs that exact version, restarts the server, and reconnects. Interrupted sessions resume ([Running sessions across a restart](server-configuration.md#running-sessions-across-a-restart)). `oppi update` on the host uses the same check.
- **Checkout `npm link`ed as the global `oppi`** (what `setup.sh --install` sets up): the server never installs from npm. When the checkout has changes the running build lacks, **Rebuild & Restart** runs `npm run build:in-place` there and restarts. A failed compile keeps the running build and shows the error.
- **Installer install** (`install.sh`, in `~/.oppi/install`): **Update Available** with the copyable installer command instead of a button. Run it on the host; it upgrades and restarts the service.
- **Other installs** (other git checkouts, Docker images): a copyable `npm install -g oppi-server@…` command instead of a button.
- If the server is older than this app needs and nothing newer is available, the row reads **Server Outdated** and names the needed and available versions. All Sessions also shows a notice that opens Server Settings until you update and reconnect.

**Paired Devices** lists devices paired with this server. Your device is marked **This device** and has no Revoke button. For others, **Revoke** asks first, then signs that device out at once. See [Onboarding](onboarding.md#paired-devices).
