# Oppi client architecture: Media, files, and sharing

Part of [Oppi client architecture](../architecture-client.md).

## Content access

- File previews and media use authenticated HTTP; the session WebSocket never carries raw media bytes. `AuthenticatedMediaSource` turns media requests into bearer-authenticated range requests.
- `APIClient` builds every current-file read through one origin-aware builder: `GET/HEAD /files/current?origin=…`, with no capability check and no legacy fallback (iOS build 53 / server 0.51.0 minimum). OppiMac uses the same route on the Unix socket (`MacCurrentFileRequest`). Attachments and tool output keep their id routes. `HostFileResolvedPathHeaders` decodes the percent-encoded `X-Oppi-Resolved-Path`.
- `SessionContentAccess` (`Core/Networking/`) owns row content operations and origin routing; `ServerConnection` owns client install, auth, and lifecycle. It reads the current client each time an operation starts or resumes, waits at most 50 × 100 ms (cancellable), lets the current catalog runtime win over a row-captured one, keeps workspace, session, host, and attachment origins distinct, and holds no cache. File browsing does not use it.
- `SessionContentAccess.toolOutputAccess(sessionId:routeScope:)` is the one place tool-output transport is built (nil, without waiting, if client or scope is missing). Only `outputAvailability.source: "sidecar"` enables full output; Pi result truncation marks stored text preview-only. `ExpandedToolOutputLoader` is the sole loader and `ToolOutputStore` the sole store.
- `MarkdownResourceAccess` (`Core/Views/`) is the one value carrying a document's identity and providers; pass-through owners do not unpack it and leaf views take only the provider they need. Identity is compared; providers never are, and an equal identity skips the re-apply. `sourceFilePath` stays separate so relative links keep their base. The file browser and touched-file readers build their own value from their own routes.
- Host HTML/SVG load through fetch → `loadHTMLString` with CSP; `WKWebView` must never URL-load `/files/current*`. Relative links in host Markdown resolve against the source directory before classification. Sidecars go through `TimedText.access(for:)`.

## Workspace file editing (iOS)

When the pencil shows and how Auto-Save gates writes: [Document editing](../architecture-client.md#document-editing).

- `APIClient.readFileForEditing` returns bytes and a strong `ETag` from one GET; `writeEditedFile` builds the only write: `PUT /files/current` with raw bytes and one concrete `If-Match`.
- Identity (`WorkspaceFileEditIdentity`) is server + owner + owner-relative path; a worktree never falls back to main. Draft keys are namespaced by owner (`storageKey`: `v1…`, `skill-v1…`, `pi-v1…`, `agent-v1…`, `schedule-v1…`), byte-identical to drafts already on disk.
- `WorkspaceFileEditSession` (`Features/FileBrowser/Editing/`) alone sets status. `WorkspaceFileEditOpening` decides, purely, how a session opens (buffer, base, draft handling). `WorkspaceFileWriteQueue` runs the writes and decides nothing: one in flight, a person's save queued behind it, each scoped by generation, epoch, and request token, so a late response never marks newer edits saved. 412 → conflict and 404 → deleted stop autosave but keep the draft; a deleted file is never recreated. `notSent` retries with the same tag; `unknown` re-reads (equal bytes → acknowledged, unchanged base → resend, else conflict). Replace sends the reviewed tag. Text is exact UTF-8 with no normalization.
- `WorkspaceFileDraftStore` writes one protected file per identity in Application Support, never `UserDefaults`, before any network wait. A failed draft write is surfaced. A draft that cannot be applied is moved aside as `<key>.<ms>.unreadable`, never deleted. `WorkspaceFileEditSessionRegistry` reuses a live session per identity, so a file never gets a second writer.
- The editor (`WorkspaceFileEditorViewController`, one `CodeEditorTextView`) recolours and previews in place, so selection and undo survive. Every edit command is a pure `CodeTextEditing` function applied as one `replace` (one undo step); `VimEngine` never touches UIKit; `CodeEditorHighlightEngine` reparses incrementally, queries only the viewport, and drops results for older text; gutter and cursor overlays never touch storage, selection, or undo; nothing edits during marked text.

## Launch and intake

- Agent launch constraints are server-authored and authoritative; a rejected launch stays on the launch surface with the server's explanation. Terminal configuration stream closures are non-retryable.
- `StartQuickSessionIntent` runs in the main app. The share extension stages into the App Group, starts the session itself, and deletes staged files on success or cancel; its drafts never enter the main app.
- `AppOpener` holds the latest accepted Shortcuts/Siri/Control payload and presents it once App Lock, launch, and the shell are ready; a request while the sheet is open is dropped, never queued.
