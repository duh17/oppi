# Pane layouts

A pane layout is a small JSON document that arranges Oppi's panes: for example a chat beside a file, with an extension's panel above it. An agent writes one to offer the owner an arrangement for the next step. Once the app supports layouts, the owner opens one with a tap, or ignores it.

**Status:** the server reads, checks, and lists layout files, and prepares their cards. Agents can write layouts and check them with `oppi layout check`. The app does not yet show layout cards, open a layout, or offer Save Layout, so a layout changes nothing on screen for now. The version 1 format on this page is complete.

A layout only opens screens. It never runs a command, edits a file, sends a message, or connects a terminal by itself, and nothing changes on screen until the owner taps Open.

A server that reads layouts says so in `GET /server/info` with `capabilities.paneLayouts`. An app that does not draw layout cards is never sent one, and no release of the app draws them yet.

## For agents

Offer a layout when the owner will want to see several things at once for the next step, such as the chat, the diff, and the file under review. Offer each arrangement once; the owner decides.

The app does not show layout cards or open layouts yet. Write and check layouts as below, but do not tell the owner a card will appear or that one tap opens it; say what the layout arranges, and link the file.

There are two ways to offer one:

- **A one-off arrangement:** put the JSON in your reply as a fenced code block whose info string is exactly `oppi-layout`. Nothing is written to disk.
- **A layout to reuse or share:** write it to `.oppi/layouts/<name>.json` at the top of the checkout you work in, with your `write` or `edit` tool, and link the file when you mention it. The server records only a `write` or `edit` as a proposal for a card; a file written by a shell command (`cat >`, `cp`, a script) is listed but never becomes a card.

Check a layout before you offer it:

```bash
oppi layout check .oppi/layouts/review.json
oppi layout check - < draft.json        # the JSON of an oppi-layout block, on stdin
```

A complete layout:

```json
{
  "v": 1,
  "title": "Review auth fix",
  "root": {
    "split": "row",
    "weights": [0.42, 0.58],
    "children": [
      { "pane": "chat", "chat": "self" },
      {
        "split": "column",
        "children": [
          { "pane": "agents", "panel": "widget:subagents" },
          { "pane": "code", "file": "server/src/storage/device-auth.ts", "line": 208 }
        ]
      }
    ]
  },
  "focus": "chat"
}
```

Each leaf has a `pane` id and exactly one of these content fields:

| Field | Value | The pane shows |
| --- | --- | --- |
| `chat` | `"self"` or a session id | `"self"` is the chat the layout is opened from |
| `file` | A path relative to the checkout, or an absolute path; optional `line` | The file, scrolled to the line |
| `panel` | An extension surface id, like `widget:subagents`; optional `session` (`"self"` when absent) | That extension's panel |
| `git` | `"status"` or a commit sha | Git status, or one commit |
| `web` | An `http` or `https` URL | The page |
| `terminal` | `{ "rex": block }`, `{ "hc": terminal }` or `{ "ssh": saved host }` | A terminal |
| `godot` | A Godot project id from the server, like `tide-3fa9c2b1` (see [Godot](godot.md)) | The Godot pane on that project (with the Godot Pane experiment on) |

Limits: at most 8 leaves, splits at most 3 deep, a title of at most 60 characters, a pane name of at most 24, and 16 KiB for the whole document. Use relative paths: an absolute path works only on the machine it names. A `web` URL must not name loopback (`localhost`, `127.0.0.1`, `::1`), because loopback is a different machine on the phone than on the Mac.

## The document

| Field | Required | Value |
| --- | --- | --- |
| `v` | yes | The layout version, an integer. This page describes version 1. |
| `title` | yes | Up to 60 characters, one line. |
| `root` | yes | A split or a leaf. |
| `focus` | yes | The `pane` of the leaf that takes focus when the layout opens. |
| `$schema` | no | For editors; Oppi ignores it. The schema is `protocol/layout.schema.json`. |

The layout's name is its file name without `.json`, so the document has no name field.

**A split** is `{ "split": "row" | "column", "children": [...], "weights": [...] }`. `row` places children left to right, `column` top to bottom. A split has 2 to 8 children. `weights` is optional: one positive number per child, giving each child its share; children share equally when it is absent. Pane order does not mirror in right-to-left languages.

**A leaf** is `{ "pane": id, "name": text, <one content field> }`. `pane` is 1 to 24 lowercase letters, digits, and `-`, unique in the document. `name` is optional, up to 24 characters; without it the pane shows its content's title. `line` belongs only to a `file` leaf and `session` only to a `panel` leaf.

A layout holds no device state: no zoom, no collapsed panes, no sizes in points. The app fits the layout to the window it opens in, and panes that do not fit stay in the pane list.

### Text

Control characters and bidirectional formatting characters (U+061C, U+200E, U+200F, U+202A to U+202E, U+2066 to U+2069) are removed from `title` and `name`. Line breaks and tabs become spaces, and the ends are trimmed. Lengths count characters after that. A title or name is shown as plain text, never Markdown, so a layout cannot put a link or a button on its card.

### Versions and unknown fields

| Case | Result |
| --- | --- |
| `v` missing, not an integer, or below 1 | A problem: the layout does not open. |
| `v` above 1 | Listed as needing a newer Oppi, never opened. |
| An unknown field on a document, split, or leaf | Ignored; `oppi layout check` warns about it. |
| A leaf with no known content field but another field | A leaf of a newer kind. It keeps its place and shows "Needs a newer Oppi". |
| A leaf with two content fields, or with none and nothing else | A problem. |

When a document repeats a key, the last one wins, as in any JSON parser.

### Paths and pages

- A relative `file` path, and a `git` leaf, read from the checkout of the chat that opens the layout. A chat in a worktree shows that worktree's files. Opened with no chat, they read from the checkout that holds the layout file.
- A relative path must not contain a `..` part, and must not start with `~`.
- An absolute `file` path is valid. It opens under the same rules as any host file the app opens, and `oppi layout check` warns that it ties the layout to one machine.
- A `web` URL is `http` or `https`, at most 2 KiB, with no user name or password, on a host other than loopback (`localhost`, `*.localhost`, `127.0.0.0/8`, `::1`). The app also refuses a page at the address of a server it has paired with, when the pane opens.

## Where layout files live

Layout files live in `.oppi/layouts/` at the top of a workspace checkout: the workspace's own folder and each of its worktrees. There is no folder shared by all workspaces.

- A file name is 1 to 48 characters from lowercase letters, digits, `_` and `-`, starting with a letter or digit, plus `.json`. Other names are ignored.
- The first 64 files by name are read; the rest are ignored.
- `.oppi` and `.oppi/layouts` must be real folders, not links. A file whose real path leaves the folder through a link is ignored.
- A file over 16 KiB is refused without being read further. A file that is not UTF-8 is refused; a UTF-8 byte order mark is accepted.
- Two checkouts can each have a file with the same name. Both are listed, each with its checkout.
- A missing folder means no layouts. Creating a layout file through the file editor creates the folder (see [Server API](#server-api)).
- Whether `.oppi/layouts/` is committed is up to each repository. A layout that came with the repository is listed but never makes a card.
- A sandbox workspace keeps its layouts in its mount, which the server reads like any checkout.

The server looks at a folder again when it is read and its last look is more than 2 seconds old, and every 60 seconds for each folder it has read. It does not watch the folders. When a look finds a change, the server tells connected apps to read the list again.

## Cards

No release of the app shows these cards yet. This section describes the cards the server prepares, and how the app is to show them once it does.

A card shows a layout in the chat: its title, a map of the panes, one line per pane, any warnings, and Open.

A card comes from one of two places:

- **A layout file** that a session's `write` or `edit` tool left in a layouts folder. The card appears in that session's chat when the tool call ends without an error, and again whenever that chat's history loads. A child session's write makes a card in the child's chat.
- **An `oppi-layout` block** in a completed assistant reply. The app reads it from the transcript, so it appears again whenever that history loads.

Files written by a shell command, a script, a background job, another program, or a person never make a card. They are still listed by `GET /workspaces/{id}/layouts`, and a link to one in an agent's reply shows the same preview as a card.

Every card shows the file as it is now. Each write makes its own card, and a card whose file no longer holds what its write left says so. The app keeps one live card per file in a chat and folds earlier ones. Open reads the file again and opens only if it still matches what the card shows; if it changed, the card refreshes instead. A card with a problem names the first problem and has no Open.

## `oppi layout check` and `oppi layout guide`

`oppi layout check <file>` validates a layout file. `oppi layout check -` reads the layout from stdin. Neither needs a server, and neither proposes, saves, or opens anything.

```text
$ oppi layout check .oppi/layouts/review.json
review.json: valid (layout version 1) · Review auth fix
  chat         Chat      this chat
  agents       Panel     widget:subagents
  code         File      server/src/storage/device-auth.ts:208
This layout is valid and saved. The app does not open layout cards yet, so nothing changes on screen; link the file when you mention it.
```

- A problem prints the JSON path, what is wrong, and what is allowed there, such as `root: a split needs 2 to 8 children, found 1`. The command then exits 1. A layout that needs a newer Oppi also exits 1.
- Warnings do not fail the check: an unknown field, an absolute path, or a file that does not exist yet. For a file in `.oppi/layouts/`, relative paths are looked up in that file's checkout; otherwise, and for stdin, in the current folder.
- `--json` writes the result as data: `valid`, the `layout`, `problems`, `newerVersion`, and `warnings`, each issue with a `code`, `path`, and `message`.

`oppi layout guide` prints the section of this page for agents, for a session that does not have this page.

## Examples

A review, as above: the chat, an extension's panel, and the file under review.

Two files side by side under the chat, with Git status:

```json
{
  "v": 1,
  "title": "Compare the two parsers",
  "root": {
    "split": "column",
    "weights": [0.6, 0.4],
    "children": [
      {
        "split": "row",
        "children": [
          { "pane": "old", "name": "Old parser", "file": "src/parse-v1.ts" },
          { "pane": "new", "name": "New parser", "file": "src/parse-v2.ts", "line": 40 }
        ]
      },
      {
        "split": "row",
        "children": [
          { "pane": "chat", "chat": "self" },
          { "pane": "status", "git": "status" }
        ]
      }
    ]
  },
  "focus": "new"
}
```

A page of documentation beside the chat:

```json
{
  "v": 1,
  "title": "UIKit focus reference",
  "root": {
    "split": "row",
    "children": [
      { "pane": "chat", "chat": "self" },
      { "pane": "docs", "web": "https://developer.apple.com/documentation/uikit/uifocussystem" }
    ]
  },
  "focus": "chat"
}
```

## Server API

| Request or message | What it does |
| --- | --- |
| `GET /workspaces/{id}/layouts` | Every layout file of the workspace's checkouts: `name`, `worktreeId` and `checkout`, `path`, `hash`, `source`, and `title` and `leafCount`, or the first `problem`, or `newerVersion`. |
| `GET /workspaces/{id}/layouts/{name}?worktree=<id>` | One file, read now: the canonical document and its warnings, or its problems. `worktree` defaults to the workspace's own folder (`main`). |
| `workspace_layouts_changed` (app events) | A layouts folder of the workspace changed; read the list again. |
| `layout_proposal` (session stream) | A card for one tracked write, with the file as the server read it. Sent only to a socket whose `client_capabilities` named `pane-layouts:v1`. |
| `layoutProposals` (trace page) | The same cards for the tracked writes in that page of history. |

`source` is `session` (with the `sessionId` whose `write` or `edit` left the file as it is now, while the server remembers it), `repository` (tracked and unmodified in git), or `folder` (anything else). `hash` is `sha256-<hex>` of the file's bytes, the same value as the file editor's ETag. The canonical document drops unknown fields from known objects and cleans the title and names; a leaf of a newer kind keeps its fields.

The app does not offer Save Layout yet. A layout file can be created through the file editor, which writes `.oppi/layouts/<name>.json` (`PUT /files/current?origin=workspace`): `If-None-Match: *` creates the file and any missing `.oppi` and `layouts` folders, and `If-Match` replaces it. This is the only workspace file the editor creates.
