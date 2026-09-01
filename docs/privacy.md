# Privacy Policy

_Last updated: 2026-08-17_

This policy describes the current Oppi Apple client and the Oppi server that you run yourself. Oppi is a native client for a paired, self-hosted Oppi server. That server runs Pi through its SDK; Pi does not ship a server mode. Oppi does not provide a hosted Oppi account service, a central session store, or an Oppi-operated external analytics service. Pi may collect its own install or update telemetry outside this policy; see Pi's documentation for that behavior.

You choose the server, workspace, model providers, speech-to-text service, and text-to-speech service. Those choices determine where your content goes and how long it remains there. Check the Pi version and configuration used by your server.

## The short version

- Pairing credentials and connection preferences stay on your Apple device. Server credentials are stored in the iOS Keychain.
- Prompts, session history, workspace metadata, tool results, and attachments can be stored by the paired server and by Pi in the server's configured data and workspace locations.
- A selected photo or file is read by the app and uploaded to the paired server with the session turn. The app does not collect photos or files in the background.
- Dictation can use Apple's on-device speech APIs or audio sent through the paired server to its configured speech-to-text backend.
- Model, speech, and voice providers can receive the content needed for the operation you choose. Their privacy policies and retention rules apply.
- Public builds upload diagnostics only after you enable **Settings → Privacy & Security → Send Diagnostics to Server**. Diagnostics go to your paired server, not to a hosted Oppi service.
- Remote connections use authenticated HTTPS/WSS, including LAN and Tailscale HTTPS. The network path can see ordinary connection metadata such as IP addresses, hostnames, timing, and traffic volume.
- Removing a server from the app removes its local pairing credential. It does not delete the server, workspace files, session history, provider data, or backups.

## Data locations and control boundaries

Oppi has two important storage boundaries:

1. **The Apple device.** The app stores pairing state, preferences, caches, and bounded diagnostic context in its sandbox and Keychain.
2. **The paired server and services it contacts.** The server stores session and workspace state and can send prompts, attachments, and generated content to the providers you configure.

The person who operates the paired server controls its filesystem, backups, server configuration, Pi session files, workspace directories, provider credentials, and diagnostics. Oppi cannot delete data held by a model provider, speech or voice backend, network provider, operating-system backup, or another server operator.

## Information you choose to use with Oppi

Oppi can process the following when you use the corresponding feature:

- Prompts, replies, tool calls, tool output, approval responses, and session metadata.
- Files selected through the Files picker and files referenced from a paired workspace.
- Photos selected from the photo library, images captured with the camera, and images shared through the Share extension.
- Microphone audio while dictation is active.
- Model-provider credentials that you enter or authorize through the paired server's provider setup.
- Optional voice-reply text and audio produced by a server-side voice extension.

Oppi does not need photo, camera, or microphone access to pair with a server or display existing sessions. iOS permission prompts control those features.

## What stays on the Apple device

### Pairing and Keychain state

The app stores each paired server as a Keychain item in the shared App Group. The stored record includes the HTTPS host and port, server identity fingerprint, TLS certificate pin when present, and the current device credential: a server-issued device ID, short-lived access token, expiry, and refresh challenge. A separate Keychain item holds the device's P-256 signing key. On supported hardware that key stays in the Secure Enclave; otherwise it is Keychain-sealed. The signing key is not written into the paired-server record. Keychain items use `WhenUnlockedThisDeviceOnly` protection. Older `dt_` pairings can remain until they migrate to this device-key HTTPS credential.

The app keeps a small server-ID index in shared and standard `UserDefaults` so the app and its extensions can find paired servers. Removing a server from the app deletes its server Keychain item and removes it from the local server list. It does not remove data from that server.

### Preferences and caches

Settings such as appearance, text size, voice mode, auto-title mode, haptics, diagnostics consent, quick-session choices, and the last keyboard language are device-local preferences. A bounded diagnostic context can also keep coarse values such as a session, workspace, or server identifier, screen, lifecycle state, and resource measurements for a later diagnostic payload.

The app caches server responses under `Library/Caches/`. The timeline cache contains plaintext JSON copies of session traces, session lists, workspaces, Skills, and Skill details. It is sandbox-private, excluded from backup, protected by iOS file protection, and intentionally disposable. The current timeline-cache defaults are a 256 MB disk budget and a 30-day trace age; iOS can evict cache data sooner. The file-browser index is a separate cache that iOS can also evict.

**Settings → Storage → Clear Local Cache** clears the timeline cache. It does not delete the paired server, server workspaces, Pi session files, provider data, or backups. Removing the app is a device-level control and does not delete server-side data.

## Paired-server storage

The server's data directory defaults to `~/.config/oppi/` and can be changed with `OPPI_DATA_DIR` or the server's `--data-dir` option. It can contain, among other things:

- `config.json`, authentication state, server identity material, and transport configuration.
- SQLite session state, workspace records, saved Agents, schedules, resource settings, and search indexes.
- Pi session JSONL files referenced by Oppi sessions and local-session imports.
- Workspace files and files created or changed by server-side tools.
- Session attachment copies under the workspace's `.pi/attachments/` directory.
- Generated media under the server's `session-attachments/` directory.
- Upload records and blobs under the configured upload-store directory.
- Optional diagnostics under `diagnostics/telemetry/`.

Oppi server-side tools run on the paired server. A server-side tool can read or change workspace files according to the server and Pi permission policy. The Apple app renders the result; it does not execute those tools on iOS.

### Session and workspace deletion

Deleting a session from the app asks the server to stop it and remove the Oppi session metadata, search-index entry, referenced local Pi session JSONL files, generated media attachments, and session-scoped copies in the workspace attachment directory. It does not undo changes that an agent made to ordinary workspace files. It does not delete data already sent to a model, speech, or voice provider, or data in backups.

Deleting a workspace removes the Oppi workspace record. It does not remove the host directory or the files in that directory.

Uploaded chat attachments use a separate local upload store. The default unused and retained upload TTLs are 24 hours and can be changed by the server operator. The current server marks a consumed upload as used and keeps its staged record/blob available to the upload-store garbage collector; session deletion does not remove that separate staged blob. The server operator controls this directory and any manual cleanup.

These are implementation boundaries, not promises that every copy disappears at the same instant. Filesystem snapshots, backups, Pi session paths, and provider-side copies follow their own controls.

## Prompts, files, and photos

A prompt is sent over the authenticated connection to the server you paired. The server can store it in session history and pass it to Pi and the selected model provider.

When you select a photo or local file, the app holds the selected bytes while preparing the turn. Before the turn is sent, it creates an upload on the paired server. The server validates the upload, stores it in the upload store, and copies it into the session's workspace attachment directory when Pi materializes the turn. Images can also be passed to the selected model as image input. A photo or file that you cancel before sending is not uploaded by the composer path.

The Share extension temporarily stages shared files in the app's shared container until the quick-session handoff succeeds or is cancelled. Staged files are removed by the success and cancellation paths. The source app controls any copy it retains.

Saving an image to the photo library is a separate, explicit action. Oppi does not read the photo library or camera continuously.

## Model providers and server extensions

Oppi does not operate a hosted model service. The paired server uses Pi's configured providers and credentials. The Model Providers screen sends API-key entry to the paired server over the existing Oppi connection and the server saves the credential through its provider runtime. OAuth flows can open a provider authorization page in a browser and can ask for user input.

Depending on your settings and session, Pi or a provider can receive prompt text, conversation context, tool results, selected files, images, and other content needed to generate a response. A provider can process or retain that content under its own terms. Check the provider's current privacy policy before sending sensitive content.

Automatic session titles can be generated by the server, generated on-device, or disabled. The on-device option uses Apple's local Foundation model path. Server-generated titles follow the same server/provider boundary as other model calls.

Server-side Skills, Extensions, tools, and voice features run on the paired server. The iOS app does not download or execute server extension code as iOS code. A voice extension can send text to the text-to-speech service configured by the server and store the resulting audio as a session attachment.

## Dictation and voice

In **Settings → Voice → Dictation Engine**, you can choose **On-device** or **Server**.

### On-device dictation

On-device dictation captures microphone audio for Apple's on-device Speech or Dictation transcriber. The app receives the transcript locally and places it in the composer. The audio is not sent to the Oppi server by this path. If you submit the resulting prompt, the prompt follows the normal paired-server and model-provider flow.

Apple can manage installation of the speech assets used by its APIs. Apple's own terms and privacy information apply to those system services.

### Server dictation

Server dictation streams 16 kHz, 16-bit mono PCM audio from the iPhone to the paired server. The server forwards audio to the speech-to-text endpoint configured in `asr.sttEndpoint` and sends incremental and final transcript results back to the app. The Oppi server does not persist dictation audio locally. The configured speech-to-text backend can receive the audio and transcript and controls its own retention.

The endpoint can be local to the server host or remote. For a remote endpoint, the server operator is responsible for its transport security, credentials, processing, and retention.

Voice replies are generated by the paired server and its configured extensions/providers. Generated audio can be streamed to the app or stored as a session attachment for later playback.

## Network metadata

After pairing, Oppi uses authenticated HTTPS/WSS. Automatic routing evaluates verified LAN HTTPS and paired HTTPS; Tailscale HTTPS is supported. The local CLI stays on an owner-only Unix socket.

The network path, DNS resolver, and any TLS terminator you configure can observe ordinary connection metadata: IP addresses, hostnames, SNI, timing, duration, and approximate traffic volume. Pairing invites, access tokens, and HTTP/WebSocket requests remain subject to the configured transport and authentication settings. See [SECURITY.md](../SECURITY.md) and [Onboarding](onboarding.md).

## Optional diagnostics

Public release builds do not upload Oppi diagnostics until you enable **Settings → Privacy & Security → Send Diagnostics to Server**. The destination is the currently configured paired Oppi server. Oppi does not link an external crash-reporting service in public iOS builds.

Diagnostics can include bounded MetricKit summaries, crash/hang/CPU/disk/app-launch information, app and OS/build details, resource samples, connection and lifecycle outcomes, low-cardinality session/workspace/app-instance identifiers, and redacted client logs. The telemetry contract excludes prompt text, assistant output, tool arguments, command output, dictation transcript text, relay URLs and hosts, IP addresses, tokens, tickets, node IDs, endpoint IDs, secrets, credentials, raw URLs, and local file paths.

The paired server's default diagnostic retention is:

| Diagnostic data | Default retention | Operator override |
| --- | ---: | --- |
| MetricKit payloads | 14 days | `OPPI_METRICKIT_RETENTION_DAYS` |
| Chat metrics | 14 days | `OPPI_CHAT_METRICS_RETENTION_DAYS` |
| Client logs | 14 days | `OPPI_CHAT_METRICS_RETENTION_DAYS` |
| Server resource metrics | 30 days | `OPPI_SERVER_METRICS_RETENTION_DAYS` |
| Server operations metrics | 30 days | `OPPI_SERVER_OPS_METRICS_RETENTION_DAYS` |

The server operator can change these values, stop accepting uploads through telemetry mode, delete diagnostic files, or retain backups. Development and internal builds can have different diagnostic defaults; the public-build opt-in is the App Store behavior.

Contributor diagnostics policy, storage paths, and review commands live in the in-repo telemetry guide, not in this public user set.

## Choices and consent

You control whether to:

- Pair a server and keep or remove its device credential.
- Choose on-device or server dictation.
- Select, send, or cancel a prompt attachment.
- Connect or disconnect a model-provider credential on the paired server.
- Enable or disable public-build diagnostics upload.
- Delete sessions and clear the local timeline cache.
- Configure or disable speech-to-text, text-to-speech, and model providers on the server.

Turning off diagnostics stops new diagnostic uploads and clears the client-side diagnostic upload queues. It cannot recall diagnostics already received by the paired server. Changing dictation or provider settings does not delete content already sent to an earlier backend.

## Contact and reporting

Oppi has no hosted account or central data-request system. For data held by a paired server, contact the person who operates that server or use its local filesystem and provider controls.

For product support, privacy questions, and deletion help, email [duh@chaosdonkey.dev](mailto:duh@chaosdonkey.dev) or use the [Oppi Support page](support.md). For security reports, read [SECURITY.md](../SECURITY.md). Send sensitive details by email, not through a public issue.

## Changes to this policy

This page is versioned with the repository. The current code, server configuration, provider, network, and platform behavior control the facts described here. When those boundaries change, this page must be reviewed with the release.
