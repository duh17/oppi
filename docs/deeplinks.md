# Deep links

Use `oppi://` links to pair a server or open a place in the Apple app. The app registers only the `oppi` scheme.

```text
oppi://connect?v=3&invite=<base64url-signed-invite>
oppi://workspace?path=/Users/example/workspace/oppi&name=Oppi&server=sha256:<server-fingerprint>
oppi://session/<session-id>
oppi://thread/<session-id>
oppi://sessions?workspace=<workspace-id>
oppi://file?workspace=<workspace-id>&path=src/app.ts#L12
oppi://files?workspace=<workspace-id>&path=src
oppi://terminal/rex?session=<rex-session-id>&block=<rex-block-id>
```

Test in the Simulator:

```bash
xcrun simctl openurl booted 'oppi://workspace?path=/Users/example/workspace/oppi&name=Oppi'
```

## Routes

| Route | Required | Result |
| --- | --- | --- |
| `oppi://connect?v=3&invite=<payload>` (or `pair`) | Signed pairing invite | Pairs or re-pairs a server, validates trust, switches to it, and opens Workspaces |
| `oppi://workspace?path=<path>&name=<name>&server=<fingerprint>` | `path`; `name` and `server` optional | Opens Create Workspace with the path and name prefilled; you confirm |
| `oppi://session/<session-id>` | Session ID | Opens the session if known locally or found by server lookup; otherwise opens Workspaces |
| `oppi://thread/<session-id>` | ID of any session in the thread | Opens All Sessions (the matching list on iPad) with the session's thread open in place and scrolled to its root; if the session is a descendant, its root's thread opens. A session the server says it does not have opens the list with a "Session not found for this thread link" notice; a server that cannot be reached keeps the link for the next foreground, as a session link does |
| `oppi://sessions[?workspace=<id>]` | Nothing; `workspace` optional | Opens All Sessions, or one workspace's sessions |
| `oppi://file?workspace=<id>&path=<path>[&worktree=<id>][#L<line>]` | `workspace` and `path` | Opens a workspace file (in a worktree, at a line). `oppi://file?host=1&path=<absolute path>` opens a file on the server's host, and `oppi://file?session=<id>&path=<path>` a session's own copy |
| `oppi://files?workspace=<id>[&path=<folder>]` | `workspace` | Opens the File Browser at the workspace root or a folder |
| `oppi://panel?session=<id>&id=<surface id>` | `session` and `id` | Opens the session's chat with that extension surface in a [panel pane](extension-native-ui.md#panel-panes) beside it (full screen on a narrow window) |
| `oppi://terminal/rex?session=<id>&block=<id>` | Rex `session_id` and `block_id` (`session:…`, `block:…`, as `rex split --json` prints them; the colons may be percent-encoded) | Opens that Rex pane in the SSH terminal, on the saved SSH host for the server the link came from (the chat it was tapped in, else the active server) |

Invite and workspace links accept `oppi://workspace?...` and `oppi:///workspace?...`. Session links use `oppi://session/<id>` and thread links `oppi://thread/<id>`, with the same ID validation and server lookup (a `?workspaceId=` query is ignored). Use lowercase parameter names; route names are case-insensitive.

## Pane links

Session, thread, `sessions`, `file`, `files`, and `panel` links are pane links: each names one place a pane can show, and all of them accept an optional `server=<fingerprint>` (`sha256:<hash>` or `<hash>`). With `server`, the link opens on that server. Without it, a link tapped in a chat opens on that chat's server, and one from outside Oppi uses the server that has the session (session and thread links) or the active server.

- A session or thread link takes exactly one ID after its route; any other path, or `server` given twice, makes it invalid. It ignores every other parameter.
- On `sessions`, `file`, `files`, and `panel` links, an unknown or repeated parameter, a fragment other than a file's `#L<line>`, user-info, or a port makes the link invalid. A `file` link names exactly one of `workspace`, `host=1`, or `session`, and only a workspace file takes `worktree`.
- Oppi says when a link is invalid and opens nothing.
- A session, `sessions`, `file`, `files`, or `panel` link whose `server` this device has not paired opens a pane that says the server was removed, with **Choose…** (All Sessions) and **Close Pane**.
- On a `sessions`, `file`, or `files` link, a workspace that no longer exists opens the same way, and a server that cannot be reached shows **Retry** until the place opens. A session link to a session no server has, or to a server that cannot be reached, behaves as described under Routes. A `panel` link whose session is not on this device yet opens a pane that waits for it, then offers **Open Chat**. A pane link to locked content opens a pane that asks you to unlock only when you tap it.

The app saves its panes in the same form, so a relaunch shows the screens you left (on a wide window, with the chat's Files, Git, or extension panel beside it), each resolving on its own: a session, file, or server that is gone, or a server that cannot be reached, shows that state in its pane.

If a link needs a server that is not reachable yet, Oppi says so once, keeps the request, and opens it when Oppi returns to the foreground and the server connects. A newer link replaces the kept one, and a kept link is dropped after 10 minutes or when its server is removed.

On Mac, an external session link waits for the local workspace catalog. If the session is not in the recent snapshot, Oppi asks the server once through the owner Unix socket and never falls back to HTTPS. A routable match opens directly; not found or a lookup failure opens Workspaces.

## Pairing invites

```bash
oppi pair --host <hostname-or-ip>
oppi pair --json --host <hostname-or-ip>
oppi pair --json   # uses publicUrl when configured
```

`--json` returns the invite URL plus metadata such as the server fingerprint. The QR code and printed link use the same `oppi://connect?...` payload: a signed v3 envelope with the host, port, transport scheme, one-time pairing token, display name, server identity fingerprint, and optional TLS certificate fingerprint. The app verifies the signature and derived fingerprint before accepting pinned identity data.

- Treat an invite as sensitive until it expires or is used. A leaked invite stays valid until then.
- Invites are single-use and last 90 seconds by default. `oppi pair --ttl <duration>` sets 1 second to 30 days; use a long one only for asynchronous hand-offs such as App Review notes.
- Running `oppi pair` again replaces the pending invite, and `oppi token rotate` also revokes the owner token and every paired device. There is no dedicated revoke command.
- Do not hand-edit invites, and do not put owner or device tokens in deep links.

## Workspace links

Workspace links navigate and prefill; they never run remote commands. The app selects the server, opens Create Workspace with `path` and `name` filled in, and you complete and confirm. Deep-linked workspaces start with no skills selected unless you opt in first.

- **Server:** `server` must match a paired server fingerprint (`sha256:<hash>` or `<hash>`). If omitted and exactly one server is paired, Oppi uses it. With several paired and no `server`, the app shows a toast and does not open the form.
- **Encoding:** percent-encode query values with `URLComponents`, `URLSearchParams`, or similar. These decode query values once, so a literal `%2F` is written `%252F`. `path` is trimmed and must not be empty; empty `name` and `server` count as missing.

## Terminal links

A terminal link has no `server` parameter: a link tapped in a chat uses that chat’s server, and one opened from outside a chat uses the active server. It only opens a pane; it never types or runs anything, and any parameter beyond `session` and `block` (or one repeated, or a fragment, user-info, or port) makes it invalid. It needs the Rex experiment on and a saved host whose Multiplexer is Rex. With no saved host for the server, Oppi opens Add Host with the server's host filled in and Multiplexer set to Rex; after you save it, tap the link again. If Rex is not running or the pane is gone, Oppi says so and leaves you on the host's pane list. Sign-in is the terminal's own, including Face ID for the key.

## Links in assistant output

The chat timeline handles links before UIKit does:

- `oppi://session/<id>` pushes the target session on the current stack; Back and swipe-back return to the chat. Session URLs from outside the app, including cold launches, replace the visible route instead.
- Other `oppi://` links use the app-level handler, so pairing, workspace, and terminal links keep their global behavior. This holds in an ask card's Markdown too.
- `http://` and `https://` follow the Browser link-opening setting (Oppi's in-app browser or the external browser). Other schemes use the system default.

An agent can print a link such as `[Create workspace](oppi://workspace?path=/Users/example/workspace/oppi&name=Oppi)`. The tap is user-initiated. Oppi strips common trailing Markdown delimiters from tapped URLs, including encoded backticks from malformed autolinks.
