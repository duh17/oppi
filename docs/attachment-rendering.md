# Attachment rendering

How Oppi shows files attached to messages and tool results: screenshots, generated images, voice clips, browser recordings, PDFs, and other files. For extension authors and prompt authors.

## Choose a path

| You want to show | Use |
| --- | --- |
| A screenshot or generated image | Stored attachment in `details.image` or `details.media[]` |
| A voice or TTS clip | `kind: "audio_presentation"` with `details.audio` |
| A recording or generated video | Stored attachment in `details.media[]`, H.264 MP4 |
| A PDF or generic file | A workspace or session path or link in `content` or `details.expandedText`; `details.media[]` does not render them |
| An existing project file, in assistant Markdown | A [Markdown embed](#markdown-embeds) or file link |

Attachments are structured metadata plus server-owned bytes, not Markdown URLs. Tools return the metadata in `details`, and clients render it with native image, audio, or video views. A stored attachment is fetched by session ID and attachment ID, so it does not depend on workspace file authorization once the server has copied the bytes. Markdown `![]()` and `![[]]` embed existing Oppi-backed files; they never address stored attachments.

## Store a file

Use the helper when `ctx.attachments` exists. It is an Oppi context addition, not a portable Pi API, so portable extensions need a fallback such as writing the output path into `content`.

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
  details: { media: [video] },
};
```

`addFile()` copies the bytes into server-owned session storage before returning, then removes the source when `deleteSource` is true. Rendering later reads from storage, not the original path. Tools must not write `manifest.json`, inline large base64 payloads, or put generated media in the workspace just to make it render. The server also accepts image bytes in tool details before replay, but final results should carry stored metadata.

## Attachment metadata

```ts
type ToolMediaAttachment = {
  kind: "image" | "audio" | "video";   // required: rendering category
  id: string;                          // required: stable session-local ID
  mimeType: string;                    // required: normalized, e.g. image/png, audio/wav, video/mp4
  fileName?: string;                   // title and extension hint
  sizeBytes?: number;                  // size label and local limits
  width?: number;                      // reserve image and video layout
  height?: number;
  durationSeconds?: number;            // label audio and video before playback
};
```

The stored record can also carry `storageKey`, `sha256`, and similar fields; clients never build file paths from them.

### Image

```ts
return {
  content: [{ type: "text", text: "Created image." }],
  details: {
    image: { kind: "image", id: "att_image_png", mimeType: "image/png", fileName: "result.png",
             sizeBytes: 180_000, width: 1280, height: 720 },
  },
};
```

### Audio

Clients replay `audio/wav` in this card; other audio types render as unavailable.

```ts
return {
  content: [{ type: "text", text: "Voice message" }],
  details: {
    kind: "audio_presentation",
    text: "Here is the recorded answer.",
    playbackBehavior: "tapToPlay",
    audio: { kind: "audio", id: "att_voice_wav", mimeType: "audio/wav", fileName: "voice.wav",
             sizeBytes: 96_000, durationSeconds: 3.2 },
  },
};
```

### Video and generic media rows

Video uses `details.media[]` with `kind: "video"`. Use H.264 MP4 for Apple compatibility. The expanded tool row shows a video card and streams playback through authenticated range requests. `pi-extensions/browser-automation-video` records WebM with `agent-browser`, converts it to H.264 MP4, stores it with `ctx.attachments.addFile()`, and returns it in `details.media[]`.

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

`media[]` renders image entries as inline previews and video entries as video cards. Audio uses `audio_presentation`, not `media[]`. Unsupported entries show fallback text or are omitted.

## User message uploads

Files uploaded before a prompt use `ChatAttachmentRef`, not `details.media[]`, and render as attachment badges and image previews. Uploads can be PDFs or archives.

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

### Stored images in chat history

Images on a user message are stored once in the session attachment store, next to tool media. History sends a reference instead of the bytes, so reloading a chat with screenshots does not download megabytes of image data. The model still receives the same content.

- A history entry carries `media[]` with the attachment record, the same shape as a tool `details.media[]` entry, instead of the image's data URI.
- The Apple client fetches the bytes by reference, reserves each thumbnail's slot from `width` and `height`, opens the full-screen viewer on tap, and keeps decoded thumbnails in a shared cache so scrolling back does not download them again.
- An image the server cannot store (over the 50 MB attachment cap, undecodable, or a write failure) stays an inline `data:image/...;base64,...` line, and the message keeps every image in order.
- Older app builds that do not declare `user-image-refs` get the earlier inline shape ([App capabilities and older builds](../protocol/README.md#app-capabilities-and-older-builds)).

## Direct file paths

Use workspace or session file routes for current project files, PDFs, reports, and generic files: a source-controlled media file, a path relative to the session workspace or worktree, or an explicit real host path. Reads need owner authentication. On a host workspace they serve an explicit real path that exists, including in-tree symlink targets and absolute or `~` paths. Sandbox reads stay confined to the sandbox mount. Audio and video stream with single byte ranges.

Direct previews change when the file changes. Stored attachments keep the bytes tied to the tool result, so use them for screenshots, generated images, TTS audio, and browser recordings.

## Markdown embeds

In assistant Markdown and the full-screen Markdown reader, `![[file]]` and `![label](file)` embed an existing workspace, worktree, session-reported, or exact owner-host file when it is an image, audio, video, or USDZ file. `[[file]]` and `[label](file)` stay ordinary file links. PDFs and other files are always links, with no leftover `!`.

Targets that are not files Oppi serves never become an embed and start no fetch: remote video or audio URLs, HTML `<video>` or `<audio>`, `data:`, `attachment:` IDs, `javascript:`, `.blend`, and `.glb`. Export uses a static card and keeps the source Markdown unchanged.

### Markdown image resolution

Embedded images use the same origin-first decision as video and audio. Public HTTPS images stay tap-to-load. Owner-host files use an authenticated full-byte request. Sandbox sessions map guest POSIX paths and never read host paths for guest paths.

| Markdown source | Behavior |
| --- | --- |
| `![x](images/a.png)` | Workspace-relative file when the renderer has workspace context |
| `![[docs/a.png]]` | Same native image view for an Oppi-backed image |
| `![x](../images/a.png)` | Relative to the Markdown file's directory when the source path is known |
| `![x](/abs/path.png)`, `![x](~/a.png)`, `![x](file:///abs/path.png)` | Owner-host image, fetched with authentication on render |
| `![x](https://example.com/a.png)` | Tap-to-load prompt before fetching |
| `![x](http://...)`, localhost, LAN IPs | Blocked by the remote image policy |
| `![x](data:...)` | Skipped |
| `![x](doc.pdf)`, `![[readme.md]]` | File link |
| `![x](https://example.com/a.usdz)` | Fails closed: not a remote image and not a USDZ embed |

Image-only paragraphs become standalone image views, and mixed paragraphs split into text, image, and text segments. Raster images are downsampled. SVG uses the client's SVG path. Markdown image syntax never resolves stored tool attachments.

### Markdown inline video

`![[video-file]]` and `![label](video-file)` show a still frame with a play button. No player exists until you tap play, so scrolling past many videos stays cheap. If the frame cannot be fetched, the row shows a placeholder with the same play button. Tapping builds the authenticated range-streaming player with native controls, full screen, and Picture in Picture; scrolling the row off screen pauses it. A failure shows an open-file fallback, and a missing file shows a not-found message. Bare paths in the fallback are workspace-root-relative; use `./` or `../` to be relative to the Markdown file.

The player always reserves 16:9, because wiki-file syntax has no dimensions, and portrait clips letterbox inside that slot. Same-directory sidecar captions (`stem(.lang)?.(vtt|srt|ass|ssa)`) overlay playback inline and full screen. Auto-pick uses the bare stem, then the device locale, then the first match, and a language control appears only with more than one match. A missing, oversized, or unparseable sidecar never blocks playback. Host files ask the server for a bounded same-stem lookup, which never lists a directory.

### Markdown inline audio

`![[audio-file]]` and `![label](audio-file)` show a compact 64 pt player strip with the file name and the clip's length (blank when the server cannot read it). Playback never starts automatically. Expanding the strip, or a plain `[[audio-file]]` link, opens the lyrics-first full-screen player. Eligible extensions are `wav`, `mp3`, `m4a`, `m4b`, `aac`, `flac`, `ogg`, `opus`, and `caf`. A failure keeps the strip with "Audio unavailable" and an open-file fallback. Voice `audio_presentation` rows keep their transcript and fetch no sidecar.

The full-screen player:

- **Lyrics:** same-directory sidecars (`stem(.lang)?.(lrc|vtt|srt|ass|ssa)`) load on expand, not on the compact strip. Without one, the player shows "No lyrics". The current line lights up word by word, spreading a cue's words evenly across its time; a line without its own end runs to the next line's start. Auto-scroll follows playback until you drag; **Current Line** resumes it. Long-press a line for **Play from Here** or **Copy**. The player shares the original file through the share sheet.
- **Scripts:** when a sidecar names speakers (WebVTT voice spans like `<v Narrator>Night fell.</v>`, or the ASS/SSA `Name` field; a cue mixing voices has no single speaker), the player reads it as a script for audiobooks and audio dramas. It lists the cast as chips in order of first line, lights up the current speaker, colors each new turn's name, and highlights the current paragraph. Tapping a paragraph jumps to it. A WebVTT `STYLE` block can set speaker colors; only `#RRGGBB` on `v[voice="…"]` selectors is read, and other speakers take the theme's accent colors.
- **Stage directions:** bracketed text such as `[laughs]` (1 to 40 characters on one line) shows as a small tag in the speaker's color.
- **Controls:** speed 0.75× to 2× (a saved preference that the lock screen shows and can change; live voice streams stay at normal speed); chapters from M4B/MP4 metadata, with previous and next buttons and a **Chapters** list (Previous restarts the chapter unless you are in its first three seconds); resume for recordings of five minutes or more (positions within 30 seconds of either end start over, and finishing forgets the position); and a sleep timer of 15, 30, 45, or 60 minutes of listening (pausing does not count) or the end of the chapter.

```text
STYLE
::cue(v[voice="Narrator"]) { color: #c9c9cf; }
```

### Markdown inline USDZ

`![[scene.usdz]]` and `![label](scene.usdz)` reserve a 1:1 slot. Chat scroll wins until you tap **Interact**; **Done** restores scroll. Drag orbits, pinch zooms, and two-finger pan moves the model; there is no auto-spin, and Reduce Motion adds no decorative motion. Expand opens a separate RealityKit scene from the same downloaded file, which is interactive at once and can reset the camera to a framed default. Loading, error, retry, and open-file fallback stay in the slot. Downloads use the 50 MB cap and load asynchronously. A plain `[[scene.usdz]]` link opens the document viewer.

## Rules for authors

- Keep base64 video and audio, and other large binary data, out of Markdown and `details` JSON.
- Treat Markdown, file names, alt text, metadata, and transcripts as untrusted text. Keep bearer tokens, local paths, and secrets out of Markdown and display metadata.
- Do not auto-fetch remote media as a substitute for stored attachments. Remote images follow the tap-to-load policy.
- Media loads when its row is visible or the user taps play, and audio and video playback is user-initiated.
- Layout reserves space from `width`, `height`, and `durationSeconds`, so provide them when you can.
- Stored attachments are scoped to one session and deleted with it. The server validates IDs, MIME types, and sizes, and does not trust file extensions alone.
- Workspace listings and fuzzy search are not secret-file access controls. Do not cite or dump secrets or private runtime state.

## Related

- [Oppi extension behavior](extensions.md): tool output fields and mobile rules
- [Extension native UI](extension-native-ui.md): prompts, widgets, and native blocks
- [Document viewers](document-viewers.md): file and document viewers
