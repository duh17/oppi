# Oppi client architecture: Renderer change map and cleanup targets

Part of [Oppi client architecture](../architecture-client.md).

## Adding a document renderer

A native document renderer draws a file format in the expanded tool row, the full-screen reader, and export (CSV/TSV, GeoJSON/TopoJSON).

1. **Classify (only if new to `FileKind`):** add the kind in `OppiCore/Formatting/FileKind.swift` and its extensions as a row in `FileKindTable.swift`, and a UI-free parser and plan in `OppiCore/Formatting` with bounds and a described failure. Nothing flags a new kind: map it in `DocumentFamily.init(fileKind:)`.
2. **One view:** a `UIView` that takes the plan, conforms to `ReaderBody`, shows its own fallback, and exposes `displays(_:)` for reuse.
3. **One composition point:** add the case to `DocumentFamily` (`Core/Views/DocumentFamily.swift`). Its exhaustive switches are the list; there is no registry, and call sites forward `.document` without naming the kind. A different default is a new `InlineTraits` field, never a per-kind branch at a call site. `ToolContentDescriptorBuilder` resolves the type once; nothing reclassifies it.
4. **Tests:** parser/plan tests, a `DocumentFamilyTests` case, a `ToolPresentationBuilderTests` case yielding `.document`, plus hosted-surface reuse or `FileShareServiceTests` where relevant.

A document renderer does not touch session runtime, transport, the reducer, or the surface owners beyond `ToolExpandedHostedSurface.installDocument`. A format shown as a fenced block in assistant prose (Mermaid, maps, LaTeX) is a Markdown segment instead.

## Adding a file viewer format

`FileViewerViewController` keeps loading, errors, size warning, and the text reader and editor (they share the edit owner). Other formats are `FileRenderer`s in `Oppi/Features/FileBrowser/Renderers/`, picked by preview category in `FileRendererRegistry`.

1. **Table:** a `FileKindTable` row maps extensions to a kind; an extension for an existing renderer stops here. Non-text formats also go in `protocol/file-kinds.json` and the server's `FILE_KINDS`.
2. **Renderer:** a new category is a `FilePreviewCategory` case, one renderer file (`load`, `mount`, its required `share`, only the hooks it uses), and its registry line; the compiler flags only the registry, so check the `default:` switches in `MarkdownWikiLink.swift` by hand. It reaches the viewer only through `FileRendererHost`; the viewer names no renderer or extension.

## Cleanup targets

- `APIClient.swift`: split by route domain, keeping one actor and the request helpers.
- `ServerConnection.swift` stays the composition root; capability, reconnect, and extension-UI policy move into small coordinators as they grow.
- `SessionInboxViewController.swift`, `WorkspaceDetailViewController.swift`: shared list behaviour belongs in `SessionListCollection.swift`; refresh, worktree, archive, and import state move to a small owner as the detail screen grows.
- `ChatViewController.swift` (and its extensions): screen structure only; lifecycle and timeline policy go to `ChatSessionManager`, composer state to `ChatComposerOwner`.
- Tool rows: the row orchestrates and calls `ToolExpandedMarkdownSurface` and `ToolExpandedHostedSurface` directly (no shared surface protocol); format dispatch lives in `DocumentFamily`.
