# Document viewers

Oppi renders text and document output in native full-screen viewers on iPhone and iPad. These viewers are for reading, review, copy/share, and selection. They do not modify the underlying file, tool output, session transcript, or agent context.

This page covers full-screen viewers for markdown, code, source text, diffs, terminal output, HTML, and rendered document formats such as Org, LaTeX, Mermaid, and Graphviz. Media viewers such as images, audio, video placeholders, and PDFs use their own controls.

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

The options affect only the current viewer family. For example, changing terminal wrapping does not change markdown spacing, and changing markdown text size does not change code text size.

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
