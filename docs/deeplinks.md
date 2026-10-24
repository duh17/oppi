# Deep links

Use `oppi://` links to pair a server or open a place in the Apple app. The app registers only the `oppi` scheme.

```text
oppi://connect?v=3&invite=<base64url-signed-invite>
oppi://workspace?path=/Users/example/workspace/oppi&name=Oppi&server=sha256:<server-fingerprint>
oppi://session/<session-id>
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

Invite and workspace links accept `oppi://workspace?...` and `oppi:///workspace?...`. Session links use `oppi://session/<id>`. Use lowercase parameter names; route names are case-insensitive.

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

## Links in assistant output

The chat timeline handles links before UIKit does:

- `oppi://session/<id>` pushes the target session on the current stack; Back and swipe-back return to the chat. Session URLs from outside the app, including cold launches, replace the visible route instead.
- Other `oppi://` links use the app-level handler, so pairing and workspace links keep their global behavior.
- `http://` and `https://` follow the Browser link-opening setting (Oppi's in-app browser or the external browser). Other schemes use the system default.

An agent can print a link such as `[Create workspace](oppi://workspace?path=/Users/example/workspace/oppi&name=Oppi)`. The tap is user-initiated. Oppi strips common trailing Markdown delimiters from tapped URLs, including encoded backticks from malformed autolinks.
