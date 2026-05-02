# Voice replies / TTS

Oppi TTS is exposed through the **`voice` workspace extension**. It is not wired into the server globally like ASR.

The voice extension uses local [Yuwp](https://github.com/duh17/yuwp) TTS to generate WAV audio for agent replies. The iOS app can render those replies as playable voice-message cards or direct playback when allowed.

## What the voice extension adds

Enable `voice` on a workspace to expose these tools:

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

## Build Yuwp TTS

```bash
git clone https://github.com/duh17/yuwp.git ~/workspace/yuwp
cd ~/workspace/yuwp
swift build -c release --product yuwp-tts
bash scripts/build_mlx_metallib.sh release
```

You also need a local Qwen3-TTS model directory or Hugging Face snapshot.

## Option A: let Oppi start TTS

On first `voice_*` tool use, Oppi tries to start Yuwp TTS automatically.

Default binary lookup:

```text
~/workspace/yuwp/.build/arm64-apple-macosx/release/yuwp-tts
~/workspace/yuwp/.build/debug/yuwp-tts
```

Default model lookup checks Qwen3-TTS snapshots under:

```text
~/.cache/huggingface/hub
```

If your paths are different, set these before starting Oppi server:

```bash
export PI_VOICE_TTS_BIN=/path/to/yuwp-tts
export PI_VOICE_MODEL=/path/to/qwen3-tts-model
export PI_VOICE_TTS_URL=http://127.0.0.1:7937
```

Then restart Oppi server.

## Option B: run TTS yourself

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

If you use a non-default URL, set it for Oppi server:

```bash
export PI_VOICE_TTS_URL=http://127.0.0.1:7937
```

Then restart Oppi server.

## Enable the workspace extension

In the workspace extension list, enable:

```text
voice
```

After that, ask the agent to create or use a voice. Example:

```text
Create a warm technical teammate voice and save it as my default.
```

or:

```text
Use voice_speak to reply as a voice message.
```

## iOS playback modes

In **Settings → Voice → Voice Replies**:

- **Voice** — autoplay only when the agent explicitly requests direct playback.
- **Voice message** — never autoplay; render a playable voice card.
- **Direct speak** — autoplay all voice replies immediately when allowed.

## Notes

- Oppi only allows local TTS URLs by default.
- To use a remote TTS URL, set `PI_VOICE_ALLOW_REMOTE=1` deliberately.
- Generated audio is saved under `~/Library/Application Support/Yuwp/Audio/pi-voice`.
- TTS setup is per workspace because it is provided by the `voice` extension.
