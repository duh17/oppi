# Voice replies / TTS

Oppi defines only a **generic audio reply contract**. It does not require a specific TTS provider, voice catalog, or synthesis workflow.

This document covers:

1. the shared Oppi audio contract that any extension can target
2. the sample `voice` extension in this repository, which uses local [Yuwp](https://github.com/duh17/yuwp) TTS as one concrete implementation

For extension authors, the shared contract is in `server/src/tts-provider.ts`.

## Shared Oppi audio contract

A custom extension does not need a provider base class. It needs only to:

1. emit optional in-flight tool details with `kind: "audio_presentation"`
2. stream optional live audio with `createAudioStreamEmitter({ ui: ctx?.ui, streamId: toolCallId })`
3. return final details with `createAudioPresentationDetails({ audio, text, playbackBehavior, ... })`

Minimal shape:

```ts
import { createAudioPresentationDetails, createAudioStreamEmitter } from "../src/tts-provider.js";

onUpdate?.({
  content: [{ type: "text", text: spokenText }],
  details: {
    kind: "audio_presentation",
    text: spokenText,
    playbackBehavior: "playNow",
    provider: { id: "example-tts", model: "v1", voiceId: "warm-1" },
    status: "speaking",
  },
});

const emitAudio = createAudioStreamEmitter({
  ui: ctx?.ui,
  streamId: toolCallId,
});

emitAudio?.({
  kind: "audio-stream",
  event: "metadata",
  mimeType: "audio/pcm; codecs=s16le",
  sampleRate: 24000,
  channels: 1,
  playbackBehavior: "playNow",
});

emitAudio?.({
  kind: "audio-stream",
  event: "chunk",
  mimeType: "audio/pcm; codecs=s16le",
  chunkIndex: 0,
  audioBase64: pcmChunkBase64,
  playbackBehavior: "playNow",
});

return {
  content: [{ type: "text", text: spokenText }],
  details: createAudioPresentationDetails({
    text: spokenText,
    playbackBehavior: "playNow",
    audio: {
      kind: "audio",
      mimeType: "audio/wav",
      path: outPath,
      fileName: "reply.wav",
      sizeBytes: bytes.length,
    },
    extra: {
      provider: { id: "example-tts", model: "v1", voiceId: "warm-1" },
    },
  }),
};
```

Use `toolCallId` as the live audio stream ID. This correlation lets Oppi attach stream playback controls to the correct tool row.

## Audio playback behavior

`playbackBehavior` has two values:

- `tapToPlay` — show a playable card
- `playNow` — request immediate playback when the current session allows reply-controlled playback

Notes:

- Default missing behavior to `tapToPlay`.
- Manual mode suppresses autoplay even when a reply says `playNow`.
- Keep the contract based on local files and session attachments, rather than arbitrary remote-URL playback.

## Sample `voice` extension

The repository contains a sample `voice` extension at `server/extensions/voice.ts`. It is neither the core protocol nor an installed Pi resource. It shows one way to implement voice creation, synthesis, and playback on Oppi's generic audio contract.

### What the sample implementation adds

When an embedding host registers it or it is packaged as a Pi resource, the extension exposes these tools:

- `voice_create` — create or update a saved Yuwp voice from a VoiceDesign prompt.
- `voice_speak` — generate a spoken reply and attach the audio to the timeline.
- `voice_list` — list saved local voices.
- `voice_preferences` — set or inspect the default saved voice.

Slash commands:

```text
/voice list
/voice default <voice-id>
/voice speak <voice-id> hello from Oppi
```

### Build Yuwp TTS

```bash
git clone https://github.com/duh17/yuwp.git ~/workspace/yuwp
cd ~/workspace/yuwp
swift build -c release --product yuwp-tts
bash scripts/build_mlx_metallib.sh release
```

You also need a local Qwen3-TTS model directory or a Hugging Face snapshot.

### Option A: let Oppi start TTS

On the first `voice_*` tool use, Oppi tries to start Yuwp TTS automatically.

Default binary lookup:

```text
~/workspace/yuwp/.build/arm64-apple-macosx/release/yuwp-tts
~/workspace/yuwp/.build/debug/yuwp-tts
```

Default model lookup checks Qwen3-TTS snapshots under:

```text
~/.cache/huggingface/hub
```

If your paths differ, save them in Oppi config:

```bash
oppi config set runtimeEnv.TTS_LOCAL_BIN /path/to/yuwp-tts
oppi config set runtimeEnv.TTS_LOCAL_MODEL /path/to/qwen3-tts-model
oppi config set runtimeEnv.TTS_BASE_URL http://127.0.0.1:7937
oppi config validate
```

Then restart the Oppi server.

### Option B: run TTS yourself

```bash
cd ~/workspace/yuwp
.build/arm64-apple-macosx/release/yuwp-tts serve \
  --transport http \
  --model <qwen3-tts-model-dir> \
  --host 127.0.0.1 \
  --port 7937
```

Check it:

```bash
curl -sf http://127.0.0.1:7937/v1/info | jq .
```

If you use a non-default URL, save it in the Oppi server config:

```bash
oppi config set runtimeEnv.TTS_BASE_URL http://127.0.0.1:7937
oppi config validate
```

Then restart the Oppi server.

### Availability

The current server does not register the sample factory, and Pi's resource loader does not auto-discover `server/extensions/voice.ts`. Therefore, it does not appear in the workspace editor's extension toggles or load in sessions by default. A separately packaged Pi extension can use this implementation and the generic audio contract above.

After you install and enable such an extension, ask the agent to create or use a voice:

```text
Create a warm technical teammate voice and save it as my default.
```

or:

```text
Use voice_speak to reply as a voice message.
```

## Client playback modes

In **Settings → Voice → Voice Replies**:

- **Manual** — keep audio replies tap-to-play.
- **Agent decides** — follow each reply's playback behavior.

The agent can still change the current session's behavior with `voice_reply_mode`. For example, a user can say “keep this chat manual” or “for this session, let the agent decide.”

## Sample extension notes

- Oppi allows only local TTS URLs by default.
- To use a remote TTS URL, deliberately set `TTS_ALLOW_REMOTE=1`.
- Generated audio is saved under `~/Library/Application Support/Yuwp/Audio/pi-voice`.
- The sample source becomes loadable only after a host packages or registers it.
