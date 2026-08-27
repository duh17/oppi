# Dictation / ASR

Oppi provides two dictation paths:

1. **On-device dictation** — Apple local speech recognition on iPhone.
2. **Server dictation** — iPhone audio streams to Oppi server, and Oppi forwards it to an STT backend.

Server dictation has two backends: HTTP (Yuwp or any compatible streaming STT endpoint) and a Pi package `./host` export. ASR is configured globally in Oppi server through `~/.config/oppi/config.json`, not as a workspace extension.

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
5. Oppi server sends incremental `dictation_result` updates.
6. iOS sends `dictation_stop`.
7. Oppi server sends `dictation_final`.

## Choose a server STT backend

`asr.backend` is `http` or `pi-extension`. If you omit `backend` and set a non-empty `asr.sttEndpoint`, Oppi uses HTTP.

HTTP:

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

Pi extension host:

```bash
pi install @earendil-works/pi-transcribe
oppi config set asr.extension @earendil-works/pi-transcribe
oppi config set asr.backend pi-extension
oppi config validate
```

```json
{
  "asr": {
    "backend": "pi-extension",
    "extension": "@earendil-works/pi-transcribe"
  }
}
```

`asr.extension` must be a package name (`@scope/name`), an `npm:` spec, or an absolute package directory. It must not be a Node subpath or the package TUI entry. Oppi imports only that package's `./host` export from the already-installed Pi package store. It does not run `npm install` or `git clone` on serve or `/server/info`, and it does not load the TUI factory.

If `backend` is `pi-extension`, Oppi ignores `sttEndpoint` when deciding whether dictation is available. `GET /server/info` advertises `dictationStream` when HTTP has a non-empty `sttEndpoint`, or when `pi-extension` has a valid `extension` whose package directory exports `./host`. A `prepare()` failure is a fatal `dictation_error` after the client starts dictation, same as an unreachable Yuwp endpoint.

Restart the Oppi server after changing `asr`.

## STT backend API contract

The HTTP backend must implement this session API:

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

Configure the Oppi server for HTTP:

```bash
oppi config set asr.sttEndpoint http://127.0.0.1:7936
oppi config validate
```

Restart the Oppi server. Then choose **Settings → Voice → Dictation Engine → Server** in the iOS app.

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

- The connection runs from **Oppi server → STT backend**, not phone → STT backend.
- Use `https://` for non-local endpoints.
- Network latency directly affects partial and final transcript latency.
- For HTTP, Oppi configures `asr.sttEndpoint`. If your STT backend needs custom auth headers, put a reverse proxy in front of it.
- For `pi-extension`, install the package with `pi install` (or point `asr.extension` at an absolute package directory). Oppi will not install it.

## Audio retention

Oppi server does not persist dictation audio locally. Configure archival or replay fixtures in your STT backend.

## Troubleshooting

- If server dictation is unavailable, switch the iOS Dictation Engine to **On-device** to verify the microphone and permissions.
- Run `curl -sf <sttEndpoint>/v1/info` from the Mac that runs Oppi server.
- Check Oppi server logs for `dictation_error` and STT HTTP failures.
