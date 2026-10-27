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

1. Oppi sends `session.update` with `session.type: "transcription"`, `audio.input.format: { "type": "audio/pcm", "rate": 16000 }` and `turn_detection: { "type": "server_vad", "silence_duration_ms": 2000 }`, then waits up to 10 s for `session.updated`. Yuwp accepts 16 kHz or 24 kHz PCM, so the phone's 16 kHz audio goes out as is. When the Dictation Dictionary has phrases for the call's session (its workspace list first, then the global list, as dictation selects them), the update also carries `audio.input.transcription.prompt: "Vocabulary: <phrase>, <phrase>, …"`, the same system context Yuwp builds from dictation's `contextual_strings`. Phrases that would push the prompt past Yuwp's 8192-byte limit are left out, last first. The server reads the dictionary at each call's start; there is no per-device consent, since the call already streams all its audio to the same endpoint. A dictionary that cannot be read logs `voice_media.vocabulary_unavailable` and the call starts without hints.
2. Oppi sends the call's audio as `input_audio_buffer.append` (base64 PCM16 mono) until the call ends.
3. Yuwp's VAD ends each turn after the pause. It sends `input_audio_buffer.speech_started`, then `input_audio_buffer.committed` (`item_id`) and `conversation.item.input_audio_transcription.completed` (`transcript`, punctuated final text). `…delta` events carry the stable text while an item is still being heard and only feed the live caption. `…failed` is an empty item.
4. Items are ordered by commit; Oppi hands turns to the session in that order, even when a later transcript finishes first.
5. At the end of the call Oppi sends `input_audio_buffer.commit` to cut what the VAD had not, waits for the items in flight, and closes the socket.
6. Oppi pings the socket every 60 s (Yuwp closes one that receives nothing for 15 minutes). When the phone stops sending audio while an item is open (mute, hold), Yuwp's VAD cannot see the pause, so after `silence_duration_ms` without a frame Oppi sends one `input_audio_buffer.commit` for that item; `input_audio_buffer_commit_empty` in answer means it had already ended.

Oppi has no silence timers of its own for Live Voice: the pause that ends a turn is `silence_duration_ms` in Yuwp's VAD. A Yuwp without `/v1/realtime`, or one that refuses the session, fails the call's start; a socket that closes or errors mid-call ends the call.

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
