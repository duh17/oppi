# Document viewers

Oppi opens text and document output in native full-screen viewers on iPhone and iPad, for reading, reviewing, copying, sharing, and selecting. Viewers do not change the file, tool output, session transcript, or agent context.

Covered here: markdown, code, source text, diffs, terminal output, HTML, and rendered formats (Org, LaTeX, Mermaid, Graphviz, GeoJSON, TopoJSON). Images, audio, video, and PDFs use their own controls; inline embeds are in [Attachment rendering](attachment-rendering.md).

## File links in agent output

Assistant messages link to files with wiki links or standard Markdown links. A tap opens the file in the matching viewer, and Back returns to the chat.

```text
[[path/to/file]]
[[path/to/file|Human-readable label]]
[[Sources/App.swift#L12-L18|focused code]]
[[~/workspace/kypu/README.md]]
[[/tmp/oppi-debug.log]]
[Contributing](CONTRIBUTING.md)
```

**Workspace links.** Oppi keeps an explicit extension and adds `.md` to an extensionless wiki target. `./` and `../` resolve against the source Markdown file's directory when known; otherwise paths are relative to the workspace root. Backslashes become `/`. Query strings stay literal text. A link to the current session does nothing.

**Host links.** Absolute POSIX paths, `~` and `~/...`, and local `file://` URLs open a real file the Oppi server process can read. `~otheruser` and non-local `file://` URLs stay literal. A host file opens in the existing viewer on the current stack; it does not switch workspace or start a session in another checkout. The viewer title shows the file's real path. Relative links inside a host Markdown file resolve against that file's directory.

**Markdown links.** `[label](path)` works like a wiki link, except Oppi does not add `.md` and root files such as `README.md` resolve from the workspace root. A heading fragment on a file path opens the file and ignores the heading; a same-file `#heading` link is not tappable. `http`, `https`, `mailto`, and `oppi` links are unchanged. `javascript:`, `data:`, query strings, and unsupported host forms fail closed.

**Line anchors.** `#L12` and `#L12-L18` (uppercase `L`, positive one-based numbers, end not before start) focus and highlight those source lines in code, plain-text, and Markdown Source viewers. The rendered Markdown reader highlights every block whose source range overlaps the anchor. A range past the end is clipped, and the file opens at the end with one short notice. Malformed anchors (`#L0`, `#L12-L11`, `#l12`) stay literal text and are not links.

**Resolution.** Oppi resolves a link when you tap it. One match opens directly, several matches show a chooser, and none shows an unresolved-file message. A non-main worktree that lacks the file retries on the main checkout. Authentication or server errors on a host file are reported as such, not as an unresolved file.

**What opens.** Git tracking does not matter: tracked and safe Git-ignored files open the same way. The viewer follows the file type: Markdown, code, JSON, CSV, HTML, CSS, XML, GeoJSON, TopoJSON, PDF, images, audio and video (`.mp3`, `.wav`, `.m4a`, `.mp4`, `.mov`, `.m3u8`), and `.usdz` scenes. An unknown binary is served within the limits below without a guaranteed preview.

**Limits.**

- Images, PDFs, and USDZ: 50 MB.
- Text and other non-streaming files: 10 MB.
- Audio, video, and HLS: range streaming, without the size cap.
- Name lookup scans at most 1,000 entries in a directory, so resolution can fail when the target's folder has more siblings. Fuzzy search lists at most 50,000 files and says when it stopped early.

**Writes in chat.** An expanded, completed, successful text `write` row opens the file as it is now, not the content the tool wrote. Running, failed, and interrupted writes keep the tool-output viewer.

### Who can read what

Reading a file is an owner action: pairing and authentication are the gate, not a path allowlist.

- On a **host workspace**, links and file reads can open any real path the server process can read, including `.env` files, keys, and credentials. Workspace listings stay inside the workspace root, and in-tree symlinks are followed.
- A **sandbox workspace** stays inside the sandbox mount, and a path or symlink that leaves it is refused.
- Fuzzy `@` suggestions and Files search in a Git repository list tracked files and new files no ignore rule matches, like terminal Pi's `@`. Wiki links and folder browsing still open ignored files such as `.internal/**`. Other workspaces use a bounded filesystem walk that skips VCS, dependency, build, and cache directories, `.pi` runtime state, and symlinks. Search is not a secret-file ACL.
- Agents must not cite or ingest secrets, credentials, or private `.pi` state.

### Agent instructions

Copy this into an `AGENTS.md` or system prompt so an agent links and embeds files in forms Oppi renders:

````markdown
- When pointing the user to a relevant file the owner can open, use a real relative, absolute, or `~` wiki link such as `[[path/to/file.ext|Short label]]` or `[[/tmp/notes.md|Debug log]]`. Relative links resolve from the session's workspace checkout root, not the shell's cwd; link files in other repos with `~/` or absolute paths. Add an uppercase GitHub-style source anchor only when useful, for example `[[path/to/file.ext#L12-L18|Short label]]`.
- When the image or SVG itself should appear inline, use `![Short description](path/to/image.png)` or `![[path/to/image.png]]`. When a real Oppi-backed video should play inline, use `![[path/to/video.mp4]]` or `![Video](path/to/video.mp4)`. Keep `[[path/to/video.mp4|Video]]` for file navigation. When a real Oppi-backed audio file should play inline, use `![[path/to/clip.m4a]]` or `![Clip](path/to/clip.m4a)`; keep `[[path/to/clip.m4a]]` as a file link that opens the full-screen player. When a real Oppi-backed USDZ scene should orbit inline, use `![[path/to/scene.usdz]]` or `![Scene](path/to/scene.usdz)`; keep `[[path/to/scene.usdz]]` as a file link that opens the document viewer.
- Fenced `mermaid` blocks render flowchart (also graph), sequence, class, state, ER, gantt, pie, timeline, mindmap, xyChart, journey, quadrantChart, gitGraph, sankey, and kanban. Other Mermaid types show an unsupported placeholder.
- Fenced `geojson` and `topojson` blocks render as an interactive map with a JSON source toggle.
- LaTeX renders inline, display, and fenced `latex` blocks.
- Reuse a real existing path; never fabricate a path or expose secrets. Sandbox sessions should keep using sandbox-visible paths.
````

The Mobile Output Guide ([Oppi extension behavior](extensions.md#mobile-output-guide)) gives agents the same capability list automatically.

## Viewing Options

**Viewing Options**, near the bottom-right of a full-screen viewer, adapts to the content:

| Content | Options |
| --- | --- |
| Markdown and thinking text | Text Size, Spacing, Reset View |
| Code, Graphviz source, plain source text, terminal output, code-mode scripts | Text Size, Wrap Text, Reset View |
| Diffs, HTML, CSV and TSV tables | Text Size, Reset View |
| Org and LaTeX rendered documents | Text Size, Spacing (text-based), Reset View |
| Mermaid diagrams, GeoJSON and TopoJSON maps | None when rendered; Source uses the code options |

Options apply to one content family and are stored on this device only: markdown, code, source, diff, terminal, HTML, rendered document. Changing terminal wrapping does not change Markdown spacing. **Reset View** returns the active family to defaults.

### Text size

**Text Size** scales the viewer from 85% to 135% on top of **Settings → Text**. Markdown and thinking text start from the chat message size (system Dynamic Type × **Message Text Size**), with headings and inline code keeping their proportions. Code-like content starts from **Code Text Size** and ignores Dynamic Type.

### Wrapping and spacing

- **Wrap Text** applies to code, source text, and terminal output. Off keeps horizontal scrolling so indentation, columns, and diff structure stay intact. Plain source text defaults to wrapped; code and terminal output default to unwrapped. Diffs always stay unwrapped so line numbers and highlights align.
- **Spacing** (Compact, Standard, Relaxed) changes the gap between Markdown blocks and line spacing. Standard adds no extra line spacing; Relaxed adds some. It never changes the source or an export.

### Source and rendered modes

The toolbar toggles Markdown (Reader / Source), HTML (Preview / Source), HTML diffs (Diff / Render), LaTeX, Org, and Mermaid (Rendered / Source), and GeoJSON and TopoJSON (Rendered / Source). Viewing Options apply to the mode on screen.

## Diagrams and maps

**Mermaid.** Fenced `mermaid` blocks and `.mmd` / `.mermaid` files render flowchart (`graph`), sequence, class, state, ER, gantt, pie, mindmap, timeline (`timeline-beta`), xyChart, journey, quadrantChart, gitGraph, sankey (`sankey-beta`), and kanban diagrams. Unknown types show an unsupported placeholder.

**Visual Markup.** In the full-screen rendered view, the bottom-left pencil starts Visual Markup, and a bottom-right pick menu offers **Pick Object** for flowchart, pie, and sequence diagrams. You can still pan and pinch while picking, and **Browse** leaves pick mode. A tap highlights the node, edge, slice, legend row, participant, or message, with **Comment** beside it. A pie slice and its legend row are one object, as are a sequence arrow and its label. Overlapping hits open a chooser with readable labels. The comment prompt includes the readable label and short source excerpts, never internal IDs. If the source changes, the prompt keeps the original object and marks it stale. Other Mermaid types render but are not selectable.

**GeoJSON and TopoJSON.** `.geojson` and `.topojson` files, fenced `geojson` and `topojson` blocks, and `.json` files whose root `type` is `FeatureCollection`, `GeometryCollection`, or `Topology` open with Rendered (a MapKit map) and Source (JSON). Other JSON, such as `package.json`, stays a JSON listing. Invalid input keeps the source JSON and shows a short reason.

## HTML

The HTML viewer runs in a constrained `WKWebView` with a restrictive content security policy. It is a preview surface and gives workspace HTML no app privileges. Other viewers use native UIKit rendering, which gives fast scrolling and selection, system text behavior, Dynamic Type, accessibility, and review-comment selection.

**Comment on a rendered element.** In the full-screen HTML viewer, the pencil starts Visual Markup and the pick menu offers **Pick Element**. The inline preview has its own Pick control. Picking pauses browsing: a native shield catches the tap, so it never clicks or focuses page controls, and scrolling and pinching pause until **Browse**. A selected element shows a **Comment** bubble, and **Select Parent** walks to the containing element. Open shadow roots can be selected; closed shadow roots and frames are commented as the visible container, and the comment says so.

The outgoing comment gives the element's tag, readable label, bounded visible text, and page-order position when several share a tag. Oppi rechecks the node when you save: a replaced node, or text changed past the stored excerpt, is rejected, and a page that navigates or reloads first gets no comment attached elsewhere. Hidden content, form values, password fields, editable text, event-handler code, and token-bearing URLs are left out, as are `display`/`visibility`/`hidden`/`aria-hidden`, near-zero opacity, `font-size: 0`, and zero-size clipped text. Low-contrast or off-screen text is not guaranteed to be detected. HTML text-selection Comment and screenshot annotation stay available while browsing.

## Editing workspace files

A workspace text file opens in the reader, and **Edit** (in the reader's bar, or the toolbar beside the iPad file tree or file review) lets you type. Markdown, code, JSON, and plain text up to 1 MiB are editable in the selected checkout or worktree when the server supports editing. Host-origin and session-origin files, binaries, symlinks, files outside the workspace, and uploaded-file pills stay read-only. Files opened from a chat (file pills, **Files → All**, **Files → Changed**, **Git** panel) use that session's worktree, and the editor shows which checkout it writes to. File review opens on **Changes**; its **File** tab and new files show current bytes with **Edit**, and deleted files stay diff-only.

The editor has syntax color, line numbers, a current-line band, a status line (Ln/Col, indentation, language), native Find and Replace (⌘F), and Markdown styled in source. Tap **Ln, Col** to go to a line. It uses your code font and size from **Settings → Text**.

- **Typing:** Return keeps indentation and the file's CRLF or LF ending, and adds a level after an opening bracket (or a colon in Python and YAML). Tab indents with the file's own style, Backspace in leading spaces removes one level, and typing a bracket or quote adds its closer (not quotes in Markdown). In Markdown, Return in a list or task item starts the next item, and Return on an empty item ends the list. Each of these is one undo step. Long-press the space bar to move the cursor like a trackpad.
- **Key bar:** Tab, repeating arrows, Undo, Redo, and common symbols; **Settings → Editor → Customize Keys** adds, removes, and reorders keys.
- **Hardware keyboard** (hold ⌘ on iPad to list them): ⌘S save, ⌘L go to line, ⌘/ toggle comment, ⌘] and ⌘[ (or Tab and ⇧Tab) indent and outdent, ⌥⌘[ and ⌥⌘] move lines, ⌘D duplicate line, ⇧⌘K delete line, ⌘↩ and ⇧⌘↩ open a line below or above, and ⌘B and ⌘I in Markdown.
- **Vim keybindings** (**Settings → Editor → Keybindings**, or the editor's options menu) start in Normal mode with a block cursor and mode badge. Supported: counts; motions `h j k l w W b B e E ge 0 ^ $ g_ gg G { } % f F t T ; , n N * # + - _` and ⌃d ⌃u ⌃f ⌃b; operators `d c y > < gu gU g~` with motions, doubled for lines, and text objects (`iw aw iW aW i" a" i' a' i( a( i[ a[ i{ a{ i< a< ip ap`); `x X s S D C Y p P J gJ r ~ u ⌃r .`; `i a I A o O`; Visual `v V gv o`; `zz zt zb`; and `/ ? :w :q :wq :x :<line> :s :%s`. Esc, ⌃[, or ⌃C leave Insert. Yanks also go to the system clipboard on this device only. `:q` and `:wq` work like **Done**, and `:q!` explains that edits already autosave.
- **Settings → Editor** also sets syntax color, line numbers, current-line highlight, wrapping, indentation (detected by default), bracket closing, and the key bar.

**Saving.** Typing is local. The app saves one second after you stop, one request at a time, and keeps an on-device draft until the server confirms. **Preview** renders the draft. **Done**, Back, and leaving the app save the draft first and never wait for the network. A save that times out is verified by re-reading the file before retrying. Bytes save exactly as typed: line endings, BOM, Unicode form, JSON formatting, and the trailing newline are not normalized. The server never creates a file through the editor.

**Conflicts.** The save carries the version tag from your read. If the file changed on the server, autosave stops and your edits stay. **Review Changes** compares the disk version with your draft; **Use Disk Version** discards your edits; **Replace Disk Version** writes your draft only if the disk still matches the version you reviewed. If the file was deleted, the app keeps your draft, reopens it as deleted even after a restart, and does not recreate the file. If the draft cannot be saved on the device, the editor says so. The server checks the tag just before an atomic rename, so an agent, git, or shell writing at that exact moment can still race a save.

## Editing Skill files

The files of an editable Skill (one in `~/.pi/agent/skills` or another top-level Skill directory, not from a package) open in the same editor when the server supports it, with the same save and conflict rules. A Skill that is a single Markdown file edits only that file. The file's **Edit** button opens a menu: **Edit File** types in the editor, and **Edit with Oppi** starts a setup session that revises the Skill with your staged comments ([Edit with Oppi](usage.md#edit-with-oppi)). Package Skills offer only **Edit with Oppi** or stay read-only, as does every Skill on a server without Skill editing. A Skill file that is a symlink, over 1 MiB, or not UTF-8 text is read-only. The Agent definition, Schedule prompt, and Pi `SYSTEM.md` readers use the same pencil for **Edit with Oppi**.

## Export

The Viewing Options panel controls on-screen reading. Export and share live in the toolbar beside copy and share. A renderer preset can define export choices such as document theme, heading scale, margins, code-block style, and page width; the reader previews compatible parts, and the source document never changes unless you export or save a generated artifact.
