# Attachment rendering

This document describes how Oppi renders files attached to messages and tool results.

It is for extension authors, prompt authors, and Oppi client/server developers. Use it when a tool or message needs to show a screenshot, generated image, voice clip, browser recording, PDF, or other file.

## Status

Oppi already has three attachment paths:

- user message attachments, uploaded before a prompt is sent
- tool-produced image attachments through `details.image`
- tool-produced audio through `kind: "audio_presentation"` and `details.audio`

Expanded tool rows also understand `details.media[]` for stored media attachment metadata. The video path should extend `details.media[]` rather than add a new markdown URL scheme.

## Core rule

Attachments are structured metadata plus server-owned bytes. They are not markdown URLs.

Tools return attachment metadata in `details`. Clients render that metadata with native image, audio, video, or file views. Markdown `![]()` keeps its current job: resolving image file paths and remote images.

## Deployment model and trust boundary

Oppi is self-hosted. A paired iPhone or iPad talks to an owner-run server, usually over LAN, Tailscale, or TLS with certificate pinning.

The trust boundary is:

- bearer-token authentication for HTTP and WebSocket requests
- workspace/session ownership checks on server routes
- server-controlled attachment storage

Network membership is not enough. Tailscale or LAN limits exposure, but bearer auth remains required.

## Attachment metadata

Renderable tool attachments use this shape.

```ts
type ToolMediaAttachment = {
  kind: "image" | "audio" | "video" | "file";
  id: string;
  mimeType: string;
  fileName?: string;
  sizeBytes?: number;
  width?: number;
  height?: number;
  durationSeconds?: number;
};
```

The server-side attachment record can also include storage fields such as `storageKey`, `sha256`, `createdAt`, `toolCallId`, and optional text/transcript metadata. Clients do not construct file paths from those fields.

Required fields:

| Field      | Requirement                                                         |
| ---------- | ------------------------------------------------------------------- |
| `kind`     | Rendering category: `image`, `audio`, `video`, or `file`.           |
| `id`       | Stable session-local attachment ID.                                 |
| `mimeType` | Normalized MIME type such as `image/png`, `audio/wav`, `video/mp4`. |

Optional fields improve rendering:

- `fileName` gives users a readable title and a file extension hint.
- `sizeBytes` lets clients show size and enforce local limits.
- `width` and `height` let clients reserve image/video layout before loading bytes.
- `durationSeconds` lets clients label audio/video before playback.

## User message attachments

User files are uploaded before sending a prompt. The message carries `ChatAttachmentRef` values rather than raw file bytes.

```ts
type ChatAttachmentRef = {
  type: "attachment";
  id: string;
  source: "upload" | "workspace";
  name: string;
  mimeType: string;
  sizeBytes: number;
  sha256?: string;
  kind?: "image" | "text" | "pdf" | "audio" | "video" | "archive" | "unknown";
  workspacePath?: string;
};
```

Current message rendering treats uploaded files primarily as message attachment badges and image previews. The client also keeps a legacy `ImageAttachment` path for base64 image blobs used by pending/optimistic UI and older traces.

Message attachments and tool-result attachments share the same product idea: files associated with a chat entry. Their wire shapes differ because user uploads and tool results enter the system at different points.

## Tool image output

Image-producing tools can return `details.image`.

```ts
return {
  content: [{ type: "text", text: "Created image." }],
  details: {
    image: {
      kind: "image",
      id: "att_image_png",
      mimeType: "image/png",
      fileName: "result.png",
      sizeBytes: 180_000,
      width: 1280,
      height: 720,
    },
  },
};
```

Server materialization also accepts image bytes from tool details before replay. Final results should carry the stored attachment metadata, not large base64 payloads.

## Tool audio output

Voice/audio tools use `kind: "audio_presentation"` with `details.audio`.

```ts
return {
  content: [{ type: "text", text: "Voice message" }],
  details: {
    kind: "audio_presentation",
    text: "Here is the recorded answer.",
    playbackBehavior: "tapToPlay",
    audio: {
      kind: "audio",
      id: "att_voice_wav",
      mimeType: "audio/wav",
      fileName: "voice.wav",
      sizeBytes: 96_000,
      durationSeconds: 3.2,
    },
  },
};
```

The Apple client treats `audio/wav` as the replayable audio format for this card. Other audio MIME types render as unavailable unless a client adds support for them.

## Tool video output

Video should use `details.media[]` with `kind: "video"`.

```ts
return {
  content: [{ type: "text", text: "Captured browser run." }],
  details: {
    media: [
      {
        kind: "video",
        id: "att_browser_mp4",
        mimeType: "video/mp4",
        fileName: "browser-run.mp4",
        sizeBytes: 1_842_112,
        width: 1280,
        height: 720,
        durationSeconds: 9.4,
      },
    ],
  },
};
```

The expanded tool row renders stored video attachments as video cards and streams playback through authenticated range-capable media sources.

For Apple compatibility, use H.264 MP4 for generated video.

## Generic expanded media rows

Generic extension tools can return `details.media[]` for stored media rows.

```ts
return {
  content: [{ type: "text", text: "Created media." }],
  details: {
    expandedText: "Generated screenshot and recording.",
    presentationFormat: "markdown",
    media: [imageAttachment, videoAttachment],
  },
};
```

Current client behavior:

- image entries render as inline image previews
- video entries render as video cards
- audio playback uses the `audio_presentation` shape, not generic `media[]`
- unknown or unsupported entries render fallback text or are omitted from media preview rows

## Markdown image resolution

Markdown `![]()` continues to resolve images through the existing image resolver.

| Markdown source                        | Current behavior                                                                                            |
| -------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `![x](images/a.png)`                   | Resolves as a workspace-relative file when the renderer has workspace context.                              |
| `![x](../images/a.png)`                | Resolves relative to the markdown file directory when the source file path is known.                        |
| `![x](/abs/path.png)`                  | Resolves through the session raw-file API; the server requires a touched session file inside the workspace. |
| `![x](~/a.png)`                        | Same session raw-file path as absolute paths.                                                               |
| `![x](file:///abs/path.png)`           | Same session raw-file path as absolute paths.                                                               |
| `![x](https://example.com/a.png)`      | Shows a tap-to-load remote image prompt before fetching.                                                    |
| `![x](http://...)`, localhost, LAN IPs | Blocked by the remote image policy.                                                                         |
| `![x](data:...)`                       | Skipped by the markdown image resolver.                                                                     |

Image-only paragraphs become standalone image views. Mixed paragraphs split into text/image/text segments. Raster images are downsampled. SVG uses the existing SVG image path on clients that implement it.

Markdown image syntax does not resolve stored tool attachments. A tool that returns a stored video or stored image should put that metadata in `details.image`, `details.audio`, or `details.media[]`.

## Extension authoring API

Extension authors should use the server-provided helper to create stored tool attachments. They do not write `manifest.json`, inline large base64 payloads, or put generated media in the workspace just to make it render.

Minimal API:

```ts
const video = await ctx.attachments.addFile({
  path: mp4Path,
  kind: "video",
  mimeType: "video/mp4",
  fileName: "browser-run.mp4",
  deleteSource: true,
});

return {
  content: [{ type: "text", text: "Recorded browser run." }],
  details: {
    media: [video],
  },
};
```

Returned helper shape:

```ts
type StoredToolAttachment = ToolMediaAttachment & {
  storageKey?: string;
  sha256?: string;
};
```

`addFile()` copies bytes into server-owned session attachment storage before returning. If `deleteSource` is true, the helper removes the source file after a successful copy. Later rendering reads from attachment storage, not from the original path.

## Direct file paths

Workspace file rendering and attachment rendering solve different jobs.

Use workspace/session file routes for current project files:

- `docs/example.png`
- a source-controlled media file
- a touched session file that passes the session raw-file policy

Use stored tool attachments for files associated with a message or tool result:

- screenshots captured by a tool
- generated images
- voice or TTS audio
- browser automation recordings
- exported PDFs or reports

Direct file previews can change when the file changes. Stored tool attachments preserve the bytes associated with the tool result.

## Server requirements

The server owns attachment materialization and serving.

- Store tool attachments under server-controlled session attachment storage.
- Keep attachment records scoped to one session.
- Validate attachment IDs, MIME types, extensions, and byte sizes.
- Sniff image/audio/video headers where practical; do not trust only file extensions.
- Copy bytes from helper-approved paths, generated temp files, or authenticated uploads.
- Do not expose an HTTP API that attaches arbitrary server paths by name.
- Reject path traversal and symlink escapes.
- Serve media through authenticated endpoints.
- Support byte ranges for audio and video.
- Delete attachments when the owning session is deleted.

## Client requirements

Clients render attachments from metadata and authenticated byte sources.

- Choose the renderer from `kind` and `mimeType`.
- Show fallback text for unknown IDs, unsupported MIME types, missing bytes, or failed decodes.
- Keep audio/video playback user-initiated except for explicit trusted voice-message behavior.
- Use authenticated range-capable media sources for audio and video.
- Reuse existing full-screen viewers and media players where possible.
- Make fallback labels accessible with VoiceOver.

## Performance rules

- Do not embed base64 video or audio in markdown.
- Do not put large binary data in `details` JSON.
- Lazy-load media when the row is visible or when the user taps play.
- Use range streaming for audio and video.
- Downsample large images before display.
- Reserve layout from `width`, `height`, and `durationSeconds` when available.
- Cap automatically rendered attachments in one message or tool row; show a “more attachments” row after the cap.
- Cache decoded thumbnails or small images, not large video files in memory.
- Cancel media fetches when rows leave the screen.

## Security and privacy rules

- Treat markdown, attachment metadata, file names, alt text, and transcripts as untrusted text.
- Keep bearer tokens, local paths, and user secrets out of markdown and display metadata.
- Do not render tool media through arbitrary HTML tags.
- Do not auto-fetch remote media as a substitute for stored tool attachments.
- Route remote URLs through the existing tap-to-load remote image policy.
- Keep attachment endpoints authenticated and session-scoped.
- Block sensitive workspace paths in direct file-preview routes.
- Avoid logging full file paths or attachment text when it can contain private data.
- Treat stored attachments as durable session history until the session or attachment is deleted.

## Apple review posture

This contract renders user/session media with app-owned views. Apple clients do not download or execute extension code.

Review-friendly behavior:

- Playback is explicit and user-initiated for audio/video.
- Media bytes come from the user's paired server through authenticated requests.
- The app does not expose arbitrary WebKit video HTML for extension content.
- Extensions cannot access native device APIs through attachments.

## Acceptance criteria

A complete implementation satisfies these checks:

- Existing `details.image` results still render image previews.
- Existing `kind: "audio_presentation"` results still render voice/audio cards.
- A generic extension result with `details.media[]` can render image and video attachment rows.
- A tool-generated video can be stored outside the workspace and rendered from `details.media[]`.
- Markdown `![]()` keeps resolving workspace/session/remote images through the existing image resolver.
- Unknown attachment IDs render fallback text and do not trigger network fetches.
- Video and audio playback use authenticated range-capable media sources.
- Large binary data stays out of message text and tool `details` JSON.
- Session deletion removes attachment bytes and manifest entries.

## Related docs

- [`extensions.md`](extensions.md) — Oppi extension loading and generic mobile output behavior
- [`extension-native-ui.md`](extension-native-ui.md) — native extension UI blocks and Apple presentation mapping
- [`document-viewers.md`](document-viewers.md) — file and document viewer behavior
