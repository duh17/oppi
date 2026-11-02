# Oppi client architecture: Renderer change map and cleanup targets

Part of [Oppi client architecture](../architecture-client.md); same standard (owners, boundaries, invariants, entry points).

## Adding a document renderer

A native document renderer draws a file format itself in the expanded tool row, the full-screen reader, and export (implemented: CSV/TSV, GeoJSON/TopoJSON).

1. **Classify (only if new to `FileType`):** add the case and detection in `OppiCore/Formatting/FileType.swift`, and a UI-free parser and plan in `OppiCore/Formatting` with bounds and a described failure. The compiler then flags `DocumentFamily.init(fileType:)`, `ToolPresentationBuilder.expandedFileContent`, and the Mac renderer.
2. **One view:** a `UIView` that takes the plan, conforms to `FullScreenReaderConfigurable`, shows its own fallback, and exposes `displays(_:)` for reuse.
3. **One composition point:** add the case to `DocumentFamily` (`Core/Views/DocumentFamily.swift`). Its exhaustive switches are the list; there is no registry, and call sites forward `.document` without naming the kind. A different default is a new `InlineTraits` field, never a per-kind branch at a call site. `ToolContentDescriptorBuilder` resolves the type once; nothing reclassifies it.
4. **Tests:** parser/plan tests, a `DocumentFamilyTests` case, a `ToolPresentationBuilderTests` case yielding `.document`, plus hosted-surface reuse or `FileShareServiceTests` where relevant.

A document renderer does not touch session runtime, transport, the reducer, or the surface owners beyond `ToolExpandedHostedSurface.installDocument`. A format shown as a fenced block in assistant prose (Mermaid, maps, LaTeX) is a Markdown segment instead. The Mac renderer is separate (`MacMarkdownPaintKind`).

## Cleanup targets

- `APIClient.swift`: split by route domain, keeping one actor and the request helpers.
- `ServerConnection.swift`: stays the composition root; move capability, reconnect, and extension-UI policy into small coordinators as they grow.
- `SessionInboxViewController.swift`, `WorkspaceDetailViewController.swift`: shared list behaviour belongs in `SessionListCollection.swift`; extract refresh, worktree, archive, and import state into a small owner as the detail screen grows.
- `ChatViewController.swift` (+`Bars`, `+Presentations`, `+Leaves`): screen structure only; lifecycle and timeline policy go to `ChatSessionManager`, composer state to `ChatComposerOwner`.
- Tool rows: the row orchestrates and calls `ToolExpandedMarkdownSurface` and `ToolExpandedHostedSurface` directly (no shared surface protocol); format dispatch lives in `DocumentFamily`.
