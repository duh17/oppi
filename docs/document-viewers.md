# Document viewers

Oppi opens text and document output in native full-screen viewers on iPhone and iPad, for reading, reviewing, copying, sharing, and selecting. Viewers do not change the file, tool output, session transcript, or agent context.

Covered here: markdown, code, source text, diffs, terminal output, HTML, rendered formats (Org, LaTeX math, Mermaid, GeoJSON, TopoJSON), EPUB books, and Graphviz, which opens as highlighted source. Images, audio, video, and PDFs use their own controls; inline embeds are in [Attachment rendering](attachment-rendering.md).

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

**Workspace links.** Oppi keeps an explicit extension and adds `.md` to an extensionless wiki target. `./` and `../` resolve against the source Markdown file's directory when known; otherwise paths are relative to the workspace root. Backslashes become `/`. Query strings stay literal text. A link to the current session does nothing. The target and label are read as written, as in Obsidian: `*` and `_` inside `[[…]]` are not emphasis, a `[name]: url` definition does not take over `[[name]]`, and the first `]]` ends the link.

**Host links.** Absolute POSIX paths, `~` and `~/...`, and local `file://` URLs open a real file the Oppi server process can read. `~otheruser` and non-local `file://` URLs stay literal. A host file opens in the existing viewer on the current stack; it does not switch workspace or start a session in another checkout. The viewer title shows the file's real path. Relative links inside a host Markdown file resolve against that file's directory.

**Markdown links.** `[label](path)` works like a wiki link, except Oppi does not add `.md` and root files such as `README.md` resolve from the workspace root. A heading fragment on a file path, such as `notes.md#setup`, opens the Markdown or Org file at that heading. In a file reader, a same-file `[label](#setup)` link scrolls to the heading; elsewhere, such as in chat, it is not tappable. The fragment is the heading's GitHub-style slug: lowercase, punctuation dropped, spaces as hyphens, and `-1`, `-2` on repeated headings. When the heading does not exist, a link to another file opens it at the top, and a same-file link shows a short notice. `http`, `https`, `mailto`, and `oppi` links are unchanged. `javascript:`, `data:`, query strings, and unsupported host forms fail closed.

**Line anchors.** `#L12` and `#L12-L18` (uppercase `L`, positive one-based numbers, end not before start) focus and highlight those source lines in code, plain-text, and Markdown Source viewers. The rendered Markdown reader highlights every block whose source range overlaps the anchor. A range past the end is clipped, and the file opens at the end with one short notice. Malformed anchors (`#L0`, `#L12-L11`, `#l12`) stay literal text and are not links.

**Resolution.** Oppi resolves a link when you tap it. One match opens directly, several matches show a chooser, and none shows an unresolved-file message. A non-main worktree that lacks the file retries on the main checkout. Authentication or server errors on a host file are reported as such, not as an unresolved file.

**What opens.** Git tracking does not matter: tracked and safe Git-ignored files open the same way. The viewer follows the file type: Markdown, code, JSON, CSV, HTML, CSS, XML, GeoJSON, TopoJSON, PDF, images, audio and video (`.mp3`, `.wav`, `.m4a`, `.mp4`, `.mov`, `.m3u8`), and `.usdz` scenes. Any other file, such as a `.zip`, `.dmg`, or `.docx`, opens as a file card: its type, size, and when it last changed, with **Share** and **Save to Files**, and **Quick Look** when iOS can preview the type (Office and iWork documents, for example). Text too large to show opens as the same card.

**Limits.**

- Images, PDFs, and USDZ: 50 MB.
- Text and other files the viewer reads whole: 100 MB.
- Markdown, Org, LaTeX, Mermaid, HTML, CSV, and map files over 1 MB, and code over 5 MB, open as plain text, which stays fast at any size. A note at the bottom says so; **Format Anyway** (or **Highlight Anyway** for code), there or in the bar, formats the file, which can take a while and a lot of memory.
- Audio, video, and HLS: range streaming, without the size cap.
- **Share**, **Save to Files**, and **Quick Look** download the file to the device, with progress and **Cancel**, and are not held to these limits. A download has no size cap of its own; it needs free space for twice its size, room for the file and the copy another app makes. The card keeps its copy until you leave the file.
- Downloads use the same paired connection and certificate check as the rest of the app; nothing gets a public link. A download that drops, or that iOS pauses after you leave the app, continues from where it stopped once the connection or the app is back (if iOS closed Oppi meanwhile, start it again), unless the file changed on the server, in which case it starts over. While it waits, the progress says **Reconnecting**; when the server's address changes meanwhile (leaving Wi-Fi for Tailscale, say), it continues at the new one. After about a minute with no bytes moving it stops and says why: offline, server unreachable, file not found, outside the folders the server shares, or too large. Before the file is offered, the app checks it against the SHA-256 the server sends and discards it if they differ. Text files travel compressed; archives and media do not.
- Folders list in pages of 1,000 entries, which the app fetches one after another until it has the whole folder, so a folder of 10,000 files shows its first page at once and the rest within moments. Fuzzy search lists at most 50,000 files and says when it stopped early.

**Writes in chat.** An expanded, completed, successful text `write` row opens the file as it is now, not the content the tool wrote. Running, failed, and interrupted writes keep the tool-output viewer.

### Who can read what

Reading a file is an owner action: pairing and authentication are the gate, not a path allowlist.

- On a **host workspace**, links and file reads can open any real path the server process can read, including `.env` files, keys, and credentials. Workspace listings stay inside the workspace root, and in-tree symlinks are followed.
- A **sandbox workspace** stays inside the sandbox mount, and a path or symlink that leaves it is refused.
- Fuzzy `@` suggestions and Files search in a Git repository list tracked files and new files no ignore rule matches, like terminal Pi's `@`. Wiki links and folder browsing still open ignored files such as `.internal/**`. Other workspaces use a bounded filesystem walk that skips VCS, dependency, build, and cache directories, `.pi` runtime state, and symlinks. Search is not a secret-file ACL.
- Agents must not cite or ingest secrets, credentials, or private `.pi` state.

### Agent instructions

When it is on, the Mobile Output Guide ([Oppi extension behavior](extensions.md#mobile-output-guide)) sends this text to managed sessions. For other agents, copy it into an `AGENTS.md` or system prompt:

````text
You are running in Oppi: your Markdown renders in a native iPhone/iPad app.

- Link files or folders the user may want to open, such as files you created, changed, or cite: [[path|label]] or [[path#L12-L18|label]]. Backticked paths, `file.ts:12`, and [[file#Heading]] stay plain text. Extensionless wiki targets gain .md, so link those with [label](path).
- Embed images, audio, video, or USDZ you made or found: ![[path]] or ![alt](path). [[path]] only links. Only local files embed; remote https images load on tap.
- Relative paths resolve from this session's workspace checkout root (its worktree, if any), not the shell's cwd. Paths a subagent, tool, or other session reports are relative to its own checkout or worktree. Use ~/ or absolute paths for those and other files on this machine, including other repos; in a sandbox, use sandbox-visible paths. Check that a file exists (e.g. `test -f`) before you link or embed it.
- Session link: [label](oppi://session/<full-session-id>); never write history://, agent:// or proc:// links for the user.
- ```mermaid renders only flowchart/graph, sequence, class, state, ER, gantt, pie, timeline, mindmap, xychart, journey, quadrantChart, gitGraph, sankey, and kanban.
- ```geojson or ```topojson renders an interactive map.
- Inline and display math render, including align, gather, cases, matrices, \color, \overset, \substack, and \tag. \newcommand, array, multline, \cancel, \not, and \textbf show as source.
- Inline HTML renders only <b> <strong> <i> <em> <code> <s> <del> <strike> <u> <ins> <sub> <sup> <kbd> <mark> <a href>, <br> (also in table cells), an <hr> line, and hidden <!-- comments -->. Other HTML, footnotes, and callouts show as text.
- Linked CSV, HTML, Org, .mmd, GeoJSON, and PDF files open in rendered viewers.
- Never link, embed, or quote secrets, credentials, or private runtime state.
````

## Viewing Options

**Viewing Options**, in a full-screen viewer's bar ([The reader's bar](#the-readers-bar)), adapts to the content. A Git diff opened from a review or a commit has it in the diff's bar too.

| Content | Options |
| --- | --- |
| Markdown and thinking text | Text Size, Spacing, Reset View |
| Code, Graphviz source, plain source text, terminal output, code-mode scripts | Text Size, Wrap Text, Reset View |
| Diffs, HTML, full-screen tables (Markdown, CSV, and TSV) | Text Size, Reset View |
| Org and LaTeX rendered documents | Text Size, Spacing (text-based), Reset View |
| Mermaid diagrams, GeoJSON and TopoJSON maps | None when rendered; Source uses the code options |

Options apply to one content family and are stored on this device only: markdown, code, source, diff, terminal, HTML, rendered document, table. Changing terminal wrapping does not change Markdown spacing. **Reset View** returns the active family to defaults.

### Text size

**Text Size** scales the viewer from 85% to 135% on top of **Settings → Text**. Markdown and thinking text start from the chat message size (system Dynamic Type × **Message Text Size**), with headings and inline code keeping their proportions. Code-like content starts from **Code Text Size** and ignores Dynamic Type.

### Wrapping and spacing

- **Wrap Text** applies to code, source text, and terminal output. Off keeps horizontal scrolling so indentation, columns, and diff structure stay intact. Plain source text defaults to wrapped; code and terminal output default to unwrapped. Diffs always stay unwrapped so line numbers and highlights align.
- **Spacing** (Compact, Standard, Relaxed) changes the gap between Markdown blocks and line spacing. Standard adds no extra line spacing; Relaxed adds some. It never changes the source or an export.
- **Reading width.** On a wide window, such as an iPad in landscape, rendered Markdown and Org files read in a centered column about 75 characters wide, which grows with Text Size. Tables and code blocks widen past it, up to the full window, before they wrap or scroll sideways ([Tables](#tables)). A narrower window uses its full width.

### Source and rendered modes

The toolbar toggles Markdown (Reader / Source), HTML (Preview / Source), HTML diffs (Diff / Render), LaTeX, Org, and Mermaid (Rendered / Source), and GeoJSON and TopoJSON (Rendered / Source). Viewing Options apply to the mode on screen.

## Tables

A Markdown table's cells use the message text, so they follow Dynamic Type and **Message Text Size**; only inline code in a cell uses the code font. A table in chat or in the reader keeps short values, such as dates, times, and counts, on one line. A long header over short values wraps instead. A table with long text, such as a column of descriptions, grows as wide as the text around it, the reader's column included, before it wraps that text; a table that needs less width keeps its own. A table wider than the screen wraps its longer columns to fit when every column stays readable and no word breaks in the middle. Otherwise it scrolls sideways, with a fade at its edge, and a **Show all N columns** bar under its rows.

- **Alignment.** A column follows the colons in the table's delimiter row: `:---` left, `:---:` centered, `---:` right. A column without colons that holds only numbers is right-aligned, header included. A number can have a sign, a currency, a short unit, or a word such as "about" ("0.35 ms", "$7.76", "12%", "about 2 s"); a dash or "n/a" counts as an empty cell. Digits in a table all have the same width, so numbers line up.
- **Long tables.** In chat, a table longer than 20 rows shows its first 20 and a **Show all N rows** bar. When columns are cut as well, the bar reads **Show all N rows · M columns**. The reader and exports show every row.
- **Full screen.** The bar under a table opens it full screen. Touch and hold any table in chat and choose **View Full Screen** to open one that fits. Where a touch and hold selects text, **View Full Screen** is in the menu for the selection. VoiceOver offers it as an action on every cell. Full screen shows the same table with every row, fit to the screen and centered on a wide one. Its text size follows **Viewing Options**, and a caption gives its size in columns and rows. Its header row stays under the bar while the rows scroll. Touch and hold a cell to select its text. **Copy** in the toolbar offers **Copy as Markdown** and **Copy as TSV**; **Share** shares a TSV file.
- **Copy.** Touch and hold a table, or its bar, for **Copy as Markdown** and **Copy as TSV**, which always take every row. Text selected across cells copies as tab-separated cells, ready to paste into a spreadsheet.
- **Formatting.** Bold, italic, strikethrough, `code`, links, math, and the [inline HTML](#html-in-markdown) tags show in cells. A `<br>` starts a new line in its cell; a table with one always wraps its cells.

## Math

Markdown in chat and in the reader draws TeX math in paragraphs, headings, table cells, quotes, and lists.

- **Inline.** `$…$`, `\(…\)`, and `$$…$$` inside a line. A `$` opens math only when a non-space follows it. It closes math only when a non-space comes before it and no letter or digit comes after it, so `$5 and $10`, `$PATH:$HOME`, and `$n$th` stay text. `\$` is always a dollar sign.
- **Blocks.** A line that is only `$$` or `\[` starts a block, and the next line that ends in `$$` or `\]` closes it. `$$…$$` or `\[…\]` alone on a line is a one-line block. Until the closing line arrives, the block shows its TeX as text. A block with no closing line runs to the end of its quote, list item, or message, as a code fence does.
- **Code.** Code spans and code blocks never contain math.
- **Environments.** `aligned`, `align`, `split`, `gather`, `cases`, `equation`, and the matrices. Rows are not numbered; `\tag{…}` labels a row and `\tag*{…}` labels it without parentheses.
- **Colour.** `\color` and `\textcolor` take a name such as `red`, `blue`, or `teal`, or a hex value such as `#ff8800`. Oppi draws the theme's nearest accent colour, so coloured math stays readable in light and dark themes. Black, white, gray, and names Oppi does not know draw in the text colour or its dimmed shade.
- **Fallback.** TeX that Oppi cannot draw shows as written.

Quotes and dashes show as typed: `--`, `...`, and straight quotes are not changed to typographic characters.

## HTML in Markdown

Markdown in chat, in the reader, and in tool output draws a small set of the HTML tags GitHub allows, with the app's own text styles. Nothing in it runs or loads.

| HTML | Shows as |
| --- | --- |
| `<b>`, `<strong>` | Bold |
| `<i>`, `<em>` | Italic |
| `<code>` | Inline code |
| `<s>`, `<del>`, `<strike>` | Strikethrough |
| `<u>`, `<ins>` | Underline |
| `<sub>`, `<sup>` | Subscript and superscript |
| `<kbd>` | A key on a key-colored fill |
| `<mark>` | Highlighted text |
| `<a href="…">` | A link, opened like a Markdown link. An `<a>` without `href` shows its text. |
| `<br>`, `<br/>` | A line break, also in a table cell. A line of only `<br>` tags between blocks adds nothing. |
| `<hr>` on its own line | A horizontal rule |
| `<!-- … -->` | Nothing: comments are hidden |

- **Pairs.** A tag works only with its closing tag in the same paragraph, heading, or table cell, and inside the same Markdown emphasis or link. Tags can nest (`<b><i>x</i></b>`) and mix with Markdown (`**a <sub>2</sub>**`). Tag names ignore case.
- **HTML lines.** A line that is one tag alone, such as `<br>` or `<kbd>`, starts an HTML block that runs to the next blank line. When every tag in it is from the table, the block shows as a paragraph of its text, read as HTML: Markdown inside it stays as written, and line breaks inside it are spaces.
- **Attributes.** Attributes such as `style`, `class`, and `onclick` are ignored. `href` on `<a>` is the only one used.
- **Shown as text.** Any other tag (`<details>`, `<img>`, `<span>`, `<script>`, `<iframe>`, forms), a tag without its closing tag, a closing tag without its opening tag, a self-closing `<b/>`, and a comment with no `-->` show as written, so no text is hidden. `&lt;b&gt;` and HTML in code spans also stay text.
- **While streaming.** A tag whose closing tag has not arrived shows as text until it arrives.
- **Differences from GitHub.** GitHub removes `<u>` and other unknown tags and closes a tag that is left open; Oppi underlines `<u>` and shows the others as text. Markdown inside `<code>` keeps its text but not its emphasis. An HTML block that mixes `<hr>` with text, or holds any tag outside the table, shows as written.
- **Org files.** Org has no inline HTML. `@@html:…@@` snippets and `#+HTML:` lines show as text, and a `#+begin_export html` block shows as an `html` code block.

## The reader's bar

The reader's bar holds **Edit**, **Find**, **Outline**, **Copy**, **Share**, the source toggle, **Viewing Options**, and **Previous File** and **Next File** for a file opened from a list (the File Browser, a chat's files, or the changed files of a Git review), each where the file offers it. A file shown inside another screen (a Git review's **File** tab, a file with no text diff, a file beside the File Browser) puts these buttons in that screen's bar. On a side toolbar (iPhone Duo), **Annotate** and **Staged Comments** join the bar; elsewhere they float over the page. Every button the reader offers is on the bar until you change it. When the bar is too narrow for all of them, the buttons at the end of your order move into the **…** menu.

**Share** opens the share sheet with the file in its default format, a PDF for Markdown and Org. To choose PDF, Image, or the source file, touch and hold **Share**, or use **Share As** in the **…** menu. The source toggle stays highlighted while the source shows; in the **…** menu it has a checkmark.

**Settings → Editor → Reader Bar**, also **Customize Bar…** in the reader's **…** menu, chooses which buttons the bar shows and their order. A button turned off moves into the **…** menu, which also holds **Edit with Session** where a document offers it. **Reset to Default** shows every button again. While you edit a file, the editor's own controls take the bar. The layout is kept on this device.

## Outline and Find

The reader of a Markdown or Org file has **Find** in its toolbar, and **Outline** when the file has headings.

- **Outline** lists the file's headings, indented by level, with each Org heading's TODO state. Choose one to scroll to it. Any folded heading above it opens. Outline opens as a popover on iPad and as a sheet on iPhone or in a narrow window.
- **Find** opens the system find bar. On iPad, ⌘F opens it too. It searches the whole file, folded sections included, in text and code blocks. Tables, images, diagrams, maps, and math blocks are not searched. Matching ignores case and accents unless you change that in the find bar's options. The bar shows which match is current and how many there are, and next and previous wrap at the ends. The current match is highlighted and scrolled into view, and the folded sections that hold it open. A query with no match leaves the page where it was.

## Org files

The reader shows an Org file as a formatted document; **Source** shows it as written.

- **Headings.** Each heading starts with a bullet, as in Emacs with org-superstar. The bullet's shape and the heading's color follow its level: level 1 uses the theme's heading color, level 2 its purple, and level 3 a mix of the two. Deeper levels repeat those colors closer to the text color, and the shapes repeat after level 4. A heading's TODO state, priority, and progress cookie (`[2/5]`, `[40%]`) follow the bullet as one badge bar, colored by state (open, waiting, done, dropped). Tags follow the title as capsules, and `#+FILETAGS` shows the same capsules. Property drawers stay hidden.
- **Dates.** Scheduled, Deadline, and Closed lines show as dated badges under their heading. An open deadline with a warning period, such as `<2026-11-20 Fri -2d>`, turns to the warning color when that period starts, and VoiceOver reads it as due soon. A deadline without a warning period does not warn early. An open deadline that has passed turns red with a warning symbol.
- **Folding.** Tap the bullet of a heading with content under it, or anywhere on the heading, to hide everything under it, up to the next heading of the same or a higher level. Tap it again to show the content. The heading stays where it is on the screen; only what is under it hides or shows. A folded heading's bullet is solid on a faint disc, and the heading ends in **…**. A tap on a link in the heading opens the link, and a long press still opens the text menu. Folding never changes the file, so it works in files you cannot edit. Folds stay while the file is open, also after a task change saves. When you open the file again, all headings are unfolded. VoiceOver reads **Expanded** or **Collapsed** and offers **Collapse** or **Expand**.
- **Comments.** A `COMMENT` heading and everything under it are hidden, as are `#` comment lines and `#+begin_comment` blocks. Source still shows them.
- **Links.** `[[file:…]]` links and `./`, `../`, and `~/` paths open relative to the document. `[[*Heading]]`, `[[#custom-id]]`, and `[[id:…]]` scroll to that heading of the same file, opening any folded heading above it. The heading, custom ID, or ID must be in this file. `[[file:notes.org::*Heading]]` and `[[file:notes.org::#custom-id]]` open the other file at that heading. Another search option, such as a line number, opens the file at the top. A link that nothing can open shows as its label. In a share image, a PDF, or an Org file shown in chat, a link to a heading of the same file links to the file itself. Image and PDF exports keep relative file links.

## Tasks in Markdown and Org

When the file reader can save a Markdown or Org file (it shows the pencil), the file's tasks work in place:

- **Checkboxes.** Tap one to check or uncheck it. A progress cookie such as `[1/3]` or `[33%]` on the item above it, or else on the heading above, is recounted.
- **States (Org).** Tap a heading's state to choose another of the file's `#+TODO` states (TODO, NEXT, WAITING, HOLD, DONE, and CANCELLED without one), or **No state**. Moving into a done state adds a `CLOSED:` stamp under the heading, and moving out of one removes it. The same menu sets a Scheduled or Deadline date the heading does not have yet. A heading without a state shows nothing extra: long-press its text and choose **State**.
- **Dates (Org).** Tap a Scheduled or Deadline date to pick another day, add or remove a time, or **Clear** it. A repeater such as `+1w` and a warning period stay, and a time range keeps its length. Marking a repeating task done does not move it to its next date.

Each tap saves at once, whatever Auto-Save says, and rewrites only the lines it changes. If the file changed on the server since it was read, nothing is overwritten: the editor opens with your change in it and offers the usual [conflict choices](#editing-workspace-files). A file the reader cannot save shows the same tasks, but tapping them does nothing. VoiceOver offers **Toggle**, **Change state**, and **Change date** as actions.

## Books (EPUB)

An `.epub` file opens as a book in the file viewer. The server sends books of up to 100 MB.

- **Pages.** Each chapter is set as screen-sized pages. Swipe or tap the edge of the page to turn it. A turn past the first or last page opens the previous or next chapter. While you read, the controls hide; tap the middle of the page to show them. A line at the bottom shows the page and the time left in the chapter.
- **Bar.** A book shows one bar, whose **Share** sends the `.epub` file. The book's header under it names the chapter.
- **Table of Contents**, in the header, lists the chapters and marks the one on screen.
- **Aa** sets the text size, theme (**Original**, **Sepia**, **Gray**, **Dark**), typeface (**New York**, **System**, **Georgia**, **Palatino**), line spacing, margins, justification, and **Pages** or **Scrolling**. Changes apply at once and are kept on this device. **Scrolling** shows one chapter at a time, with **Previous** and **Next** at its end.
- **Position.** Oppi keeps your place in each book on this device. A change of size, theme, or layout keeps the paragraph you were reading on screen.
- **Limits.** Fixed-layout pages and vertical writing show "This chapter can't be shown yet". Images show as their alt text. A book with DRM says that it is protected.

## Diagrams and maps

**Mermaid.** Fenced `mermaid` blocks and `.mmd` / `.mermaid` files render flowchart (`graph`), sequence, class, state, ER, gantt, pie, mindmap, timeline (`timeline-beta`), xyChart, journey, quadrantChart, gitGraph, sankey (`sankey-beta`), and kanban diagrams. Unknown types show an unsupported placeholder.

**Visual Markup.** In the full-screen rendered view, the bottom-left pencil starts Visual Markup, and a bottom-right pick menu offers **Pick Object** for flowchart, pie, and sequence diagrams. You can still pan and pinch while picking, and **Browse** leaves pick mode. A tap highlights the node, edge, slice, legend row, participant, or message, with **Comment** beside it. A pie slice and its legend row are one object, as are a sequence arrow and its label. Overlapping hits open a chooser with readable labels. The comment prompt includes the readable label and short source excerpts, never internal IDs. If the source changes, the prompt keeps the original object and marks it stale. Other Mermaid types render but are not selectable.

**GeoJSON and TopoJSON.** `.geojson` and `.topojson` files, fenced `geojson` and `topojson` blocks, and `.json` files whose root `type` is `FeatureCollection`, `GeometryCollection`, or `Topology` open with Rendered (a MapKit map) and Source (JSON). Other JSON, such as `package.json`, stays a JSON listing. Invalid input keeps the source JSON and shows a short reason.

## HTML

The HTML viewer runs in a constrained `WKWebView` with a restrictive content security policy. It is a preview surface and gives workspace HTML no app privileges. Other viewers use native UIKit rendering, which gives fast scrolling and selection, system text behavior, Dynamic Type, accessibility, and review-comment selection.

**Comment on a rendered element.** In the full-screen HTML viewer, the pencil starts Visual Markup and the pick menu offers **Pick Element**. The inline preview has its own Pick control. Picking pauses browsing: a native shield catches the tap, so it never clicks or focuses page controls, and scrolling and pinching pause until **Browse**. A selected element shows a **Comment** bubble, and **Select Parent** walks to the containing element. Open shadow roots can be selected; closed shadow roots and frames are commented as the visible container, and the comment says so.

The outgoing comment gives the element's tag, readable label, bounded visible text, and page-order position when several share a tag. Oppi rechecks the node when you save: a replaced node, or text changed past the stored excerpt, is rejected, and a page that navigates or reloads first gets no comment attached elsewhere. Hidden content, form values, password fields, editable text, event-handler code, and token-bearing URLs are left out, as are `display`/`visibility`/`hidden`/`aria-hidden`, near-zero opacity, `font-size: 0`, and zero-size clipped text. Low-contrast or off-screen text is not guaranteed to be detected. HTML text-selection Comment and screenshot annotation stay available while browsing.

## Editing workspace files

A workspace text file opens in the reader, and **Edit** (in the reader's bar, or the toolbar beside the iPad file tree or file review) lets you type. Markdown, Org, code, JSON, and plain text up to 1 MiB are editable in the selected checkout or worktree when the server supports editing. Binaries, files that are themselves symlinks, and uploaded-file pills stay read-only. Files opened from a chat (file pills, **Files**, **Git** panel) use that session's worktree, and the editor shows which checkout it writes to. File review opens on **Changes**; its **File** tab and new files show current bytes with **Edit**, and deleted files stay diff-only.

A reader that shows less than the file, or the file as it was, still edits the live file: a tool's output row and the Git panel's **This session** copy (the session's copy of a file Git cannot diff) have the same pencil, and it opens the file as it is on disk now.


The editor has syntax color, line numbers, a current-line band, a status line (Ln/Col, indentation, language), native Find and Replace (⌘F), and Markdown styled in source. A wrapped line's number sits on its first row, and stays at the top of the screen while the rest of a tall wrapped paragraph scrolls by. Wrapped rows start where the line's text starts: flush for prose, under the indentation for code, under the item text for Markdown lists and quotes (inside a fenced code block, every line is code; a fence nested in a list item or quote is not detected, so its lines still wrap as items). Tap **Ln, Col** to go to a line. It uses your code font and size from **Settings → Text**.

- **Typing:** Return keeps indentation and the file's CRLF or LF ending, and adds a level after an opening bracket (or a colon in Python and YAML). Tab indents with the file's own style, Backspace in leading spaces removes one level, and typing a bracket or quote adds its closer (not quotes in Markdown). In Markdown, Return in a list or task item starts the next item, and Return on an empty item ends the list. Each of these is one undo step. Long-press the space bar to move the cursor like a trackpad.
- **Key bar:** Tab, repeating arrows, Undo, Redo, and common symbols; **Settings → Editor → Customize Keys** adds, removes, and reorders keys.
- **Hardware keyboard** (hold ⌘ on iPad to list them): ⌘S save, ⌘L go to line, ⌘/ toggle comment, ⌘] and ⌘[ (or Tab and ⇧Tab) indent and outdent, ⌥⌘[ and ⌥⌘] move lines, ⌘D duplicate line, ⇧⌘K delete line, ⌘↩ and ⇧⌘↩ open a line below or above, and ⌘B and ⌘I in Markdown.
- **Vim keybindings** (**Settings → Editor → Keybindings**, or the editor's options menu) start in Normal mode with a block cursor and mode badge. Supported: counts; motions `h j k l w W b B e E ge 0 ^ $ g_ gg G { } % f F t T ; , n N * # + - _` and ⌃d ⌃u ⌃f ⌃b; operators `d c y > < gu gU g~` with motions, doubled for lines, and text objects (`iw aw iW aW i" a" i' a' i( a( i[ a[ i{ a{ i< a< ip ap`); `x X s S D C Y p P J gJ r ~ u ⌃r .`; `i a I A o O`; Visual `v V gv o`; `zz zt zb`; and `/ ? :w :q :wq :x :<line> :s :%s`. Esc, ⌃[, or ⌃C leave Insert. Yanks also go to the system clipboard on this device only. `:q` closes like **Done**, `:w` and `:wq` save like ⌘S, and `:q!` closes without saving, throwing the edits away as **Discard Changes** does.
- **Settings → Editor** also sets syntax color, line numbers, current-line highlight, wrapping, indentation (detected by default), bracket closing, and the key bar. Markdown and plain text wrap by default and code does not; **Wrap Markdown and Text** and **Wrap Code** set each, and **Wrap Lines** in the options menu changes the open file's kind. **Auto-Save** is there too, and in the options menu beside Syntax Highlighting: off by default, so files save when you tap **Done**.

**Saving.** Typing is local, and an on-device draft holds it until the server confirms a save. Auto-Save decides how often a save happens: with it on, the app saves one second after you stop, one request at a time, and **Done**, Back, and leaving the app save the draft first and never wait for the network. With it off (the default), nothing is written on its own: **Done** asks **Save <name>?** — **Create <name>?** for a file that is not there yet, and a note when Pi reads the file for every new session — with **Save**, **Discard Changes**, and **Keep Editing**; ⌘S and Vim's `:w` and `:wq` save at once without asking; **Replace Disk Version** writes when you choose it; and a retry only ever resends bytes you already confirmed. Everything else — the idle timer, going back, backgrounding, leaving the app, a re-read after a save whose answer was lost, Review on a create that never landed — only checkpoints the draft, and reopening a file with a kept draft never writes it either. Turning Auto-Save on or off in the options menu applies to the editor that is open, and one setting covers every document the editor writes: a workspace file, a Skill file, a home file, an Agent's or a schedule's prompt, and Pi's own files. **Preview** renders the draft. Bytes save exactly as typed: line endings, BOM, Unicode form, JSON formatting, and the trailing newline are not normalized. The server never creates a workspace, Skill, or home file through the editor; the one file it creates is Pi's own `SYSTEM.md` or a prompt template, when it is not there and you save the editor opened on it.

**Conflicts.** The save carries the version tag from your read. If the file changed on the server, saving stops and your edits stay. **Review Changes** compares the disk version with your draft; **Use Disk Version** discards your edits; **Replace Disk Version** writes your draft only if the disk still matches the version you reviewed. If the file was deleted, the app keeps your draft, reopens it as deleted even after a restart, and does not recreate the file. If the draft cannot be saved on the device, the editor says so. The server checks the tag just before an atomic rename, so an agent, git, or shell writing at that exact moment can still race a save.

## Editing a file you reached by a link

A file edits the same way however you reached it. A chat link, a wiki link, a Markdown or Org `file:` link inside another document, a host path, a tool's output row, and the workspace's file tree can all name the same file. The server follows the path to the real file, after symlinks, and picks the one place that owns it. Every way in gets the same pencil, and they share one editor, one draft, and one **Conflict** check.

The owner is the narrowest one that holds the file:

1. Pi's own `SYSTEM.md` and prompt templates.
2. An editable Skill's own files.
3. The workspace checkout or worktree that contains the file. When two workspaces use the same folder, the server always picks the same one.
4. Any other file in the server account's home folder, such as a notes folder outside every workspace (see [Home files](#home-files)).

A file outside the home and every workspace stays read-only. A link followed from a sandbox session's chat is checked inside that sandbox: a file in the sandbox edits as the sandbox workspace's file, and a host path outside it is not even read, so a sandbox session's link never opens a host file for editing.

This needs a server with file edit origins. An older server only edits workspace, Skill, and Pi files, and only when they are opened from their own workspace or page.

### Home files

A text file under the server account's home folder that no workspace, Skill, or Pi owns is editable from your paired devices, with the same 1 MiB, UTF-8, tag, and **Conflict** rules as a workspace file. A paired device can already run agents with full access to that account, so editing is not new access. These limits stop a tapped link from opening a secret, or a file that runs code the next time something starts:

- **Credentials** are never editable: `.ssh`, `.aws`, `.azure`, `.gnupg`, `.kube`, `.docker`, `.password-store`, `.config/gh`, `.config/gcloud`, `.config/op`, and `.local/share/keyrings`. Names such as `.env` and `.env.*`, `.envrc`, `.netrc`, `.npmrc`, `.pypirc`, `.pgpass`, `.git-credentials`, `auth.json`, `credentials` and `.credentials.*`, `secrets.*`, `token.json` and `*tokens.json`, and `*.pem`, `*.key`, `*.p12`, `*.pfx` are protected in any folder.
- **Oppi and Pi** are protected: the server's data directory, `.config/oppi`, and Pi's `~/.pi` (Pi's own files edit through Pi).
- **Files that run code** are protected: shell startup (`.config/fish`, `.config/zsh`, `.oh-my-zsh`, `.zsh`); programs on the `PATH` and the toolchains and packages they load (`bin`, `.local/bin`, `.local/lib`, `.bun`, `.cargo`, `.nvm`, `.npm`, `.pyenv`, and similar, plus any `node_modules`, `site-packages`, or `.venv` folder); tools that run commands from their settings (`.claude`, `.claude.json`, `.codex`, `.cursor`, `.gemini`, `.vscode`, `.config/zed`, `.config/nvim`, `.vim`, `.hammerspoon`, `.config/karabiner`, `.config/git`, `.ipython`); any `.git` folder; `bunfig.toml`, `sitecustomize.py`, and `usercustomize.py` in any folder; and a file with an execute permission bit.
- **`~/Library`** is protected, except iCloud Drive (`Library/Mobile Documents`).
- A file with a second hard link is read-only: a save replaces the file, so the other name would keep the old text.
- A file in a package Skill is read-only, as it is on the Skill's own page.
- The server checks the path you opened and the real path after symlinks. A folder link into a protected folder or out of the home folder is refused. A path that goes through a link inside a sandbox workspace's folder edits only a file in that sandbox, because the sandbox decides where its links lead. A file that is itself a symlink is read-only through that name, on every origin; open the file it points to by its own path to edit it.
- Only text types the editor opens are editable. Most dotfiles, such as `.zshrc`, are not one of them.
- The editor never creates a home file.
- The server logs every save with its path, and for a home file the real path and the device that saved it. It never logs file contents.

This list cannot name every file that some program runs. To keep every home file read-only, set `fileEditing.hostFiles` to `false` and restart the server (see [Server configuration](server-configuration.md)). Workspace, Skill, and Pi files still edit.

## Editing Skill files

The files of an editable Skill (one in `~/.pi/agent/skills` or another top-level Skill directory, not from a package) open in the same editor when the server supports it, with the same save and conflict rules. A Skill that is a single Markdown file edits only that file. The file's pencil opens the editor on it, and the reader's **…** menu holds **Edit with Session**, which starts an Oppi Control session that revises the Skill with your staged comments ([Edit with Oppi](usage.md#edit-with-oppi)). Package Skills stay read-only. A Skill file that is a symlink, over 1 MiB, or not UTF-8 text is read-only. A Skill file opened from a chat's Skill row shows the same reader, and so the same pencil and **…**, when the server's catalog proves that Skill is editable and the file is one of its own: it is matched by the Skill's own path, so a project Skill that shares a global Skill's name is never edited as that Skill, and one the catalog cannot name stays a plain reader.

## Editing an Agent's or a schedule's prompt

An Agent's prompt reader and a schedule's prompt reader have the same pencil and **…**, and the pencil opens the same editor on the prompt itself, not on the definition the reader pieces together. An Agent's prompt is its custom system prompt: the editor shows **Append** or **Replace**, which is how Pi reads it, and an Agent with no custom prompt opens on an empty one. Emptying the prompt saves the Agent without a custom prompt. A schedule's prompt is the text a run sends, so it is never empty. Saves carry the version the editor read: if the Agent or schedule changed on the server first, autosave stops and the editor shows **Conflict**, and **Review Changes** compares the server's version with your draft.

Pi's own `SYSTEM.md` reader has the same pencil when the server offers Pi file editing: it edits `~/.pi/agent/SYSTEM.md` with the same tags and **Conflict** banner. Those are the only files in Pi's agent directory the editor writes, and the server refuses a path outside them, a `..` path, a symlink that leads out of Pi's agent directory, and an allowlisted path that a symlink inside it points somewhere else. A `SYSTEM.md` that is itself a symlink is refused, so a dotfile-managed prompt stays read-only. When `SYSTEM.md` does not exist, the reader still shows Pi's default prompt and its pencil opens that same default prompt as the editor’s text: leaving it alone writes nothing, and the first edit saves `~/.pi/agent/SYSTEM.md` holding the edited default, which is what stops Pi using its built-in one. If something else created it first, that save is a **Conflict** and nothing is overwritten. Pi's prompt templates under `~/.pi/agent/prompts/` are writable by that same origin, and a missing one is created with its first save (the `prompts/` directory with it), but no screen opens them yet.

## Export

The Viewing Options panel controls on-screen reading. Export and share live in the toolbar beside copy and share. A renderer preset can define export choices such as document theme, heading scale, margins, code-block style, and page width; the reader previews compatible parts, and the source document never changes unless you export or save a generated artifact.
