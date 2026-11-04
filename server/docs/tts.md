# Voice replies / TTS

Oppi defines only a **generic audio reply contract**. It does not require a specific TTS provider, voice catalog, or synthesis workflow. An extension does its own synthesis, then hands Oppi plain JSON: a tool result `details` object for the voice card, and optional live audio events for low-latency playback. There is no helper module to import.

## Voice card: `audio_presentation` details

A tool returns this object as `details`, in its final result and, optionally, in `onUpdate` while it works:

```ts
type AudioPresentationDetails = {
  kind: "audio_presentation";                 // marks the row as a voice message
  text?: string;                              // transcript shown on the card
  playbackBehavior?: "tapToPlay" | "playNow"; // other values count as missing
  audio?: {
    kind: "audio";
    id?: string;              // stored attachment ID; the card plays from it
    mimeType: string;         // clients play only "audio/wav"
    base64?: string;          // server stores the bytes and replaces them with an id
    path?: string;            // server stores the file only from a trusted root
    fileName?: string;
    sizeBytes?: number;
    durationSeconds?: number;
  };
};
```

Other fields in `details` are not part of this contract; clients ignore them.

| Field | Server and client behavior |
| --- | --- |
| `kind` | Must be `"audio_presentation"`. The server also promotes details that have `audio.kind: "audio"` and any other or missing `kind`, and takes `text` from the first non-empty `text`, `message`, or `transcript` string. |
| `text` | The card transcript. If it is empty, the client uses the tool's `text` argument, then the tool's text output unless that output is exactly `Voice message`. When an update has no text content, the server streams `text` as the row's output. |
| `playbackBehavior` | See [Audio playback behavior](#audio-playback-behavior). |
| `audio` | In-flight updates usually omit it. Without `audio`, the card shows the transcript and the live stream for this row, if any. |
| `audio.id` | When present, the server keeps the entry and removes `path`, `base64`, and `data` from it. |
| `audio.base64` | Without an `id`, the server decodes the bytes (at most 50 MB), stores them in session storage, and replaces `audio` with the stored metadata. |
| `audio.path` | Without an `id`, the server copies the file only when it is inside `~/Library/Application Support/Yuwp/Audio/pi-voice` and at most 50 MB. It tries `path` before `base64`. Otherwise it drops `path`. |
| `audio.mimeType` | When the server stores bytes, a value that does not start with `audio/` becomes `audio/wav`. The client trims and lowercases it, and shows any type other than `audio/wav` as unavailable. |
| `audio.fileName`, `audio.durationSeconds` | Copied into the stored attachment. `durationSeconds` labels the card before playback. |

After storage, `audio` holds `kind`, `id`, `mimeType`, `fileName`, `sizeBytes`, and `storageKey`, plus `sha256` and `durationSeconds` when known. Clients fetch the bytes by session ID and attachment ID, not from `path` or `storageKey`.

The simplest way to get an `id` is `ctx.attachments.addFile()`. It is an Oppi addition to the tool context, not a portable Pi API; see [Attachment rendering](../../docs/attachment-rendering.md#store-a-file).

```ts
onUpdate?.({
  content: [{ type: "text", text: spokenText }],
  details: { kind: "audio_presentation", text: spokenText, playbackBehavior: "playNow" },
});

// ... synthesize to wavPath ...

const audio = await ctx.attachments.addFile({
  path: wavPath,
  kind: "audio",
  mimeType: "audio/wav",
  fileName: "reply.wav",
  durationSeconds,
  deleteSource: true,
});

return {
  content: [{ type: "text", text: spokenText }],
  details: { kind: "audio_presentation", text: spokenText, playbackBehavior: "playNow", audio },
};
```

## Live audio: `ctx.ui.audioStream`

To start playback before the file is complete, call `ctx.ui.audioStream(event)` from the tool. Oppi adds this function to `ctx.ui` in the sessions it hosts. Other Pi hosts do not have it, so check before you call it:

```ts
type AudioStreamEvent = {
  kind: "audio-stream";
  id: string;                                   // 1–128 characters; use toolCallId
  event: "metadata" | "chunk" | "done" | "error";
  mimeType: "audio/pcm; codecs=s16le" | "audio/wav";
  sampleRate?: number;       // integer, 8000–48000 Hz; client default 24000
  channels?: number;         // 1 or 2; client default 1
  chunkIndex?: number;       // non-negative integer
  audioBase64?: string;      // valid padded base64, at most 512 KB per event
  text?: string;             // at most 2000 characters; logged with error events
  durationSeconds?: number;  // finite, non-negative
  metrics?: Record<string, unknown>;
  playbackBehavior?: "tapToPlay" | "playNow";
};

const audioStream = (ctx.ui as { audioStream?: (event: AudioStreamEvent) => void }).audioStream;
const base = { kind: "audio-stream", id: toolCallId, mimeType: "audio/pcm; codecs=s16le", playbackBehavior: "playNow" } as const;

audioStream?.({ ...base, event: "metadata", sampleRate: 24000, channels: 1 });
audioStream?.({ ...base, event: "chunk", chunkIndex: 0, audioBase64: pcmChunkBase64 });
audioStream?.({ ...base, event: "done" });
```

`audioStream` throws when an event does not match this shape or breaks one of its limits. The server forwards valid events to clients as `audio_stream` messages.

Use `toolCallId` as the stream `id`. This correlation lets Oppi attach stream playback controls to the correct tool row.

Clients play a stream only when its `playbackBehavior` is `playNow` and the session's reply mode is **Agent decides**; they ignore every other stream. For `audio/pcm; codecs=s16le` (16-bit little-endian PCM), `metadata` starts playback with the given format (a first `chunk` without it uses the defaults), each `chunk` plays in arrival order, `done` ends playback after buffered audio drains, and `error` stops it. For `audio/wav`, a `chunk` or `done` event that carries a complete WAV file in `audioBase64` plays as one clip. Clients do not act on `chunkIndex`, `durationSeconds`, or `metrics`.

Live audio does not replace the voice card. Return `audio_presentation` details with the stored file as well, so the reply can be replayed later.

## Audio playback behavior

`playbackBehavior` has two values:

- `tapToPlay` — show a playable card
- `playNow` — request immediate playback when the current session allows reply-controlled playback

Notes:

- Default missing behavior to `tapToPlay`.
- Manual mode suppresses autoplay even when a reply says `playNow`.
- Keep the contract based on local files and session attachments, rather than arbitrary remote-URL playback.

## Client playback modes

In **Settings → Voice → Voice Replies**:

- **Manual** — keep audio replies tap-to-play.
- **Agent decides** — follow each reply's playback behavior.

A tool named `voice_reply_mode` can change the current session's mode by returning `details: { kind: "voice_reply_mode", mode }`, where `mode` is `manual`, `autoplay`, or `default` (clear the session override). For example, a user can say “keep this chat manual” or “for this session, let the agent decide.” Oppi ships no such tool; an extension provides it.
