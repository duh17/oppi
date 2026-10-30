# Dictation / ASR

Oppi provides two dictation paths:

1. **On-device dictation** — Apple local speech recognition on iPhone.
2. **Server dictation** — iPhone audio streams to Oppi server, and Oppi forwards it to the configured STT backend ([Yuwp](https://github.com/duh17/yuwp) or xAI/Grok).

ASR is configured globally in Oppi server through `~/.config/oppi/config.json`, not as a workspace extension.

## iOS dictation engines

In **Settings → Voice → Dictation Engine**:

- **Server** — route dictation through Oppi server and the configured STT backend.
- **On-device** — use Apple local dictation.

Older installs with a saved Automatic preference migrate to Server.

## Architecture

```text
iPhone mic → WSS /dictation/stream → Oppi server → STT backend → transcript
```

Dictation uses the server-level dictation WebSocket, which carries JSON control messages and binary PCM audio frames.

Message flow:

1. iOS opens the server dictation stream.
2. iOS sends `dictation_start` as a text frame.
3. iOS streams PCM audio frames, 16 kHz, 16-bit mono, as binary WebSocket messages.
4. Oppi server forwards audio to the STT backend.
5. Oppi server sends incremental `dictation_result` updates from Yuwp or xAI.
6. iOS sends `dictation_stop`.
7. Oppi server sends `dictation_final`.

## Choose a server STT backend

Set `asr.provider` to `xai`, or set a non-empty Yuwp-compatible `asr.sttEndpoint`, to enable server dictation. Unset those keys to turn it off. Leftover `asr.backend: pi-extension` and `asr.extension` values are ignored on load.

OpenAI batch dictation is not supported. `asr.provider: openai` and `openai-codex` fail config validation and disable dictation on startup, including when an endpoint is set. Replace the ASR configuration with Yuwp/http or xAI. Codex model access, login, and quotas are unchanged.

```bash
oppi config set asr.sttEndpoint http://127.0.0.1:7936
oppi config validate
```

```json
{
  "asr": {
    "sttEndpoint": "http://127.0.0.1:7936"
  }
}
```

`GET /server/info` advertises `dictationStream` only while dictation is `ready`: `asr.provider` is `xai` with an xAI credential, or a non-empty HTTP `asr.sttEndpoint` answers the server's reachability probe. Otherwise the app records on-device. See [Voice backend health](../../docs/server-configuration.md#voice-backend-health). An endpoint that goes down between probes is a fatal `dictation_error` after the client starts dictation.

Restart the Oppi server after changing `asr`.

## Yuwp / HTTP session API contract

A Yuwp-compatible HTTP backend must implement this session API. xAI uses its own streaming API instead of this contract.

| Method   | Path                                  | Purpose                                       |
| -------- | ------------------------------------- | --------------------------------------------- |
| `POST`   | `/v1/audio/transcriptions/stream`     | Create streaming session                      |
| `POST`   | `/v1/audio/transcriptions/stream/:id` | Send audio chunk (`application/octet-stream`) |
| `DELETE` | `/v1/audio/transcriptions/stream/:id` | End session and return final text             |

Session creation body:

```json
{ "model": "<model-id>", "stream_config": { "contextual_strings": ["Foo Bar", "Yuwp"] } }
```

`stream_config` is optional. Omit it when the take has no vocabulary hints. Apple clients select phrases from the paired server's global and workspace Dictation Dictionary lists. On-device dictation can use those hints locally; server dictation sends selected phrases on `dictation_start` only after a separate, default-off iPhone consent for the paired server and configured provider. Do not send conversation text through it. `contextual_strings` is a bounded phrase list (max 100 phrases, 256 UTF-8 bytes each, 8192 UTF-8 bytes total). It is vocabulary data, not a client-supplied system prompt. The backend must still accept a create body with no `stream_config`.

Create response:

```json
{ "session_id": "<id>", "context_applied": true }
```

`context_applied` is optional. `true` means the backend consumed that take's hints. It is not a recognition-accuracy guarantee. Missing or `false` still allows ordinary audio dictation.

## Live Voice (Yuwp realtime transcription)

Local Live Voice (`asr.liveVoiceBackend: yuwp`) does not use the HTTP session API above. Each call opens one WebSocket to `{asr.sttEndpoint}/v1/realtime?intent=transcription` (`http` becomes `ws`, `https` becomes `wss`), Yuwp's OpenAI Realtime transcription session:

1. Oppi sends `session.update` with `session.type: "transcription"`, `audio.input.format: { "type": "audio/pcm", "rate": 16000 }` and `turn_detection: { "type": "semantic_vad", "eagerness": "auto", "silence_duration_ms": 2000 }`, then waits up to 10 s for `session.updated`. Yuwp's `semantic_vad` scores each pause with Smart Turn: a pause that sounds finished commits after about 1 s, one that sounds mid-thought waits longer, up to 4 s (`auto` = `medium`). It ignores `silence_duration_ms`; a Yuwp from before `semantic_vad` reads the update as `server_vad`, and the field keeps that Yuwp's pause at 2 s instead of its 500 ms default. The `realtime_transcription.session_ready` log line records which one Yuwp applied (`turnDetection`). Yuwp accepts 16 kHz or 24 kHz PCM, so the phone's 16 kHz audio goes out as is. When the Dictation Dictionary has phrases for the call's session (its workspace list first, then the global list, as dictation selects them), the update also carries `audio.input.transcription.prompt: "Vocabulary: <phrase>, <phrase>, …"`, the same system context Yuwp builds from dictation's `contextual_strings`. Phrases that would push the prompt past Yuwp's 8192-byte limit are left out, last first. The server reads the dictionary at each call's start; there is no per-device consent, since the call already streams all its audio to the same endpoint. A dictionary that cannot be read logs `voice_media.vocabulary_unavailable` and the call starts without hints.
2. Oppi sends the call's audio as `input_audio_buffer.append` (base64 PCM16 mono) until the call ends.
3. Yuwp's VAD ends each turn after the pause. It sends `input_audio_buffer.speech_started`, then `input_audio_buffer.committed` (`item_id`) and `conversation.item.input_audio_transcription.completed` (`transcript`, punctuated final text). `…delta` events carry the stable text while an item is still being heard and only feed the live caption. `…failed` is an empty item.
4. Items are ordered by commit; Oppi hands turns to the session in that order, even when a later transcript finishes first.
5. At the end of the call Oppi sends `input_audio_buffer.commit` to cut what the VAD had not, waits for the items in flight, and closes the socket.
6. Oppi pings the socket every 60 s (Yuwp closes one that receives nothing for 15 minutes). When the phone stops sending audio while an item is open (mute, hold), Yuwp's VAD cannot see the pause, so after `silence_duration_ms` without a frame Oppi sends one `input_audio_buffer.commit` for that item; `input_audio_buffer_commit_empty` in answer means it had already ended.

Oppi has no silence timers of its own for Yuwp Live Voice: Yuwp's turn detection decides when a turn ends. A Yuwp without `/v1/realtime`, or one that refuses the session, fails the call's start; a socket that closes or errors mid-call ends the call.

## Live Voice (OpenRouter)

`asr.liveVoiceBackend: openrouter` runs Live Voice on a server whose only credential is an OpenRouter API key: the key models use, stored through **Model Providers** or set as `OPENROUTER_API_KEY`. It ignores `asr.sttEndpoint` and `tts`. OpenRouter offers speech only as plain HTTP requests: [`POST /api/v1/audio/transcriptions`](https://openrouter.ai/docs/api/api-reference/stt/create-transcription.md) "transcribes audio into text" from a whole clip, and [`POST /api/v1/audio/speech`](https://openrouter.ai/docs/api/api-reference/tts/create-speech.md) "returns a raw audio bytestream in the requested format". Its docs list no realtime or streaming transcription, so the Oppi server does the turn-taking:

1. The call fails to start without an OpenRouter credential. `voiceBackends` reads `needs_credentials` then, and the app does not offer Live Voice.
2. The server measures the level of each 20 ms of the phone's 16 kHz audio against a running noise floor. 200 ms of continuous speech opens an utterance, with 400 ms of audio from before it. Clicks and quiet room noise do not.
3. A 2-second pause ends the utterance (`LIVE_VOICE_TURN_SILENCE_MS`, the same pause a Yuwp without `semantic_vad` uses). So does 30 seconds of continuous speech (`max_duration`), when the phone stops sending audio for 2 seconds (mute, hold: `audio_stalled`), or when the call ends (`call_stop`).
4. Each utterance goes to OpenRouter as one WAV (`input_audio.format: "wav"`) with model `openai/whisper-large-v3-turbo`, which Groq and DeepInfra serve. The returned `text` goes to the session as one message. Turns go to the session in the order spoken, even when a later transcription finishes first. A failed request (HTTP error, 30 s timeout) logs `openrouter_live_voice.transcription_failed` with OpenRouter's error message, and that utterance is dropped. The call goes on.
5. The agent's reply is spoken sentence by sentence, as with Yuwp. Each sentence is one `/audio/speech` request: model `microsoft/mai-voice-2.1-flash`, voice `en-US-Harper:MAI-Voice-2.1-Flash`, `response_format: "pcm"`. OpenRouter's [TTS guide](https://openrouter.ai/docs/guides/overview/multimodal/tts.md) documents Azure MAI-Voice `pcm` as 24 kHz mono, the phone's playback format, so the audio streams to the phone as it arrives. Talking over the agent stops it, the same as on Yuwp.

Limits:

- **Latency.** A reply cannot start until the 2-second pause, one transcription request, the agent's first sentence, and one speech request have all finished. A mid-sentence pause of 2 seconds or more splits what you say into two messages.
- **No live captions.** The input bar shows nothing while you talk. The words appear only after the utterance is transcribed.
- **Energy detection.** Steady background noise that is loud enough to count as speech can hold an utterance open until the 30-second cap, and Whisper may then turn the noise into words. Use the call somewhere quiet.
- **Fixed models and voice.** The model ids and the voice are constants in `server/src/openrouter-live-voice.ts`. The speech model must return 24 kHz PCM; OpenRouter does not document other models' PCM rates. If OpenRouter retires a model, calls go silent or drop every utterance until the constant is changed. The `tts_failed` and `transcription_failed` log lines show OpenRouter's reason.
- **No Dictation Dictionary.** Phrases are not sent. OpenRouter's `keyterms` field returns a 400 on models that do not support it.
- **Health is credential-only**, as with xAI. A revoked key or an empty credit balance still reads `ready` until a request fails.
- **Cost.** About $0.012 per hour of speech for Whisper and $15 per million characters spoken (OpenRouter's listed prices on 2026-10-30), plus the agent's model.

## Local Yuwp ASR setup

Build Yuwp:

```bash
git clone https://github.com/duh17/yuwp.git ~/workspace/yuwp
cd ~/workspace/yuwp
swift build -c release --product yuwp-asr
bash scripts/build_mlx_metallib.sh release
```

Start the ASR server:

```bash
cd ~/workspace/yuwp
.build/arm64-apple-macosx/release/yuwp-asr serve \
  --model <asr-model-dir> \
  --transport http \
  --host 127.0.0.1 \
  --port 7936
```

Check it:

```bash
curl -sf http://127.0.0.1:7936/v1/info | jq .
```

Configure the Oppi server for HTTP:

```bash
oppi config set asr.sttEndpoint http://127.0.0.1:7936
oppi config validate
```

Restart the Oppi server. Then choose **Settings → Voice → Dictation Engine → Server** in the iOS app.

## Remote ASR

`asr.sttEndpoint` can point at a remote Yuwp-compatible session API, or `asr.provider` can select xAI. Audio is always **Oppi server → STT backend**, never phone → vendor.

### Yuwp-compatible HTTP session API

```json
{
  "asr": {
    "sttEndpoint": "https://asr.example.com"
  }
}
```

Use `https://` for non-local endpoints. Network latency directly affects partial and final transcript latency. If that backend needs custom auth headers, put a reverse proxy in front of it.

### xAI / Grok

Official APIs: [Speech to Text](https://docs.x.ai/developers/model-capabilities/audio/speech-to-text) ([REST `/v1/stt` and WebSocket `wss://api.x.ai/v1/stt`](https://docs.x.ai/developers/rest-api-reference/inference/voice#speech-to-text---streaming); announcement: [Grok STT and TTS APIs](https://x.ai/news/grok-stt-and-tts-apis)). Oppi uses the WebSocket API with `encoding=pcm`, `sample_rate=16000`, and `interim_results=true`, so live `dictation_result` ticks are real partials. xAI `transcript.partial` text is the current chunk or utterance (`is_final` / `speech_final`), not the whole take, so the provider accumulates those events into the full visible transcript before forwarding. A non-empty `transcript.done` text is the authoritative full transcript and replaces all accumulated partials, including earlier wording. Empty or missing final text retains the last partial transcript.

Auth reuses existing Pi/Oppi provider auth for `xai` — API key or SuperGrok/X OAuth access token via `getAuth` (same credentials as Grok chat), then `XAI_API_KEY`. Vocabulary is sent as documented `keyterm` query parameters (max 100 terms, 50 characters each; longer Oppi phrases are dropped).

```bash
oppi config set asr.provider xai
oppi config validate
```

```json
{
  "asr": {
    "provider": "xai"
  }
}
```

Optional `asr.sttEndpoint` overrides the default `https://api.x.ai`. Proxies must support the WebSocket STT API to keep live partials.

## Audio retention

Oppi server does not persist dictation audio locally. Configure archival or replay fixtures in your STT backend.

## Troubleshooting

- If server dictation is unavailable, switch the iOS Dictation Engine to **On-device** to verify the microphone and permissions.
- For Yuwp, run `curl -sf <sttEndpoint>/v1/info` from the Mac that runs Oppi server.
- For xAI, confirm Pi/Oppi provider auth for `xai`, or `XAI_API_KEY` on the Oppi server host.
- Check Oppi server logs for `dictation_error` and STT HTTP failures.
