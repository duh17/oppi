# File Viewer Image Loading — Learnings

## Problem
Markdown files in the file browser that reference relative images
(e.g. `![alt](images/foo.png)`) showed alt text placeholders instead
of the actual images.

## Root Causes (3 layers)

### 1. No workspace context in file viewer
The file viewer (`MarkdownFileView`, `NativeFullScreenMarkdownBody`) created
`AssistantMarkdownContentView` without `workspaceID`, `serverBaseURL`, or
`fetchWorkspaceFile`. Without these, `resolveStandaloneImage()` returned
`nil` for all relative paths.

**Fix**: Thread workspace context via `FullScreenCodeContent.WorkspaceContext`
from `FileBrowserContentView` through `EmbeddedFileViewerView` →
`FullScreenCodeViewController` → `NativeFullScreenMarkdownBody`.

### 2. No source directory for relative path resolution
Even with workspace context, a relative path `images/foo.png` in
`docs/showcase.md` resolved to `/images/foo.png` instead of
`/docs/images/foo.png`.

**Fix**: Add `sourceFilePath` to config, derive `sourceDirectory`,
pass to `FlatSegment.build()` → `resolveStandaloneImage()` which
prepends the directory to relative paths.

### 3. Wrong API endpoint
`fetchWorkspaceFile` uses the session file API (`/workspaces/{id}/files/{path}`).
The file browser needs `browseWorkspaceFile` which adds `?mode=browse`.

**Fix**: Use `api.browseWorkspaceFile()` in the `FileBrowserContentView`
workspace context closure.

## Layer Map
```
FileBrowserContentView (has workspaceId + apiClient)
  → FullScreenCodeContent.markdown(workspaceContext: ...)
    → EmbeddedFileViewerView (UIViewControllerRepresentable bridge)
      → FullScreenCodeViewController (UIKit VC, manages chrome)
        → NativeFullScreenMarkdownBody (UIScrollView wrapper)
          → AssistantMarkdownContentView (coordinator)
            → AssistantMarkdownSegmentSource → FlatSegment.build(sourceDirectory:)
              → resolveStandaloneImage(sourceDirectory:) → prepend dir to relative path
            → AssistantMarkdownSegmentApplier
              → NativeMarkdownImageView.apply(url:, fetchWorkspaceFile:)
                → fetchWorkspaceFile(workspaceID, resolvedPath)
                  → api.browseWorkspaceFile(workspaceId:, path:)
```

## Key Distinction
- **Inline rendering** (mermaid, code, tables): Works. No workspace context needed.
  These are parsed from markdown fences and rendered by CoreGraphics/UIKit.
- **Workspace images**: Needs workspace context + correct API + source directory
  resolution. This is file I/O, not rendering.

## Status
- Workspace context threading: Done
- Source directory resolution: Done  
- API endpoint: Fixed (browseWorkspaceFile)
- Still needs: verification on device that images actually load
