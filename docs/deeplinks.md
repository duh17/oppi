# Deep Links

Use `oppi://` links to pair a server or open a specific place in the Apple app.

The app registers only the `oppi` scheme.

## Quick examples

```text
oppi://connect?v=3&invite=<base64url-signed-invite>
oppi://workspace?path=/Users/example/workspace/oppi&name=Oppi&server=sha256:<server-fingerprint>
oppi://session/<session-id>
```

Simulator test helper:

```bash
xcrun simctl openurl booted 'oppi://workspace?path=/Users/example/workspace/oppi&name=Oppi'
```

## Routes

| Route | Required information | Result |
| --- | --- | --- |
| `oppi://connect?v=3&invite=<payload>` | Signed pairing invite | Pairs or re-pairs a server, validates trust, switches to the server, then opens Workspaces. |
| `oppi://pair?v=3&invite=<payload>` | Signed pairing invite | Same as `connect`. |
| `oppi://workspace?path=<path>&name=<name>&server=<fingerprint>` | `path`; `name` and `server` are optional | Opens Workspaces and presents Create Workspace with the path/name prefilled. The user confirms creation. |
| `oppi://session/<session-id>` | Session ID | Opens the session if it is already known locally. If not found, opens the Workspaces tab. |

Supported route forms:

- Invite and workspace links accept host-route and path-route forms: `oppi://workspace?...` and `oppi:///workspace?...`.
- Session links use the host-route form: `oppi://session/<id>`.

Use lowercase parameter names. Route names are case-insensitive.

## Pairing invites

Generate pairing links with the server CLI:

```bash
oppi pair --host <hostname-or-ip>
oppi pair --json --host <hostname-or-ip>
```

`oppi pair --json` returns the invite URL plus metadata such as the server fingerprint. The QR code and printed link use the same `oppi://connect?...` payload.

Current invites are signed v3 envelopes:

```text
oppi://connect?v=3&invite=<base64url(JSON SignedInviteEnvelopeV3)>
```

The signed payload contains the host, port, transport scheme, one-time pairing token, display name, server identity fingerprint, and optional TLS certificate fingerprint. The app verifies the signature and derived server fingerprint before accepting pinned identity data.

Rules:

- Treat pairing invites as sensitive until they expire or are used.
- Invites are single-use and short-lived; the default TTL is 90 seconds.
- Do not hand-edit invite payloads.
- Do not put owner tokens or device tokens in deep links.

## Workspace links

Workspace links navigate and prefill; they do not run remote commands.

```text
oppi://workspace?path=/Users/example/workspace/oppi&name=Oppi&server=sha256:<server-fingerprint>
```

Behavior:

1. The app selects the target server.
2. Workspaces opens.
3. Create Workspace opens with `path` and `name` prefilled when present.
4. The user fills any missing required fields and confirms creation.

Deep-linked workspaces start with no skills selected unless the user opts in before creating the workspace.

Server selection:

- If `server` is present, it must match a paired server fingerprint. Both `sha256:<hash>` and `<hash>` are accepted.
- If `server` is omitted and exactly one server is paired, Oppi uses that server.
- If multiple servers are paired, include `server` or the app shows a toast and does not open the form.

Encoding:

- Percent-encode query values with `URLComponents`, `URLSearchParams`, or an equivalent API.
- `URLComponents` decodes query values once. If the literal value must contain `%2F`, encode the percent sign as `%25` (`%252F` in the URL).
- `path` is trimmed and must not be empty. `name` and `server` are trimmed; empty values are treated as missing.

## Links inside assistant output

The chat timeline handles links before UIKit opens them:

- `oppi://` becomes an internal deep link.
- `http://` and `https://` follow the Browser link-opening setting: Oppi's in-app browser or the external browser.
- Other schemes fall back to the system default behavior.

An agent can print a link like this in a message:

```markdown
[Create workspace](oppi://workspace?path=/Users/example/workspace/oppi&name=Oppi&server=sha256:<server-fingerprint>)
```

The tap is user-initiated. Oppi strips common trailing Markdown delimiters from tapped URLs, including encoded backticks from malformed autolinks.
