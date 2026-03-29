# Oppi User Guide

## Getting Started

Oppi lets you supervise coding agents from your phone. You connect to
a server running on your local network, and every agent session shows
up on your device in real time. You can watch what they do, approve
actions, answer questions, and browse your codebase — all from the
same app.

This guide covers the features available in Oppi as of March 2026.

![](screenshots/home-screen.png)

### Connecting to a Server

When you first open Oppi, the app guides you through pairing with a
server. The primary method is scanning a QR code — run `oppi pair` on
your server machine and scan the code from the Oppi iOS app using the
built-in camera scanner.

You can also add a server manually by entering its address. This works
for remote servers reachable over Tailscale or any VPN — the server
does not need to be on the same WiFi network.

Once connected, the app stays connected. If the network drops (WiFi
to cellular, walking out of range, phone sleeping), Oppi reconnects
automatically when the network returns. Session state is replayed
from the server, so you pick up exactly where things were.

### Workspaces

Each server manages one or more workspaces. A workspace is a project
directory on the server. Every agent session runs inside a workspace,
and the file browser shows that workspace's contents.

The home screen lists your workspaces with their current status.

## Sessions

A session is one agent run. The agent receives a task, works through
it, and eventually finishes. While it runs, every action streams to
your phone.

### The Session List

The session list shows all sessions for the current workspace. Each
row displays the session name, its status, elapsed time, and a short
preview of the latest activity.

![](screenshots/session-list.png)

Running sessions appear at the top. Tap a session to open its timeline.

### Starting a Session

Tap the compose button to start a new session. Type or dictate your
task. The session launches immediately and you can watch progress in
the timeline.

For quick tasks, the quick session sheet provides a lightweight way
to dispatch a short prompt. It can be triggered from Control Center,
the Action Button, Lock Screen, Spotlight, or Siri.

### Session Status

| Status   | Meaning                                      |
|----------|----------------------------------------------|
| Starting | Session is being initialized                 |
| Ready    | Agent is idle, waiting for a prompt           |
| Busy     | Agent is actively working                    |
| Stopping | Stop was requested, agent is winding down    |
| Stopped  | Session has ended                            |
| Error    | Something went wrong                         |

### Searching Sessions

The session list includes a search bar that supports full-text search
across all sessions in the workspace.

| Query Length | Search Method     | What It Matches                |
|--------------|-------------------|--------------------------------|
| 1-2 chars    | Local fuzzy match | Session titles only            |
| 3+ chars     | Server full-text  | Titles, messages, tool names   |

Short queries filter instantly on-device. Longer queries hit the
server's full-text index, which searches through actual conversation
content. Results include context snippets with matching terms in bold,
ranked by relevance — matches in titles and your messages rank higher
than matches in agent output.

The search bar debounces input by 200ms, so partial keystrokes do not
flood the network.

## The Timeline

The timeline is where you follow an agent's work. It shows everything
the agent does in chronological order: messages, tool calls, file
edits, command output, and any questions directed at you.

![](screenshots/timeline.png)

### Messages

Agent responses appear as rendered markdown. Code blocks have syntax
highlighting for 25+ languages. Math expressions render as formatted
equations. Mermaid diagram blocks render as actual diagrams.

Tap any code block to open it full-screen. From there you can scroll
through the full output, copy it, or share it.

### Tool Calls

When an agent reads a file, runs a command, or makes an edit, the
tool call appears in the timeline. Each shows the tool name and a
summary of what it did. Tap to expand the full input and output.

File reads show the file content with syntax highlighting. Command
output shows stdout/stderr with ANSI color support. File edits show
the before-and-after diff.

### Approvals

Some actions require your approval before the agent can proceed. A
floating pill appears at the bottom of the timeline showing a summary
of the pending action.

Swipe right on the pill to allow, or swipe left to deny. For more
control, tap the pill to open the permission sheet. The sheet shows
the full command or file path, with primary Allow and Deny buttons
(single use) and a "More options" menu for broader scopes:

| Choice              | Effect                                     |
|---------------------|---------------------------------------------|
| Allow               | Permits this single tool call              |
| Allow this session  | Permits matching calls for this session    |
| Allow always        | Creates a persistent rule for all sessions |
| Deny                | Blocks this single tool call               |
| Deny always         | Blocks all matching calls going forward    |

![](screenshots/permission-pill.png)

Push notifications alert you when an agent is waiting for approval.
Tap the notification to jump directly to the pending action.

### Agent Questions

Agents can ask you questions with predefined options. These render as
tappable cards with labeled choices. You can pick one, pick multiple,
type a custom answer, or skip the question entirely.

![](screenshots/ask-card.png)

If you skip a question, the agent uses its best judgment and moves on.

## Permissions and Policies

The permission system controls what agents can do without asking.
When an agent calls a tool, the server decides: allow silently,
block, or send the request to your phone for approval.

![](screenshots/permission-overlay.png)

### The Approval Pill

When a tool call requires approval, a floating pill appears at the
bottom of the chat timeline. The pill shows a shield icon, the
tool's action summary, a countdown timer (or infinity symbol if no
expiry), and a `+N` badge when multiple requests are queued.

Single pending request: swipe right to allow, swipe left to deny.
The pill background tints green or red as you drag. Multiple
pending requests: swipe is disabled. Tap the pill to open the
detail sheet.

![](screenshots/permission-pill.png)

### The Permission Sheet

Tap the pill to open the full details: tool name with icon
(terminal for `bash`, document for `read`, pencil for `edit`,
wrench for extension tools), the full command or file path, the
agent's stated reason, and countdown timer.

Two primary buttons: Allow and Deny. A "More options" menu below
offers broader scope choices.

When multiple requests are pending, the sheet becomes a pager.
Swipe between requests to review each one. "Deny All" appears
when three or more requests are queued.

### Approval Scopes

| Choice             | Effect                                      |
|--------------------|---------------------------------------------|
| Allow (once)       | Permits this single tool call               |
| Allow this session | Permits matching calls for the rest of this session |
| Allow always       | Creates a persistent rule across all sessions |
| Deny (once)        | Blocks this single tool call                |
| Deny always        | Blocks all matching calls going forward     |

The default buttons are single-use. Broader scopes are in "More
options." Persistent rules are saved on the server. Future matching
calls skip the prompt entirely.

### Biometric Gate

Enable "Require Face ID" (or Touch ID / Optic ID) in Settings.
Tapping Allow then triggers biometric authentication. If it fails,
the approval does not go through. Deny always works with a single
tap. Swipe-to-allow on the pill is disabled when biometric is
required; use the detail sheet button instead.

### Timeouts

Permission requests can have a server-configured timeout. The pill
and sheet show a countdown; if it runs out, the request expires and
the tool call is blocked. Requests without a timeout show an
infinity symbol and wait indefinitely.

### Server-Side Policy

The server's policy engine runs before requests reach your phone.
Out of the box, most tool calls auto-run. Built-in heuristics catch
dangerous patterns (pipe-to-shell, credential exfiltration, sudo)
and route those for approval.

| Mode    | Behavior                                          |
|---------|---------------------------------------------------|
| Default | Most calls allowed; heuristics catch risky ones   |
| Locked  | Everything requires approval unless a rule allows |

Rules accumulate from your approval choices, so locked mode becomes
less noisy over time.

## Model and Thinking Controls

Switch models and adjust thinking levels at any point during a
session. Both controls live in the session toolbar at the bottom of
the composer.

### Switching Models

Tap the model pill in the composer toolbar. The model picker sheet
opens with three sections:

- **Recent**: models you used recently, ordered by last use
- **All models**: grouped by provider, each row showing model name,
  full ID, and context window size
- **Search**: type in the search bar to fuzzy-match across model
  name, ID, and provider

The current model is highlighted with a checkmark. Selecting a
different model applies it for the next agent turn. Previous turns
in the conversation are unaffected.

![](screenshots/model-picker.png)

### Thinking Level

The thinking pill sits next to the model pill. Tap it to open a
menu with six levels:

| Level   | Behavior                               |
|---------|----------------------------------------|
| Off     | No explicit reasoning                  |
| Minimal | Brief internal check                   |
| Low     | Light reasoning                        |
| Medium  | Moderate deliberation                  |
| High    | Extended reasoning                     |
| Max     | Full reasoning budget                  |

Higher levels spend more tokens on internal reasoning before
responding. This can improve quality for complex tasks but costs
more and takes longer.

## Session Forking

Fork a session to branch the conversation at any point. The fork
creates a new session containing history up to the message you chose.
The original session stays untouched.

![](screenshots/session-fork.png)

### How to Fork

There are two ways to fork.

**From the timeline:** long-press any user or assistant message to open
the context menu. Tap "Fork from here." The fork branches from that
message.

**From the session outline:** open the outline view, find the message
you want to branch from, and long-press it. Tap "Fork from here."

Only completed messages can be forked. Messages from a turn that is
still in progress are not forkable.

The fork appears as a new session named "Fork: <original name>" in
the same workspace. Oppi navigates to it automatically. Send a
message to take the conversation in a different direction.

### What a Fork Contains

The forked session gets a copy of the conversation up to and
including the selected message. Everything after that point is
discarded. Both sessions share the same workspace and file system.

| Property      | Original session      | Forked session           |
|---------------|-----------------------|--------------------------|
| History       | Unchanged             | Truncated at fork point  |
| Workspace     | Same                  | Same                     |
| Files on disk | Shared (same project) | Shared (same project)    |
| Future turns  | Independent           | Independent              |

Edits to files in one session are visible to the other — they share
the same working directory. Git branches or worktrees can isolate
file changes when needed.

## Session Compaction

Long sessions accumulate context. Compaction summarizes the
conversation so far, replaces the original messages in the context
window, and frees space for continued work.

![](screenshots/compaction-marker.png)

### Triggering Compaction

**Manual:** long-press the context usage ring in the session toolbar.
A confirmation dialog appears. Tap Compact to proceed.

**Automatic:** enable auto-compaction for a session, and the server
triggers compaction when context usage approaches the window limit.

### Timeline Markers

Compaction shows as a colored marker in the timeline. The marker
displays phase, token count, and an expandable summary.

| Phase                     | Color  |
|---------------------------|--------|
| Compacting context...     | Blue   |
| Context compacted         | Gray   |
| Compacted — retrying      | Orange |
| Compaction cancelled      | Red    |

### Reading the Summary

Completed compaction markers show a token count badge indicating how
many tokens were in the context before compaction.

Tap the chevron on the marker to expand the summary. The summary
shows what the model retained — topic areas, key decisions, file
paths, and open questions. Expanded summaries render as markdown.

### What Compaction Does Not Do

Compaction does not delete session history. The full conversation
remains in the session trace and the timeline. Scroll up past the
compaction marker to see everything that came before.

Compaction affects the model's context window only. The model sees
the summary plus any messages after the compaction point. You still
see the complete timeline.

## Multi-Agent Sessions

An agent can spawn child sessions to delegate work. The parent
creates children, monitors their progress, and reads their results.
Each child runs independently with its own context window.

![](screenshots/multi-agent-tree.png)

### How It Works

The parent agent decides when to delegate. It calls `spawn_agent`
with a task prompt, and the server creates a new session linked to
the parent. The child starts immediately, working on its task while
the parent continues with its own.

Children cannot spawn their own children. If the parent needs a
fully independent agent that can delegate further, it spawns in
detached mode.

### Spawn Modes

| Mode     | Description                                        |
|----------|----------------------------------------------------|
| Default  | Child session linked to parent. Visible in tree.   |
| Detached | Independent session. No parent link. Full tools.   |
| Wait     | Parent blocks until child finishes, gets result.   |

Default mode is fire-and-forget: spawn and keep working. Wait mode
blocks the parent until the child reaches a terminal state, then
returns the child's response inline.

### Parent Tools

The parent has four tools for managing children:

| Tool            | Purpose                                             |
|-----------------|-----------------------------------------------------|
| `check_agents`  | Poll status of all children. Cost, messages, time.  |
| `inspect_agent` | Read a child's execution trace (progressive detail). |
| `send_message`  | Send a course correction or follow-up to a child.   |
| `stop_agent`    | Gracefully terminate a child session.               |

### Monitoring from Your Phone

Child sessions appear in the workspace session list grouped under
their parent. Tap a child to open its timeline and watch it work.

When viewing a child session, the toolbar shows the parent's name
above the session title. Tap back to return to the parent.

### Messaging Children

The parent can send messages to running children:

- **Steer**: delivered mid-turn, after current tool calls finish but
  before the next model call. Use for course corrections.
- **Follow-up**: queued until the child finishes its current turn,
  then delivered as the next prompt.

If the child has stopped, sending a message automatically resumes
it.

## File Browser

The file browser lets you navigate your project files from your phone.
Open it from the workspace detail toolbar to browse directories,
search for files, and view source code.

### Navigating

The browser shows directories and files sorted alphabetically, with
directories first. Tap a directory to enter it. Tap a file to view
its contents. The back button and swipe gesture navigate up.

File sizes appear next to each entry. Directories show a folder icon;
files show a type-specific icon based on their extension.

![](screenshots/file-browser.png)

### Searching

The search bar at the top accepts fuzzy queries. Type a few characters
and matching file paths appear instantly. The matching is path-aware:
typing `fbv` matches `Features/FileBrowser/FileBrowserView.swift`.
Matched characters highlight in the results.

Search runs entirely on-device against a cached file index. Results
appear as you type with no network round-trip per keystroke.

### Viewing Files

All files open in a unified full-screen viewer. The viewer adapts its
rendering based on file type:

| File Type       | Rendering                                       |
|-----------------|-------------------------------------------------|
| Source code     | Syntax highlighting, line numbers, scrollable   |
| Markdown        | Rendered prose with headers, lists, code blocks  |
| Org mode        | Foldable sections, rendered inline markup        |
| JSON            | Pretty-printed with colored keys and values      |
| LaTeX           | Rendered math equations                          |
| Mermaid         | Native diagrams (flowchart, sequence, etc.)      |
| Images          | Inline preview with pinch-to-zoom                |
| PDF             | Native reader with scroll and text selection      |
| Video/Audio     | Playback controls, streams from server           |
| HTML            | Rendered preview or source view                  |

![](screenshots/code-view.png)

### Inline Images in Documents

Markdown and org files can reference images stored in the workspace.
These render inline when viewing the document:

In markdown:
```markdown
![Architecture diagram](docs/screenshots/architecture.png)
```

In org mode:
```org
[[file:screenshots/architecture.png]]
```

This means you can keep documentation with embedded diagrams in your
repo and read it directly from the file browser on your phone.

## Changed Files

While a session runs (or after it finishes), you can review every
file the agent touched. Open the session outline from the timeline
toolbar, then tap the Files tab. Each file shows its git status —
added, modified, or deleted — with line counts for additions and
removals.

![](screenshots/changed-files.png)

Tap a file to see the diff. Additions highlight in green, deletions
in red. The diff view shows enough context around each change to
understand what happened.

## Rich Content Rendering

Oppi renders several content types natively, without web views or
external dependencies.

### Syntax Highlighting

Source code in the timeline and file browser gets syntax highlighting.
The following languages have dedicated highlighter support:

```text
Swift, TypeScript, JavaScript, Python, Rust, Go, Java, Kotlin,
C, C++, Shell, SQL, HTML, CSS, JSON, YAML, TOML, XML, Org,
LaTeX, Diff, Zig, Protobuf, GraphQL, Ruby, Mermaid, Graphviz
```

Other file extensions are recognized and displayed with line numbers
and monospaced formatting, but without language-specific coloring.

During streaming, syntax highlighting updates per coalescer flush
(roughly every 33ms). A typewriter effect reveals characters smoothly
while the highlighter keeps up in the background.

### Markdown

Markdown renders with full CommonMark support plus extensions:

- Headers, paragraphs, block quotes
- Ordered and unordered lists, nested to any depth
- Task lists (checkboxes)
- Tables with aligned columns
- Syntax-highlighted fenced code blocks
- Inline code, bold, italic, strikethrough
- Links (tappable, opens in browser)
- Images (loaded from workspace or URL)
- Horizontal rules

### Org Mode

Org files render with foldable sections. Tap a heading to expand or
collapse its contents. The fold state respects the file's `#+STARTUP`
directive:

| Directive            | Behavior                                 |
|----------------------|------------------------------------------|
| `#+STARTUP: nofold`  | Everything expanded                      |
| `#+STARTUP: content` | Only top-level headings visible           |
| `#+STARTUP: overview`| Top two levels of headings visible        |

Org markup converts to the same rendering pipeline as markdown, so
bold, italic, code, links, lists, and tables all look consistent.

Source blocks get syntax highlighting. Keywords like `#+TITLE:` are
parsed and respected.

### Mermaid Diagrams

Mermaid blocks in markdown render as native diagrams. No JavaScript,
no web view. The renderer draws directly to the screen using Core
Graphics.

Supported diagram types:

- Flowcharts (with subgraphs, styling, direction control)
- Sequence diagrams (messages, activations, notes, loops)
- Gantt charts (tasks, milestones, sections)
- Mindmaps (hierarchical node trees)

Unsupported diagram types (class, state, ER, pie, git graph) fall
back to displaying the source text.

Example:

````markdown
```mermaid
graph LR
    A[Phone] --> B[Server]
    B --> C[Agent]
    C --> B
    B --> A
```
````

This renders as a horizontal flow diagram with four connected nodes.

### LaTeX Math

LaTeX expressions render as formatted math. Inline math uses `$...$`
delimiters. Display math uses `$$...$$`.

The renderer handles fractions, matrices, integrals, summations, Greek
letters, subscripts, superscripts, and most standard LaTeX math
commands. Rendering is native — no MathJax, no KaTeX.

## Sharing

The full-screen viewer includes a share button in the navigation bar.
Tap it to export with the default format. Long-press for a format
picker with all available options.

The default format is PDF for most rendered content (code, markdown,
org, mermaid, LaTeX, JSON, HTML). Plain text exports as a source file.
Image data exports as an image.

| Content Type    | Available Formats          | Default  |
|-----------------|----------------------------|----------|
| Code            | PDF, Image, Source file    | PDF      |
| Markdown        | PDF, Image, Markdown file  | PDF      |
| Org mode        | PDF, Image, Org file       | PDF      |
| Mermaid diagram | PDF, Image, Mermaid source | PDF      |
| LaTeX equation  | PDF, Image, LaTeX source   | PDF      |
| JSON            | PDF, Image, JSON file      | PDF      |
| HTML            | Image, PDF, HTML source    | PDF      |
| Plain text      | Text file                  | Source   |
| Image           | Image                      | Image    |

Exported images are rendered at @3x scale regardless of device,
producing crisp output suitable for retina displays. The export uses
the app's current color theme — if you are using a dark theme, the
export will have a dark background.

![](screenshots/share-sheet.png)

## Voice Input

Tap the microphone icon in the composer to dictate your message. The
app uses iOS speech recognition, which runs on-device for common
languages.

As you speak, tentative text appears in the composer and refines as
the recognizer processes more audio. When you stop speaking, the
final transcription replaces the tentative text.

Voice input works well for quick instructions to agents. For code
snippets or exact commands, typing is still more reliable.

## Push Notifications

Oppi sends push notifications when an agent needs your attention:

- Approval requests (a tool call waiting for Allow/Deny)
- Agent questions (the ask extension)
- Session errors
- Session completion

Notifications include enough context to decide whether to act now or
later. Tapping a notification opens the relevant session at the
pending action.

Push notifications register with all paired servers, so approval
requests arrive regardless of which server you are currently viewing.

## Settings

The Settings tab controls appearance, typography, security, and
caching.

![](screenshots/settings.png)

### Appearance

| Setting            | Options                                       | Default     |
|--------------------|-----------------------------------------------|-------------|
| Theme              | Built-in themes + imported custom themes      | Default     |
| Import from Server | Fetches themes authored on the server         | -           |
| Spinner Style      | Pi (braille dots), GoL (Game of Life)         | Pi          |
| Auto-name Sessions | Server model, On-device, Off                  | Server      |
| Keep screen awake  | Off, 1 min, 2 min, 5 min, 10 min             | 2 minutes   |

**Theme** sets colors for the entire app: timeline, code blocks,
diffs, navigation chrome. Custom themes authored for pi carry over
and can be imported via the "Import from Server" link.

**Spinner Style** changes the working indicator animation. A live
preview shows the selected style inline.

**Auto-name Sessions** controls automatic title generation. "Server"
sends the first message to a model for title generation. "On-device"
uses Apple's local language model with no network required. "Off"
uses your first message as the title.

### Typography

| Setting              | Options                                                         | Default |
|----------------------|-----------------------------------------------------------------|---------|
| Code Font            | SF Mono, Fira Code, JetBrains Mono, Cascadia Code, Source Code Pro, Monaspace Neon | SF Mono |
| Monospaced messages  | On / Off                                                        | Off     |

**Code Font** applies to code blocks, tool output, diffs, and inline
code throughout the app. **Monospaced messages** uses the selected
code font for all message text.

### Quick Actions

Text selection actions appear in the context menu when you long-press
selected text in the timeline. Each action has a title, icon, prompt
prefix, and behavior: append to the current session or start a new
one. Reorder, add, or delete actions in Settings.

### Security

Toggle "Require Face ID" (or Touch ID / Optic ID) to gate permission
approvals behind biometric authentication. See the Permissions section
for details.

### Experiments

Features under active development appear behind toggles. Currently:

- **Live Activities**: shows session status on your Lock Screen and
  Dynamic Island while an agent is working.

### Cache

View the current local cache size. Tap "Clear Local Cache" to purge
cached timelines. Cached data lets previously-viewed sessions load
instantly without a server round-trip.

## Multiple Servers

Oppi can pair with more than one oppi-server. If you run servers on
two machines, pair both and manage them from the same app.

![](screenshots/multi-server-home.png)

### Adding a Server

The first server is paired during initial setup. To add another:

1. Open the Server tab.
2. Tap the `...` menu in the toolbar.
3. Tap "Add Server."
4. Scan the QR code from `oppi pair` on the new machine.

Each server is identified by a cryptographic fingerprint derived
from its Ed25519 key. The fingerprint survives hostname changes,
port changes, and credential rotation. Re-pairing to a server whose
fingerprint already exists updates the stored credentials instead
of creating a duplicate.

### Workspace Home

With multiple servers paired, the workspace list groups everything
by server. Each server section shows a badge icon and name, connection
freshness, and workspaces sorted by activity with session counts.

Tap a workspace to connect to that server and drill in. Collapse a
server section by tapping its header.

If a server is unreachable, its workspaces still appear from cache
but show an "Offline" label.

### Server Switching

There is no manual "switch server" step. The app connects to
whichever server you navigate into. Open a workspace on Server A,
the app connects to A. Go back and open a workspace on Server B,
it connects to B. Return to Server A later and the app replays
missed events to catch up.

### Managing Servers

From the server detail view, you can change the badge icon and color,
manage workspaces, or remove the server from this device (the server
itself is unaffected). Removing the last paired server returns you
to onboarding.

## Server Stats

The Server tab shows usage data for a paired server: costs, token
consumption, model distribution, and workspace activity.

![](screenshots/server-stats.png)

### Hero Row

Three totals at the top of the dashboard:

| Metric   | What It Shows                           |
|----------|-----------------------------------------|
| Sessions | Total session count                     |
| Cost     | Total API cost across all models        |
| Tokens   | Total tokens consumed (input + output)  |

Each metric includes a trend arrow when the second half of the
range differs from the first half by more than 5%. Tap a metric
to switch the daily chart to that metric.

### Daily Chart

A stacked bar chart shows daily values for the selected metric.
Bars are color-coded by model. Pick a time range: 7 days, 30 days,
or 90 days.

Tap a bar to select that day and load a detailed breakdown showing
an hourly chart and individual sessions with their costs. Tap the
same bar again to deselect.

### Model Breakdown

Below the chart, a donut chart and ranked list show cost by model.
Each row has a color dot, proportional bar, dollar cost, and
percentage.

### Workspace Breakdown

Each workspace listed with session count and cost, sorted by cost
descending.

### Server Health

At the bottom: heap memory, RSS, uptime, platform, and active
session count.

## Extensions in the Timeline

Pi extensions register custom tools that agents can call. When an
agent calls an extension tool, the call appears in the timeline
alongside built-in tools (`bash`, `read`, `edit`, `write`).

![](screenshots/extension-tool-row.png)

### Collapsed Row

Extension authors can provide styled segments for the collapsed
summary line. Each segment is a text span tagged with a style:

| Style   | Appearance     | Typical use              |
|---------|----------------|--------------------------|
| bold    | Strong text    | Tool name, action verb   |
| accent  | Cyan highlight | Primary argument value   |
| muted   | Dimmed text    | Secondary parameters     |
| dim     | Comment color  | Metadata, tags, counts   |
| success | Green          | Completion indicators    |
| warning | Yellow         | Limits, truncation notes |
| error   | Red            | Failures                 |

Without styled segments, the row falls back to the raw tool name
and plain text argument summary.

### Expanded View

Tap a tool row to expand it. The expanded view shows the tool's
full output. Extensions can control how the expanded content renders
by setting a format in the tool result:

| Format   | Rendering                                         |
|----------|---------------------------------------------------|
| markdown | Rendered prose with headers, code blocks, lists   |
| code     | Syntax-highlighted source with line numbers        |
| json     | Pretty-printed with colored keys and values        |
| diff     | Unified diff with added/removed line highlighting  |
| (none)   | Auto-detected from content structure               |

When no format is specified, the renderer inspects the output: valid
JSON is pretty-printed, text with diff headers renders as a diff,
text with markdown structure renders as markdown, and everything else
renders as plain text with ANSI color support.

### Extension UI

Extensions can prompt you with dialogs: text input, selection lists,
confirmations, and editors. These are relayed from the server and
appear as native sheets on your phone. You respond on-device and
the result goes back to the extension running on the server.

## Mac App

Oppi for Mac is a menu bar app that runs the oppi-server process
and gives you quick access to sessions, stats, logs, and diagnostics
without opening a terminal.

![](screenshots/mac-app-menubar.png)

### Menu Bar Icon

The icon reflects server state:

| Icon                  | Meaning                               |
|-----------------------|---------------------------------------|
| Outline circle        | Server stopped or idle                |
| Dotted circle         | Server starting                       |
| Filled circle         | Sessions active                       |
| Filled circle + pulse | Agent actively working                |
| Exclamation circle    | Server failed                         |

### Popover

Click the menu bar icon to open the popover with two tabs:

- **Sessions**: active sessions across workspaces with name, model,
  and cost
- **Stats**: compact stats dashboard with hero row, daily chart,
  model breakdown, and server health

Below the tabs: server status, macOS permission status, Start/Stop/
Restart buttons, "Pair New Device," "Check for Updates," and "Show
Oppi."

### First-Run Setup

On first launch, a four-step wizard runs:

1. **Prerequisites** — checks for a JS runtime and the pi CLI
2. **Permissions** — checks macOS Full Disk Access
3. **Server Init** — creates the config, starts the server, waits
   for the health check
4. **Pairing** — shows a QR code to scan from the iOS app

On subsequent launches, the app auto-starts the server.

### Main Window

Click "Show Oppi" in the popover to open the main window with a
sidebar:

| Section     | What It Shows                                  |
|-------------|------------------------------------------------|
| Status      | Server URL, version, uptime, start/stop/restart|
| Pair        | QR code and invite link for pairing devices    |
| Permissions | macOS TCC permission status with repair links  |
| Logs        | Live stdout/stderr from the server process     |
| Doctor      | Diagnostic checks (prerequisites, config)      |
| Settings    | Launch at login, server paths, update check    |

### Server Lifecycle

The Mac app manages the server as a child process. If the server
crashes, the app auto-restarts up to 3 times with backoff. When you
quit the Mac app, the server stops.

Release builds bundle Bun and the server code inside the app, so
no system dependencies are needed beyond macOS itself.

## Tips

- **Double-tap** any message or tool output in the timeline to copy its text.
- **Pinch-to-zoom** works on images, diagrams, and PDF files.
- The file browser remembers your last browsed path per workspace.
- Search in the file browser supports partial matches: `tsconf`
  finds `tsconfig.json`.
- Large tool outputs in the timeline are collapsed by default. Tap
  to expand, tap again to collapse.

## Appendix: Supported File Types

The file browser recognizes and renders these file extensions.

### Source Code (with syntax highlighting)

```text
.swift .ts .tsx .mts .cts .js .jsx .mjs .cjs .py .pyi .rs .go
.java .kt .kts .c .cpp .cc .cxx .h .hpp .hxx .rb .sh .bash .zsh
.fish .sql .graphql .gql .proto .zig .html .htm .css .scss .less
.json .jsonl .geojson .yml .yaml .toml .xml .xsl .xslt .xsd .plist
.org .tex .latex .diff .patch .mmd .mermaid .dot .gv
```

### Source Code (displayed without highlighting)

These extensions are recognized and shown with line numbers and
monospaced font, but do not have dedicated syntax coloring:

```text
.scala .php .lua .pl .pm .r .ps1 .ex .exs .erl .hs .ml .fs
.dart .nim .tf .hcl
```

### Data and Config

```text
.json .jsonl .json5 .yml .yaml .toml .ini .cfg .conf .xml .xsl .xsd
.csv .tsv .html .htm .css .scss .sass .less
```

### Documents

```text
.md .mdx .markdown .rst .adoc .txt .org .tex .latex
```

### Media

```text
Images: .png .jpg .jpeg .gif .webp .svg .ico .bmp .tiff
Video:  .mp4 .mov .m4v .avi .webm
Audio:  .mp3 .m4a .wav .aac .ogg .flac .opus
PDF:    .pdf
```

### Special Files

These files without standard extensions are recognized:

```text
Dockerfile  Containerfile  Makefile  GNUmakefile
.gitignore  .dockerignore  .prettierignore  .eslintignore
.env  .prettierrc  .eslintrc  .babelrc  .swcrc
```
