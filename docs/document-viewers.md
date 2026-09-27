# Document viewers

Oppi renders text and document output in native full-screen viewers on iPhone and iPad. Use them to read, review, copy, share, and select. They do not modify the underlying file, tool output, session transcript, or agent context.

This page covers full-screen viewers for markdown, code, source text, diffs, terminal output, HTML, and rendered document formats such as Org, LaTeX, Mermaid, Graphviz, GeoJSON, and TopoJSON. Media viewers such as images, audio, video players, and PDFs use their own controls.

## Workspace wiki links

Assistant messages can reference files in the active workspace with:

```text
[[path/to/file]]
[[path/to/file|Human-readable label]]
```

Workspace-relative targets keep the current rules: Oppi preserves an explicit extension, adds `.md` to an extensionless target, and resolves `./` or `../` relative to the source Markdown file's directory when that directory is known. Backslashes become `/`. Query strings and malformed line anchors stay literal text.

Owner wiki links can also name a real host file the Oppi server process can already read:

```text
[[/tmp/oppi-debug.log]]
[[~/workspace/kypu/README.md]]
[[/Users/chenda/workspace/kypu/src/main.go#L12-L18]]
[[file:///tmp/foo.md]]
```

Absolute POSIX paths, bare `~` / `~/...`, and local `file://` URLs become host-file links. `~otheruser`, undocumented `file:/...`, non-local `file://` URLs, and query strings stay literal. Opening a host file pushes the existing document or media viewer onto the current stack. It does not switch workspace, attach the file to the workspace browser, or start a session in another checkout.

### Line anchors

Oppi accepts GitHub-style, one-based, inclusive source line anchors on workspace file links:

```text
[[Sources/App.swift#L12]]
[[Sources/App.swift#L12-L18|focused code]]
```

The fragment must use an uppercase `L`, a positive decimal line number, and an optional `-L<end>` range whose end is not before its start. Anchors are valid only on file links. Oppi removes the fragment before checking the workspace path; an anchored target that looks like a session ID never opens a session.

When the file opens:

- Code and plain-text viewers focus and highlight the exact requested source lines; scrolling keeps the enclosure attached to those lines.
- Code ranges use one gutter marker for the continuous focus cue (a single-line anchor still has one marker).
- The rendered Markdown reader highlights every rendered block whose source line range overlaps the anchor inside one translucent continuous rounded enclosure; the blocks keep their normal spacing and remain individually readable.
- Markdown Source mode keeps the same one-based source range and focuses those exact lines.
- A labeled link uses the text after `|`; without a label, the target text is displayed.

The range can extend past the file. Oppi clips the highlight to existing lines and opens at the end when no requested line exists. It gives one short out-of-range notice and VoiceOver announcement for that open action. Empty files use the same end-of-file behavior.

Malformed or unsupported fragments remain literal Markdown text and do not become links. Examples include `#Heading`, `#L0`, `#L12-L11`, `#l12`, and `#L12-Lx`. No chooser or file lookup runs for a malformed link.

### What links can open

Git tracking does not decide whether an exact link can open. Tracked files and safe Git-ignored files can use the same syntax. Examples include:

- Markdown and text: `[[.internal/release-notes/testflight-build-45-changelog.md|Build 45 release note]]`
- Source and structured text: `[[server/src/file-serving-policy.ts|File-serving policy]]` and `[[package.json|Package metadata]]`
- Images: `[[docs/images/app-icon.png|Oppi app icon]]`
- Audio and video: recognized files such as `.mp3`, `.wav`, `.m4a`, `.mp4`, `.mov`, and `.m3u8`
- 3D scenes: `.usdz` files open a RealityView document viewer
- Other recognized documents: HTML, CSS, XML, CSV, GeoJSON, TopoJSON, and PDF files

Oppi selects a document or media viewer from the detected file type. An unknown binary file can be served within the file limits below, but it does not guarantee a native preview.

### Resolution, navigation, and limits

Oppi resolves a wiki link when the user taps it. Workspace-relative candidates check the exact parent directory instead of relying on fuzzy search. If the source session is missing, or a non-main worktree listing is a deterministic absence, Oppi retries the same workspace-relative path on the main checkout. Host-file candidates skip workspace contents and HEAD/GET the source server's authenticated host-origin current-file route (see [current-file reads](#current-file-reads)). One matching session, workspace file, or host file opens directly. Multiple matches show a chooser; no match shows an unresolved-file message. A 401/403 host-file response is an auth or server error, not an unresolved file. A link to the current session remains inert. Opening a file pushes its viewer onto the current navigation stack, and Back returns to the originating chat or file context. Host-file viewers show the canonical realpath from `X-Oppi-Resolved-Path` in the navigation title. Oppi does not present a separate path toast or confirmation sheet. Relative `./` and `../` links inside a host Markdown file resolve against that file's directory before host/workspace classification.

An expanded, completed, successful text `write` row opens the current file directly on this navigation stack. Workspace sessions fetch it through the source session origin, which preserves the server, workspace, worktree or sandbox mapping, and exact structured path. Guest and worktree-relative children followed from that reader keep the same immutable session origin. A wiki link classified as a host file opens the authenticated host-origin current-file route from a session-origin reader only when workspace runtime is confirmed host; sandbox and unknown runtime keep the session origin even for that classification. Workspace-less control sessions use the session origin on the declared source server, with relative paths resolved from the server-owned control-session working directory. Oppi does not use the recorded write content or retry another origin when the current file is unavailable. Empty writes retain an expanded “Open current file” surface with the same double-tap, pinch, context-menu, and accessibility activation. Running, failed, and interrupted writes keep the tool-output viewer. Reads, edit diffs, generic extension output, terminal output, and stored media keep their existing viewer behavior.

Fuzzy discovery uses a deterministic, bounded filesystem walk rather than Git's ignore rules. It includes safe Git-ignored files such as `.internal/**`, but excludes major VCS, dependency, build, generated, and cache directories, root `.pi` runtime state, and symlink aliases. An explicitly named existing file can still be checked by exact lookup; agents must not cite private `.pi` state, session stores, credentials, or configuration. Fuzzy `/paths` is not a secret-file ACL.

The server enforces these limits:

- Images, PDFs, and USDZ: 50 MB maximum.
- Text and other non-streaming files: 10 MB maximum.
- Audio, video, and HLS media: authenticated range streaming without the text/image size cap.
- Exact parent-directory lookup: at most 1,000 entries. Resolution can fail when a candidate's directory has more than 1,000 siblings. Fuzzy search reports truncation when it reaches its traversal bounds.

### Workspace and security boundary

Workspace directory listings (`contents`), the fuzzy `/paths` index, and the legacy workspace `raw` route keep the requested path lexically inside the workspace root. Lexical `..` traversal and absolute escapes are rejected. On a host workspace, an in-tree symlink name is followed to its real path even when the target is outside the workspace. On a sandbox workspace, the real path of a file or listed directory must stay inside the sandbox mount; a symlink that leaves the mount returns 404, and listings omit child symlinks that leave it. Byte reads are verified against the opened file. Listings read the checked directory by path, so a guest that swaps a parent directory between the check and the read could briefly expose outside entry names and metadata to the owner, never bytes. Search does not follow symlink aliases for indexing. Host-workspace session-origin reads (current or legacy session-raw) and workspace-origin current-file reads (`/files/current?origin=workspace`) are not workspace-confined: an owner-authenticated client may read an explicit real path that exists, including in-tree symlink targets and absolute/~ host paths. Pairing/auth is the gate. Sandbox workspace-origin and session-origin reads still 403 outside, guest-escape, and symlink-escape paths. See [current-file reads](#current-file-reads).

Owner host-file reads use authenticated GET/HEAD. iOS uses `/files/current?origin=host` (see [current-file reads](#current-file-reads)) when the server reports `currentFiles`. Older iOS builds, and iOS against an older server, use `/files/raw?path=`. Both accept absolute paths and expand bare `~` / `~/`. `/files/current?origin=host` returns 404 for a relative path and 400 for `controlSessionId`. Relative control-session reads use `origin=session` with that session's id. Legacy `/files/raw` still accepts a relative path when `controlSessionId` names an existing declared control session; it resolves against that session's server-owned working directory. Unknown or workspace-owned session IDs do not authorize relative `/files/raw` reads. Both routes realpath a regular file, return the canonical path as percent-encoded `X-Oppi-Resolved-Path`, and never list directories. Current control-file readers use the canonical path returned with the bytes as the base for source-relative Markdown links. Wiki-link parsing accepts local `file://` URLs and rejects undocumented `file:/...`. Neither route applies workspace-root confinement or a secret-name 403. Pairing/auth is the remote gate. Host HTML and SVG still use the existing fetch → `loadHTMLString` + CSP viewer; WKWebView must not URL-load `/files/raw` or `/files/current`.

Directory listings, fuzzy `/paths`, and workspace byte reads can show owner-visible names including `.env`, keys, credential files, and files that are not under ignored VCS/build directories. Workspace listings and legacy `raw` stay lexically inside the workspace; host workspaces may follow in-tree symlinks, sandbox workspaces stay inside the mount after realpath. Host-origin reads (`/files/current?origin=host` or legacy `/files/raw`) and host-workspace workspace-origin and session-origin reads stay owner-authenticated. Sandbox workspace-origin and session-origin reads stay confined. Agents must not ingest secrets.

### Current-file reads

Servers that report `capabilities.currentFiles` serve every current-file read through one authenticated GET/HEAD route. The `origin` parameter selects how `path` resolves; it is not a second host-file permission check.

```text
GET /files/current?origin=host&path=~/Movies/clip.mp4
GET /files/current?origin=workspace&workspaceId=<id>&worktreeId=<id>&path=docs/plan.md
GET /files/current?origin=session&sessionId=<id>&path=/workspace/<slug>/out.png
GET /files/current/sidecars?origin=host&path=~/Movies/clip.mp4
```

- `origin=host` accepts absolute, `~`/`~/`, and local `file://` paths. A relative path returns 404.
- `origin=workspace` resolves from the selected checkout or worktree. `origin=session` resolves from the session's actual working directory: its worktree, sandbox mount, or the server-owned control-session directory. For both origins on a host workspace, and for control sessions, absolute, `~`, `file://`, and `..` paths also resolve, because pairing/auth is the gate. This differs from the lexically confined legacy workspace `raw` route.
- Sandbox origins map `/workspace/<slug>/…` guest paths to the host mount. The real path must stay inside the mount; an escape returns 403. Sandbox responses never carry `X-Oppi-Resolved-Path`. Other origins return the percent-encoded canonical path in that header.
- A missing or unknown `origin`, an unknown or repeated query parameter, a missing `path`, or a parameter that does not belong to the origin returns 400. The server never retries through a less restrictive origin.
- Bytes come from a handle opened without following a final symlink. The server rechecks that the checked path still resolves to that same file, so a symlink swapped in after the check returns 404.
- Responses keep the regular-file check, size limits, MIME detection from the requested name, single byte ranges (`200`/`206`/`416`), and `Cache-Control: private, no-cache`.
- `/files/current/sidecars` takes the same origin parameters for an existing media file. It returns `{ "names": [...], "truncated": <bool> }`: only regular files beside that media name that match `stem(.lang)?.(vtt|srt|ass|ssa|lrc)`. The scan is bounded; `truncated` is `true` when it stopped at the bound. A sandbox sidecar that resolves outside the mount is left out. It never lists a directory.

iOS switches to this route only after the same server reports `currentFiles` in `/server/info`. Against an older server it keeps the legacy route for the file's origin: workspace `raw`, session-raw, or host `/files/raw`. It never sends a sandbox path to `/files/raw`. The legacy routes stay available for older iOS builds, with their existing path semantics and status codes, except that an existing file the server cannot read now returns 404 on workspace `raw` and session-raw, as it already did on `/files/raw`. WKWebView must not URL-load any current-file route.

### Editing workspace files

On iPhone and iPad, a workspace text file can be edited when the server reports `capabilities.workspaceFileEditing`. Files open in the reader; tap **Edit** to type. Markdown, code, JSON, and plain text up to the advertised `maxBytes` (1 MiB) are eligible, in the selected checkout or worktree. Host-origin and session-origin files, binaries, symlinks, and files outside the workspace stay read-only. A server without the capability is read-only.

- **Edit** is in the reader's bar, or in the toolbar when the file shows beside the iPad file tree or in file review. Files opened from a chat (file pills, **Files → All**, **Files → Changed**, and the git context bar) use that session's worktree; the editor shows which checkout it writes to. File review opens on **Changes**; its **File** tab and new files show the current bytes with **Edit**. Deleted files stay diff-only. Uploaded-file pills open the session's copy, which stays read-only.
- In Markdown, Return in a `-`, `*`, `+`, numbered, or task (`- [ ]`) item starts the next item; a task continues unchecked. Return on an empty item removes the marker and ends the list. The new line keeps the file's CRLF or LF ending, and one undo removes it.
- Typing is local. The app saves 1 second after you stop, one request at a time, and keeps an on-device draft until the server confirms the save. **Preview** renders the current draft. **Done**, Back, and leaving the app save the draft first and never wait for the network.
- Saves use `PUT /files/current?origin=workspace&workspaceId=<id>&worktreeId=<id>&path=<path>` with the raw bytes and `If-Match` set to the strong `ETag` (`"sha256-<hex>"`) from the read. `*` is refused, a missing tag returns 428, a changed file returns 412, and a missing file returns 404; the server never creates a file. Legacy `raw` routes are read-only.
- If the file changed on the server, autosave stops and your edits stay. **Review Changes** shows the disk version against your draft. **Use Disk Version** discards your edits. **Replace Disk Version** writes your draft only if the disk still matches the version you reviewed. If the file was deleted, the app keeps your draft, reopens it in a deleted state even after the app restarts, and does not recreate the file. If the on-device draft cannot be written, the editor says so instead of claiming your edits are kept.
- If a save times out after it was sent, the app re-reads the file before trying again.
- Bytes are saved exactly as typed. Line endings, BOM, Unicode form, JSON formatting, and the trailing newline are not normalized.
- The server compares the tag immediately before an atomic rename, but rename is not compare-and-swap. An agent, git, or shell writing the same file at that moment can still race the save.

### Recommended agent instruction

Copy this into a Pi or agent system prompt:

```text
When citing a relevant file the owner can open, use a real relative, absolute, or ~ wiki link such as [[path/to/file.ext|Short human-readable label]] or [[/tmp/notes.md|Debug log]]. Add a source focus only when it helps, using [[path/to/file.ext#L12-L18|Short label]]. Reuse an existing path; never fabricate one. Keep a normal human-readable sentence and brief context around every link so Oppi can render it as a navigable personal-wiki reference. Do not cite secrets, credentials, private runtime state, or dump credential files into the session. Sandbox sessions should keep using sandbox-visible paths.
```

Inline Markdown images support workspace-relative raster paths, source-relative paths when source context is known, and the existing client SVG path for SVG. See [Markdown image resolution](attachment-rendering.md#markdown-image-resolution).

Inline Markdown video uses bang-embed syntax. `![]()` and `![[]]` both embed an Oppi-backed video:

```text
![[recordings/demo.mp4]]
![demo](recordings/demo.mp4)
![[/tmp/oppi-demo.mov]]
```

`![[video-file]]` and `![label](video-file)` render a native, non-autoplaying player in assistant messages and the full-screen Markdown reader. `[[video-file]]` remains an ordinary file link. Eligible files use existing authenticated workspace, worktree, session-file, or exact owner host-file routes. Remote video sites, arbitrary URLs, HTML video, `data:`, and attachment IDs remain readable fallback text and never start a new network route. Export uses a static video card and does not modify the source. See [Markdown inline video](attachment-rendering.md#markdown-inline-video).

`![[audio-file]]` and `![label](audio-file)` render a compact non-autoplaying player strip. `[[audio-file]]` remains an ordinary file link and opens the lyrics-first full-screen audio player. Remote URLs, HTML audio, `data:`, and attachment IDs are not embeds. See [Markdown inline audio](attachment-rendering.md#markdown-inline-audio).

`![[scene.usdz]]` and `![label](scene.usdz)` reserve a 1:1 RealityView slot. Chat scroll wins until Interact; Done restores scroll. Expand, and `[[scene.usdz]]`, open a separate immediately interactive RealityView. Remote USDZ URLs fail closed and never become a remote image. Export uses a static card. See [Markdown inline USDZ](attachment-rendering.md#markdown-inline-usdz).

### Copyable `AGENTS.md` guidance for other projects

````markdown
- When pointing the user to a relevant file the owner can open, use a real relative, absolute, or `~` wiki link such as `[[path/to/file.ext|Short label]]` or `[[/tmp/notes.md|Debug log]]`. Add an uppercase GitHub-style source anchor only when useful, for example `[[path/to/file.ext#L12-L18|Short label]]`.
- When the image or SVG itself should appear inline, use `![Short description](path/to/image.png)` or `![[path/to/image.png]]`. When a real Oppi-backed video should play inline, use `![[path/to/video.mp4]]` or `![Video](path/to/video.mp4)`. Keep `[[path/to/video.mp4|Video]]` for file navigation. When a real Oppi-backed audio file should play inline, use `![[path/to/clip.m4a]]` or `![Clip](path/to/clip.m4a)`; keep `[[path/to/clip.m4a]]` as a file link that opens the full-screen player. When a real Oppi-backed USDZ scene should orbit inline, use `![[path/to/scene.usdz]]` or `![Scene](path/to/scene.usdz)`; keep `[[path/to/scene.usdz]]` as a file link that opens the document viewer.
- Fenced `mermaid` blocks render flowchart (also graph), sequence, class, state, ER, gantt, pie, timeline, mindmap, xyChart, journey, quadrantChart, gitGraph, sankey, and kanban. Other Mermaid types show an unsupported placeholder.
- Fenced `geojson` and `topojson` blocks render as an interactive map with a JSON source toggle.
- LaTeX renders inline, display, and fenced `latex` blocks.
- Reuse a real existing path; never fabricate a path or expose secrets. Sandbox sessions should keep using sandbox-visible paths.
````

## Standard Markdown file links

The native Markdown reader also treats GitHub-style file links as the same tappable resource references as wiki links:

```text
[Contributing](CONTRIBUTING.md)
[Onboarding](docs/onboarding.md)
[App](Sources/App.swift#L12)
```

Relative destinations join against the source Markdown file's directory when that directory is known. Root files such as `README.md` have no source directory, so `CONTRIBUTING.md` and `docs/onboarding.md` resolve from the workspace root. Wiki `[[path]]` targets stay workspace-root-relative unless they start with `./` or `../`.

Oppi does not add `.md` to these destinations. `#L12` and `#L12-L18` stay as source line anchors. A heading fragment on a file path opens the file and ignores the heading. A same-file `#heading` destination stays visible but is not tappable.

`http`, `https`, `mailto`, `oppi`, `oppi-session-file`, and already-rewritten `oppi-resource-reference` destinations are unchanged. `javascript:`, `data:`, query strings, and unsupported host forms fail closed with the same host-path rules as wiki links.

## Viewing Options

Full-screen document viewers show a **Viewing Options** button near the bottom-right corner of the screen. The panel adapts to the content type.

| Content | Available options |
| --- | --- |
| Markdown and thinking text | Text Size slider, Spacing, Reset View |
| Code and Graphviz source | Text Size slider, Wrap Text, Reset View |
| Plain source text | Text Size slider, Wrap Text, Reset View |
| Diffs | Text Size slider, Reset View |
| Terminal output | Text Size slider, Wrap Text, Reset View |
| HTML | Text Size slider, Reset View |
| Org and LaTeX rendered documents | Text Size slider, Spacing where text-based, Reset View |
| Mermaid diagrams | None on the rendered diagram. Source uses code Viewing Options. |
| CSV and TSV tables | Text Size slider, Reset View. Source mode keeps the original file bytes. |
| GeoJSON and TopoJSON maps | None on the rendered map. Source JSON uses code Viewing Options. |

Options affect only the current viewer family. Changing terminal wrapping does not change markdown spacing, and changing markdown text size does not change code text size.

## Text size

The **Text Size** slider scales the current viewer from 85% to 135% of its standard reader size.

The scale applies on top of Oppi's existing font choices and Dynamic Type behavior. Code-like content keeps monospaced fonts. Markdown keeps native text styling for headings, links, inline code, lists, and quotes.

## Wrapping

**Wrap Text** is available for content that often has long lines:

- code
- source text
- terminal output

When wrapping is off, the viewer keeps horizontal scrolling so indentation, terminal columns, and diff line structure stay intact. When wrapping is on, long lines fit the viewport and horizontal scrolling is hidden.

Plain source text defaults to wrapped. Code and terminal output default to unwrapped. Diffs stay unwrapped so line numbers, additions, removals, and word-level highlights keep their alignment.

## Markdown spacing

Markdown and text-based rendered documents can use three spacing modes:

- Compact
- Standard
- Relaxed

Spacing changes the distance between markdown blocks and the line spacing inside text runs. It does not change the markdown source or exported file content.

## Persistence

Viewing preferences are stored on the device by content family:

- markdown
- code
- source
- diff
- terminal
- HTML
- rendered document

Preferences are local to the Apple client. Oppi does not send them to the server, include them in prompts, or write them into workspace files.

Use **Reset View** to return the active content family to its default reader settings.

## Source and rendered modes

Some document types have a separate source/render toggle in the toolbar:

- Markdown: Reader / Source
- HTML: Preview / Source
- HTML diffs: Diff / Render when renderable content is available
- LaTeX, Org, and Mermaid: Rendered / Source
- GeoJSON and TopoJSON: Rendered / Source

Viewing Options apply to the mode currently on screen. Source mode uses code/source reader behavior. Rendered mode uses document reader behavior.

## Mermaid

Fenced `mermaid` blocks and `.mmd` / `.mermaid` files render these types:

- flowchart (`graph`)
- sequence (`sequenceDiagram`)
- class (`classDiagram`, `classDiagram-v2`)
- state (`stateDiagram`, `stateDiagram-v2`)
- ER (`erDiagram`)
- gantt
- pie
- mindmap
- timeline (`timeline-beta`)
- xyChart (`xychart`, `xychart-beta`)
- journey
- quadrantChart
- gitGraph
- sankey (`sankey-beta`)
- kanban

Unknown types show an unsupported placeholder.

In the full-screen rendered view, **Visual Markup** is a bottom-left pencil control. A separate bottom-right pick menu offers **Pick Object** for flowchart, pie, and sequence diagrams. Staged comments stack above Visual Markup when both are present. You can still pan and pinch to explore while picking; **Browse** leaves pick mode. A tap highlights the node, edge, slice, legend row, participant, or message that was hit, with **Comment** beside the selection. A pie slice and its legend row are the same object. A sequence arrow and its label are the same object. Overlapping hits open a chooser that shows the readable label and display key instead of guessing. Comment uses the existing review-comment composer and stash. The outgoing prompt includes the readable label and bounded source-line excerpts, not internal object IDs, hashes, or byte offsets. Changing the source does not silently retarget an existing comment. When the send path can still see that source, the prompt keeps the original object and marks it stale. The other Mermaid families above still render, but they do not emit selectable objects yet.

## GeoJSON and TopoJSON

`.geojson` / `.topojson` files and fenced `geojson` / `topojson` blocks open the document viewer with Rendered = MapKit map and Source = JSON. `.json` files whose root `type` is `FeatureCollection`, `GeometryCollection`, or `Topology` use the same viewer. Ordinary JSON such as `package.json` stays a JSON listing. Invalid or unsupported input keeps the source JSON and shows a short failure reason instead of an empty map.

## Native rendering and HTML

Oppi uses native UIKit rendering for interactive markdown, code, diffs, terminal output, and most document reading surfaces. Native rendering gives the app:

- fast scrolling and selection on iPhone and iPad
- system text behavior, edit menus, Dynamic Type, and accessibility hooks
- native review-comment selection support
- controlled image loading and workspace-relative markdown image resolution
- consistent toolbar behavior across sheet and embedded file-browser viewers

HTML is useful for content that is already HTML and for export-oriented rendering. The HTML viewer runs in a constrained `WKWebView` with a restrictive content security policy. It is a preview surface, not a way for arbitrary workspace HTML to gain app privileges.

### Comment on a rendered HTML element

In the full-screen HTML viewer, **Visual Markup** is a bottom-left pencil control, with staged comments stacked above it. A separate bottom-right pick menu offers **Pick Element**. The inline HTML preview has its own Pick control. Picking pauses browsing so you can comment on a rendered element. A native shield covers the page before WebKit sees the tap, so the pick does not click, focus, or otherwise activate page controls. Entering Pick resigns WebKit's native keyboard responder so keyboard input no longer edits a page field. The DOM `activeElement` may remain unchanged because Oppi does not write to the page or dispatch a page `blur` event. Scrolling and pinching are paused in pick mode. **Browse** leaves pick mode and restores normal scrolling. A selected element has a nearby **Comment** bubble in full screen; **Select Parent** is in the pick menu while an element is selected.

The outgoing comment describes the rendered element by its tag, readable label, bounded visible text, and a readable page-order position when several elements share a tag. It does not show the loaded document hash, fingerprint, DOM ID, or locator. Those remain private anchor data for revalidation; the summary is not fenced as HTML source and does not claim an original source line. The loaded source hash alone is not a promise that the live DOM is unchanged. Oppi checks the picked node's identity again when the comment is saved. A replaced node, or a text change past the stored excerpt, is rejected. Hidden content, form values, password fields, editable text, accessible names on those sensitive controls, event-handler code, and token-bearing URLs are left out. Known nonvisible text is also left out: `display`/`visibility`/`hidden`/`aria-hidden`, near-zero opacity, `font-size: 0`, and zero-size clipped overflow. This is not a claim that every visually hard-to-read string, such as low-contrast or off-screen text, is detected. If the page navigates, reloads, or the element changes before you save, Oppi does not attach the comment to a different element.

**Select Parent** walks to the containing element. Open shadow roots can be selected inside. Closed shadow roots and embedded frames are commented as the container you can see, and the comment says that limitation. HTML text-selection Comment and screenshot annotation stay available while browsing.

## Export and renderer presets

The Viewing Options panel controls the on-screen reading experience. Export and share actions live in the toolbar next to copy/share controls.

Use explicit renderer configurations for custom export themes or renderer presets. A renderer preset can define export-facing choices such as document theme, heading scale, margins, code-block style, and page width. The native reader can preview compatible parts of those choices, but the source document remains unchanged unless the user exports or saves a generated artifact.

This separation keeps reading fast and native while preserving a clear path for HTML, PDF, and image export pipelines.
