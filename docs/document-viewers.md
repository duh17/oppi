# Document viewers

Oppi renders text and document output in native full-screen viewers on iPhone and iPad. Use them to read, review, copy, share, and select. They do not modify the underlying file, tool output, session transcript, or agent context.

This page covers full-screen viewers for markdown, code, source text, diffs, terminal output, HTML, and rendered document formats such as Org, LaTeX, Mermaid, and Graphviz. Media viewers such as images, audio, video players, and PDFs use their own controls.

## Workspace wiki links

Assistant messages can reference files in the active workspace with:

```text
[[path/to/file]]
[[path/to/file|Human-readable label]]
```

The target is a workspace-relative path. Oppi preserves an explicit extension, adds `.md` to an extensionless target, and resolves `./` or `../` relative to the source Markdown file's directory when that directory is known. Backslashes become `/`. Absolute paths, `~` paths, `file://` URLs, query strings, and fragments are not workspace wiki links.

### What links can open

Git tracking does not decide whether an exact link can open. Tracked files and safe Git-ignored files can use the same syntax. Examples include:

- Markdown and text: `[[.internal/release-notes/testflight-build-45-changelog.md|Build 45 release note]]`
- Source and structured text: `[[server/src/file-serving-policy.ts|File-serving policy]]` and `[[package.json|Package metadata]]`
- Images: `[[docs/images/app-icon.png|Oppi app icon]]`
- Audio and video: recognized files such as `.mp3`, `.wav`, `.m4a`, `.mp4`, `.mov`, and `.m3u8`
- Other recognized documents: HTML, CSS, XML, CSV, and PDF files

Oppi selects a document or media viewer from the detected file type. An unknown binary file can be served within the file limits below, but it does not guarantee a native preview.

### Resolution, navigation, and limits

Oppi resolves a wiki link when the user taps it. It checks the exact parent directory instead of relying on fuzzy search. One matching session or workspace file opens directly. Multiple matches show a chooser; no match shows an unresolved-file message. A link to the current session remains inert. Opening a file pushes its viewer onto the current navigation stack, and Back returns to the originating chat or file context.

Fuzzy discovery uses a deterministic, bounded filesystem walk rather than Git's ignore rules. It includes safe Git-ignored files such as `.internal/**`, but excludes major VCS, dependency, build, generated, and cache directories, root `.pi` runtime state, sensitive files, and symlink aliases. An explicitly named existing file can still be checked by exact lookup; agents must not cite private `.pi` state, session stores, credentials, or configuration.

The server enforces these limits:

- Images and PDFs: 50 MB maximum.
- Text and other non-streaming files: 10 MB maximum.
- Audio, video, and HLS media: authenticated range streaming without the text/image size cap.
- Exact parent-directory lookup: at most 1,000 entries. Resolution can fail when a candidate's directory has more than 1,000 siblings. Fuzzy search reports truncation when it reaches its traversal bounds.

### Workspace and security boundary

Wiki links can open workspace files only. The server canonicalizes the workspace root and requested file with `realpath`, then requires the canonical file to remain inside the canonical workspace root. This rejects `..` traversal, absolute or other path escapes, and symlinks that resolve outside the workspace. Search does not follow symlinks or index aliases.

Directory listings can show sensitive names, but raw serving blocks `.env` files, private-key and certificate extensions, SSH private-key names, credential files such as `.netrc` and `.npmrc`, and paths under `.git`. A rejected path fails closed instead of falling back to an external or arbitrary host path.

### Recommended agent instruction

Copy this into a Pi or agent system prompt:

```text
When citing a relevant file from the current Oppi workspace, use a workspace-relative wiki link such as [[path/to/file.ext|Short human-readable label]]. Reuse an existing path from the workspace; never fabricate a path or use an absolute, ~, file://, or outside-workspace path. Keep a normal human-readable sentence and brief context around every link so Oppi can render it as a navigable personal-wiki reference. Do not cite secrets, credentials, private runtime state, or sensitive files.
```

Inline Markdown images support workspace-relative raster paths, source-relative paths when source context is known, and the existing client SVG path for SVG. See [Markdown image resolution](attachment-rendering.md#markdown-image-resolution).

### Copyable `AGENTS.md` guidance for other projects

````markdown
- When pointing the user to a relevant file in the current workspace for navigation, use a real workspace-relative wiki link such as `[[path/to/file.ext|Short label]]`.
- When the image or SVG itself should appear inline, use standard Markdown image syntax such as `![Short description](path/to/image.png)` or `![Diagram](path/to/diagram.svg)`.
- For both formats, reuse a real existing workspace-relative path; never fabricate a path, use an absolute or outside-workspace path, or expose secrets or private runtime state. Keep normal human-readable context, and use these formats when actually showing or citing content—not for every casual filename mention.
- For a diagram that should render inline, use a fenced Markdown code block labeled `mermaid` with valid Mermaid source:
  ```mermaid
  graph LR
    A[Start] --> B[Done]
  ```
- For inline math, use `$x^2$` or `\(x^2\)`; for a displayed formula, use `$$x^2 + y^2 = z^2$$`, `\[...\]`, or a fenced `latex` block.
````

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
| Org, LaTeX, and Mermaid rendered documents | Text Size slider, Spacing where text-based, Reset View |

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

Viewing Options apply to the mode currently on screen. Source mode uses code/source reader behavior. Rendered mode uses document reader behavior.

## Native rendering and HTML

Oppi uses native UIKit rendering for interactive markdown, code, diffs, terminal output, and most document reading surfaces. Native rendering gives the app:

- fast scrolling and selection on iPhone and iPad
- system text behavior, edit menus, Dynamic Type, and accessibility hooks
- native review-comment selection support
- controlled image loading and workspace-relative markdown image resolution
- consistent toolbar behavior across sheet and embedded file-browser viewers

HTML is useful for content that is already HTML and for export-oriented rendering. The HTML viewer runs in a constrained `WKWebView` with a restrictive content security policy. It is a preview surface, not a way for arbitrary workspace HTML to gain app privileges.

## Export and renderer presets

The Viewing Options panel controls the on-screen reading experience. Export and share actions live in the toolbar next to copy/share controls.

Use explicit renderer configurations for custom export themes or renderer presets. A renderer preset can define export-facing choices such as document theme, heading scale, margins, code-block style, and page width. The native reader can preview compatible parts of those choices, but the source document remains unchanged unless the user exports or saves a generated artifact.

This separation keeps reading fast and native while preserving a clear path for HTML, PDF, and image export pipelines.
