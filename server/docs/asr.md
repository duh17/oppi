# Dictation / ASR

Oppi provides two dictation paths:

1. **On-device dictation** — Apple local speech recognition on iPhone.
2. **Server dictation** — iPhone audio streams to Oppi server, and Oppi forwards it to the configured STT backend ([Yuwp](https://github.com/duh17/yuwp), OpenAI, or xAI/Grok).

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
5. Oppi server sends incremental `dictation_result` updates when the vendor supports live partials (Yuwp, xAI). OpenAI does not; nothing is faked while you speak.
6. iOS sends `dictation_stop`.
7. Oppi server sends `dictation_final`.

## Choose a server STT backend

Set `asr.provider` to `openai-codex` or `xai`, or set a non-empty `asr.sttEndpoint`, to enable server dictation. Unset those keys to turn it off. Leftover `asr.backend: pi-extension` and `asr.extension` values are ignored on load. Yuwp remains the local streaming backend; OpenAI and xAI are additive vendors.

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

`GET /server/info` advertises `dictationStream` when `asr.provider` is `openai-codex` or `xai`, or when `asr.sttEndpoint` is non-empty. An unreachable Yuwp endpoint is a fatal `dictation_error` after the client starts dictation. Missing OpenAI/xAI credentials fail at start the same way.

Restart the Oppi server after changing `asr`.

## Yuwp / HTTP session API contract

A Yuwp-compatible HTTP backend must implement this session API. OpenAI and xAI use their own official APIs instead of this contract.

| Method   | Path                                  | Purpose                                       |
| -------- | ------------------------------------- | --------------------------------------------- |
| `POST`   | `/v1/audio/transcriptions/stream`     | Create streaming session                      |
| `POST`   | `/v1/audio/transcriptions/stream/:id` | Send audio chunk (`application/octet-stream`) |
| `DELETE` | `/v1/audio/transcriptions/stream/:id` | End session and return final text             |

Session creation body:

```json
{ "model": "<model-id>", "stream_config": { "contextual_strings": ["Foo Bar", "Yuwp"] } }
```

`stream_config` is optional. Omit it when the take has no vocabulary hints. Apple clients currently send no `contextual_strings`; the field stays on `dictation_start` for a future vocabulary source. Do not send conversation text through it. Reintroduce an explicit Server opt-in if phrases leave the device. `contextual_strings` is a bounded phrase list (max 100 phrases, 256 UTF-8 bytes each, 8192 UTF-8 bytes total). It is vocabulary data, not a client-supplied system prompt. The backend must still accept a create body with no `stream_config`.

Create response:

```json
{ "session_id": "<id>", "context_applied": true }
```

`context_applied` is optional. `true` means the backend consumed that take's hints. It is not a recognition-accuracy guarantee. Missing or `false` still allows ordinary audio dictation.

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

`asr.sttEndpoint` can point at a remote Yuwp-compatible session API, or `asr.provider` can select OpenAI or xAI. Audio is always **Oppi server → STT backend**, never phone → vendor.

### Yuwp-compatible HTTP session API

```json
{
  "asr": {
    "sttEndpoint": "https://asr.example.com"
  }
}
```

Use `https://` for non-local endpoints. Network latency directly affects partial and final transcript latency. If that backend needs custom auth headers, put a reverse proxy in front of it.

### OpenAI (provider id `openai-codex`)

Official API: [`POST /v1/audio/transcriptions`](https://platform.openai.com/docs/api-reference/audio/createTranscription) ([OpenAPI spec](https://github.com/openai/openai-openapi)). File upload of 16 kHz 16-bit mono PCM wrapped as WAV. Optional `stream=true` only streams the transcript **after** the whole file is uploaded; Oppi does **not** emit live `dictation_result` ticks for OpenAI. The transcript arrives as `dictation_final` after `dictation_stop`.

Auth reuses existing Pi/Oppi provider auth for `openai-codex` — the same `ModelRuntime.getAuth` path as the ChatGPT Codex LLM provider (`pi auth` / Settings login). If that bearer is missing, Oppi falls back to the `openai` API-key credential or `OPENAI_API_KEY`. Vocabulary is sent as the documented `prompt` field.

```bash
oppi config set asr.provider openai-codex
oppi config set asr.sttModel gpt-4o-mini-transcribe
oppi config validate
```

```json
{
  "asr": {
    "provider": "openai-codex",
    "sttModel": "gpt-4o-mini-transcribe"
  }
}
```

Optional `asr.sttEndpoint` overrides the default `https://api.openai.com` (base URL, not the full transcriptions path).

### xAI / Grok

Official APIs: [Speech to Text](https://docs.x.ai/developers/model-capabilities/audio/speech-to-text) ([REST `/v1/stt` and WebSocket `wss://api.x.ai/v1/stt`](https://docs.x.ai/developers/rest-api-reference/inference/voice#speech-to-text---streaming); announcement: [Grok STT and TTS APIs](https://x.ai/news/grok-stt-and-tts-apis)). Oppi uses the WebSocket API with `encoding=pcm`, `sample_rate=16000`, and `interim_results=true`, so live `dictation_result` ticks are real partials. xAI `transcript.partial` text is the current chunk or utterance (`is_final` / `speech_final`), not the whole take, so the provider accumulates those events into the full visible transcript before forwarding. This is **not** OpenAI's `/v1/audio/transcriptions` path.

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
- OpenAI/xAI: confirm Pi/Oppi provider auth for `openai-codex` or `xai`, or `OPENAI_API_KEY` / `XAI_API_KEY` on the Oppi server host.
- Check Oppi server logs for `dictation_error` and STT HTTP failures.
