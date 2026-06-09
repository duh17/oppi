# Dictation / ASR

Oppi supports two dictation paths:

1. **On-device dictation** — Apple local speech recognition on iPhone.
2. **Server dictation** — iPhone audio streams to Oppi server, and Oppi forwards it to an STT backend.

ASR is wired into Oppi server globally through `~/.config/oppi/config.json`. It is not a workspace extension.

## iOS dictation engines

In **Settings → Voice → Dictation Engine**:

- **Server** — route dictation through Oppi server and the configured STT backend.
- **On-device** — use Apple local dictation.

Older installs that still have a saved Automatic preference are migrated to Server.

## Architecture

```text
iPhone mic → WSS /dictation/stream → Oppi server → STT backend → transcript
```

Dictation uses the server-level dictation WebSocket. The stream carries JSON control messages and binary PCM audio frames.

Message flow:

1. iOS opens the server dictation stream.
2. iOS sends `dictation_start` as a text frame.
3. iOS streams PCM audio frames, 16 kHz, 16-bit mono, as binary WebSocket messages.
4. Oppi server forwards audio to the STT backend.
5. Oppi server sends incremental `dictation_result` updates.
6. iOS sends `dictation_stop`.
7. Oppi server sends `dictation_final`.

## STT backend API contract

The backend must implement this session API:

| Method   | Path                                  | Purpose                                       |
| -------- | ------------------------------------- | --------------------------------------------- |
| `POST`   | `/v1/audio/transcriptions/stream`     | Create streaming session                      |
| `POST`   | `/v1/audio/transcriptions/stream/:id` | Send audio chunk (`application/octet-stream`) |
| `DELETE` | `/v1/audio/transcriptions/stream/:id` | End session and return final text             |

Session creation body:

```json
{ "model": "<model-id>", "stream_config": { "system_prompt": "..." } }
```

`stream_config` is optional.

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

Configure Oppi server:

```bash
oppi config set asr.sttEndpoint http://127.0.0.1:7936
oppi config validate
```

Restart Oppi server, then choose **Settings → Voice → Dictation Engine → Server** in the iOS app.

## Remote ASR

`asr.sttEndpoint` can also point to a remote backend:

```json
{
  "asr": {
    "sttEndpoint": "https://asr.example.com"
  }
}
```

Notes:

- Connectivity is from **Oppi server → STT backend**, not phone → STT backend.
- Use `https://` for non-local endpoints.
- Network latency directly affects partial and final transcript latency.
- Oppi currently configures only `asr.sttEndpoint`. If your STT backend needs custom auth headers, put a reverse proxy in front of it.

## Audio retention

Oppi server does not persist dictation audio locally. If you need archival or replay fixtures, configure that in your STT backend.

## Troubleshooting

- If server dictation is unavailable, switch iOS Dictation Engine to **On-device** to verify microphone and permissions.
- Check `curl -sf <sttEndpoint>/v1/info` from the Mac running Oppi server.
- Check Oppi server logs for `dictation_error` and STT HTTP failures.
