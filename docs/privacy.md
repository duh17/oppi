# Privacy Policy

_Last updated: 2026-10-22_

This policy describes the current Oppi Apple client and the Oppi server that you run yourself. Oppi is a native client for a paired, self-hosted Oppi server. That server runs Pi through its SDK; Pi does not ship a server mode. Oppi provides no hosted account service, central session store, or Oppi-operated external analytics service. Its only hosted service is the optional push relay described under [Push notifications](#push-notifications). Pi may collect its own install or update telemetry outside this policy; see Pi's documentation.

You choose the server, workspace, model providers, speech-to-text service, and text-to-speech service. Those choices decide where your content goes and how long it stays there. Check the Pi version and configuration your server uses.

## The short version

- Pairing credentials and connection preferences stay on your Apple device. Server credentials are in the iOS Keychain.
- Prompts, session history, workspace metadata, tool results, and attachments can be stored by the paired server and by Pi in the server's data and workspace locations.
- A selected photo or file is read by the app and uploaded to the paired server with the session turn. The app does not collect photos or files in the background.
- Dictation uses Apple's on-device speech by default. If you choose **Server** in Settings, dictation audio goes through the paired server to its configured speech-to-text backend.
- Live Voice (an experiment, off by default) streams your voice during a call through the paired server to the voice backend the server sets: speech services the server operator chooses, or xAI's Grok Voice, which also receives the text of what the agent says aloud. See [Live Voice](#live-voice).
- Model, speech, and voice providers can receive the content needed for the operation you choose. Their privacy policies and retention rules apply.
- Public builds upload diagnostics only after you enable **Settings → Privacy & Security → Send Diagnostics**, and they go to your paired server, not a hosted Oppi service.
- Push notifications and Live Activities are off until you turn them on for a server, and a server operator can turn push off for that server. When on, alert content is encrypted on your server to a key only your device holds; a push relay and Apple carry it without being able to read it. See [Push notifications](#push-notifications).
- Remote connections use authenticated HTTPS/WSS, including LAN and Tailscale HTTPS. The network path can see ordinary connection metadata such as IP addresses, hostnames, timing, and traffic volume.
- Unsaved workspace file edits are kept as protected draft files in the app's sandbox until the paired server confirms the save, or until you choose Use Disk Version.
- Removing a server from the app removes its local pairing credential and the session history, lists, and file indexes cached for it on this device. It does not delete the server, workspace files, session history on the server, provider data, or backups.

## Data locations and control boundaries

1. **The Apple device.** The app stores pairing state, preferences, caches, and bounded diagnostic context in its sandbox and Keychain.
2. **The paired server and the services it contacts.** The server stores session and workspace state and can send prompts, attachments, and generated content to the providers you configure.

The person who operates the paired server controls its filesystem, backups, configuration, Pi session files, workspace directories, provider credentials, and diagnostics. Oppi cannot delete data held by a model provider, speech or voice backend, network provider, operating-system backup, or another server operator.

## Information you choose to use with Oppi

Oppi can process the following when you use the matching feature:

- Prompts, replies, tool calls, tool output, approval responses, and session metadata.
- Files selected through the Files picker and files referenced from a paired workspace.
- Photos and videos from the photo library, camera captures, and images or files shared through the Share extension.
- Microphone audio while dictation or a Live Voice call is active.
- Model-provider credentials you enter or authorize through the paired server's provider setup.
- Optional voice-reply text and audio produced by a server-side voice extension.

Oppi needs no photo, camera, or microphone access to pair or to show existing sessions. iOS permission prompts control those features.

## What stays on the Apple device

**Pairing and Keychain state.** Each paired server is a Keychain item in the shared App Group: HTTPS host and port, server identity fingerprint, TLS certificate pin when present, and the current device credential (a server-issued device ID, short-lived access token, expiry, and refresh challenge). A separate Keychain item holds the device's P-256 signing key, in the Secure Enclave on supported hardware and Keychain-sealed otherwise; it is not written into the paired-server record. Keychain items use `WhenUnlockedThisDeviceOnly` protection. Older `dt_` pairings cannot authenticate; update the client and re-pair. A small server-ID index in shared and standard `UserDefaults` lets the app and its extensions find paired servers.

**Preferences and caches.** Settings such as appearance, text size, voice mode, auto-title mode, haptics, diagnostics consent, quick-session choices, and the last keyboard language are device-local. A bounded diagnostic context can keep coarse values such as a session, workspace, or server identifier, screen, lifecycle state, and resource measurements for a later diagnostic payload. The app caches server responses under `Library/Caches/`: JSON copies of session traces, session lists, workspaces, Skills, and Skill details. That cache is sandbox-private, excluded from backup, and disposable, with a 256 MB disk budget and 30-day trace age by default (iOS can evict it sooner). The file-browser index is a separate cache. Traffic to your server is not written to the system HTTP cache (`Cache.db`): the API, WebSocket, event-stream, and dictation connections use no URL cache, so response bodies and bearer headers never land there, and on launch the app deletes any `Cache.db` an older build left behind.

**Encryption at rest.** Files the app and Share extension store (caches, message and file-edit drafts, the shared-file inbox) use iOS Data Protection class *Complete unless open*. Closed files cannot be read while the device is locked; files already open stay accessible until closed. The first launch after updating from an older build upgrades files it left at the iOS default. `UserDefaults` holds settings, identifiers, and review comment drafts; unsent Start Session prompts are protected draft files, not preferences.

**App Lock.** **Settings → Privacy & Security → App Lock** (Off, Immediately, or after 1, 5, or 15 minutes in the background) asks for Face ID, Touch ID, or the device passcode before Oppi shows content. Oppi never locks while open, and the timeout uses the system's monotonic clock. While on, the app-switcher snapshot is covered, Oppi's own local notifications show no session text (Live Activities never show any), the Share sheet asks before listing workspaces, and removing a server, revoking a device, deleting a workspace, changing provider credentials or signing in, and turning off Confirm New Servers ask first. Audio and video keep playing while locked. `oppi://` links and notification taps wait for unlock, Siri and Shortcuts open Oppi to unlock before starting a session and list no servers or workspaces, and push notifications show no session name. App Lock protects against someone holding your unlocked device. It encrypts nothing further and does not protect data on your servers or other paired devices. It is stored in the shared App Group preferences so the Share extension honors it.

**Server, workspace, and session locks.** Server Settings and Workspace Settings have a **Lock** toggle, and a session locks from its long-press menu. Opening a locked item, or starting a session in one from Quick Session, Siri, or Shortcuts, asks for device authentication first; if Siri cannot bring Oppi forward to ask, nothing is sent. A locked server covers its workspaces and sessions, and a locked workspace covers its sessions. An unlock lasts until Oppi locks again or, with App Lock off, leaves the foreground. Locks never stop audio or video. Locked items show only their name in lists, search, and Thread view, and Oppi's ask notifications hide their text and show no session name. Incognito sessions are always locked while App Lock is on. Turning a lock off asks for device authentication. These locks work with App Lock off, are stored on this device only (keyed by server identity and workspace or session ID), are never sent to a server, and are removed with their server, workspace, or session. Like App Lock, they protect against someone holding your unlocked device.

**Settings → Storage & About → Clear Local Cache** clears the timeline cache, file-browser index, and any leftover HTTP cache. It does not delete the paired server, server workspaces, Pi session files, provider data, or backups. Removing the app does not delete server-side data.

## Paired-server storage

The server's data directory defaults to `~/.config/oppi/` (change it with `OPPI_DATA_DIR` or `--data-dir`). It can contain:

- `config.json`, authentication state, server identity material, and transport configuration.
- SQLite session state, workspace records, saved Agents, schedules, resource settings, and search indexes.
- Pi session JSONL files referenced by Oppi sessions and local-session imports.
- Workspace files and files created or changed by server-side tools.
- Session attachment copies under the workspace's `.pi/attachments/`, and generated media and stored copies of photos you send under `session-attachments/`.
- Durable-session conversations (Durable Sessions experiment) under `durable/`.
- Live Voice call records in `voice-calls.json`.
- Upload records and blobs under the configured upload-store directory.
- Optional diagnostics under `diagnostics/telemetry/`.

Server-side tools run on the paired server and can read or change workspace files according to the server and Pi permission policy. The Apple app renders the result and does not execute those tools on iOS.

### Session and workspace deletion

Deleting a session asks the server to stop it and remove its Oppi session metadata, search-index entry, referenced local Pi session JSONL files, generated media attachments, stored copies of photos you sent, session-scoped copies in the workspace attachment directory, and its Live Voice call records. It does not undo changes an agent made to ordinary workspace files, delete data already sent to a model, speech, or voice provider, or touch backups.

A durable session keeps its conversation in a store under `durable/` shared with the subagents it spawned and with its forks. The server deletes that store, and every conversation in it, when you delete the last of those sessions. Until then, a deleted session's conversation stays in the store because the remaining sessions still read it.

Deleting a workspace removes the Oppi workspace record, not the host directory or its files.

Uploaded chat attachments use a separate local upload store. Unused and retained uploads expire after 24 hours by default (the operator can change this). The server marks a consumed upload as used and leaves its staged record and blob to the upload-store garbage collector, so session deletion does not remove that staged blob. The operator controls this directory and any manual cleanup.

These are implementation boundaries, not promises that every copy disappears at once. Snapshots, backups, Pi session paths, and provider-side copies follow their own controls.

### Incognito sessions

An Incognito session is left out of server search, and the app asks the server to delete it when you leave its chat, removing what deleting any session removes (Live Voice call records included). Its prompts still go to the model provider like any other session's. If the app closes before you leave the chat, or the delete fails (for example the server is unreachable), the session stays on the server and shows in your list again at the next sync.

## Prompts, files, and photos

A prompt goes over the authenticated connection to the server you paired, which can store it in session history and pass it to Pi and the selected model provider.

When you select a photo, video, or file, the app holds it while preparing the turn, creates an upload on the paired server before sending, and the server validates it, stores it in the upload store, and copies it into the session's workspace attachment directory when Pi materializes the turn. Images can also go to the selected model as image input; videos stay local files and are attached as workspace files. A photo, video, or file you cancel before sending is not uploaded. The Share extension stages shared files in the app's shared container until the quick-session handoff succeeds or is cancelled, then removes them; the source app controls any copy it keeps. Saving an image to the photo library is a separate, explicit action, and Oppi does not read the photo library or camera continuously.

## Model providers and server extensions

Oppi operates no hosted model service. The paired server uses Pi's configured providers and credentials. The Model Providers screen sends API-key entry to the server over the existing Oppi connection and the server saves the credential through its provider runtime; OAuth flows can open a provider authorization page in a browser. Depending on your settings and session, Pi or a provider can receive prompt text, conversation context, tool results, selected files, images, and other content needed to respond, and can process or retain it under its own terms. Check the provider's privacy policy before sending sensitive content.

Automatic session titles are generated by the server, generated on-device with Apple's local Foundation model, or disabled. Server-generated titles follow the same server and provider boundary as other model calls.

Server-side Skills, Extensions, tools, and voice features run on the paired server, and the iOS app does not download or execute server extension code. A voice extension can send text to the server's configured text-to-speech service and store the audio as a session attachment.

## Dictation and voice

**Settings → Voice & Dictation → Dictation Engine** is **On-device** (the default) or **Server**. Audio goes to the paired server only after you choose **Server**, and while the server offers no speech-to-text backend, the mic records on-device instead.

**On-device dictation** captures microphone audio for Apple's on-device Speech or Dictation transcriber, and the transcript stays local until you submit the prompt, which follows the normal server and provider flow. Apple can manage installation of the speech assets, and Apple's terms apply to those system services.

**Server dictation** streams 16 kHz, 16-bit mono PCM audio from the iPhone to the paired server, which sends it to the configured speech-to-text backend and returns incremental and final transcripts. `asr.provider: xai` sends audio to `asr.sttEndpoint` if set, otherwise `https://api.x.ai`. `asr.provider: http` sends it to `asr.sttEndpoint`. With no provider, an `api.x.ai` endpoint uses xAI and any other endpoint uses the HTTP/Yuwp path. With neither a provider nor an endpoint, with `http` and no endpoint, or with an unknown provider, server dictation stays off and no audio is sent. The endpoint can be local to the server host or remote ([Server configuration](server-configuration.md#dictation-asr--stt)). The Oppi server does not persist dictation audio locally. The backend can receive the audio and transcript and controls its own retention. For a remote endpoint, the operator is responsible for transport security, credentials, processing, and retention.

**Voice replies** are generated by the paired server and its configured extensions or providers, and the audio can stream to the app or be stored as a session attachment. **Read aloud** sends the text of the reply you choose, without code blocks or URLs, from the server to the text-to-speech service in its `tts` config; the audio streams to the app and is not stored.

### Live Voice

Live Voice is an experiment, off until you turn on **Settings → Experiments → Live Voice**. During a call, the app streams 16 kHz microphone audio to the paired server until the call ends. The server's `asr.liveVoiceBackend` decides where it goes:

- `yuwp` (the default): the server sends the audio to `asr.sttEndpoint` for transcription. With a `tts` config, the text-to-speech service read aloud uses speaks the agent's replies. If the agent does not speak during a reply, the server has that service read the start of its written reply, or its error.
- `grok-voice`: the server sends the audio to xAI (`wss://api.x.ai/v1/realtime`) with the server's xAI sign-in or API key. xAI transcribes it, decides which of your words to pass to the agent, and receives the text of everything the agent says aloud. xAI's privacy policy and retention apply.

What you ask during a call becomes a message in the session, like a typed prompt, and follows the same model-provider flow. The server does not store call audio. It keeps a record of each call in `voice-calls.json` (your requests and the agent's progress and replies) so a call can continue after a server restart. A call's record is deleted 24 to 25 hours after the call ends (checked hourly), or as soon as you delete its session. A dropped call that is not rejoined ends 10 minutes later. If the server finds `voice-calls.json` corrupt, it keeps it as `voice-calls.json.corrupt-<time>` and does not delete it; remove it by hand.

## Push notifications

Push is off by default. It works only when you turn on **Push Notifications** for a paired server in Server Settings (Notifications section). The first time a session on a server finishes or needs your answer, All Sessions also shows a card, "Get notified when an agent needs you", with **Turn On Notifications** and **Not Now**. Turn On shows the same disclosure as Server Settings before anything is sent; Not Now hides the card for that server for good. The card shows only while the server offers push, this build can use it, and push is off. Its state (due, or closed) is kept on this device, per server, and nothing about it is sent anywhere. The server offers push through Oppi's relay unless its operator sets `push.mode` to `off`, which hides that setting, and builds without push support do not show it. Before turning on, the app shows what the relay can see.

**How content is protected.** Turning push on creates a separate X25519 encryption key for that server. The private key stays in this device's Keychain (readable after first unlock so alerts open while locked) and never syncs or moves. The device sends only the public key to your server, signed with its pairing key. Your server encrypts each alert (title, session name, and a short message: the question or approval a session waits on, the agent's words from the `notify` tool, or fixed text) to that key and signs it with its identity key. A Notification Service Extension on your device checks the signature, decrypts the alert, and rejects old or repeated ones. While App Lock is on, or a server, workspace, or session lock covers the session, it shows the alert type without the session name, question, or agent's words. Anything it cannot verify shows only "Oppi: You have a new notification." When registering, the device tells your server which alert types it can open, and the server sends no others.

What this does not cover: someone who holds the relay's Apple key or controls its hosting account can send a notification with any text that never reaches the extension, so it shows as sent. Tapping an Oppi notification only opens the session it names, and session notifications have no actions, so a forged one can mislead you but cannot act for you. A new-device pairing request has Approve and Deny buttons, both needing the device unlocked. Approve only opens Oppi, where you approve the request your server lists. Deny acts only on an alert the extension verified, so Deny on a forged alert does nothing.

**The push relay.** Apple delivers pushes only from the developer team that signs the app, so a relay holds that team's Apple key and forwards your server's encrypted alerts to Apple. Your server names the relay. Oppi's relay is `push.oppi.chaosdonkey.dev`, operated by Oppi's developer (see [Contact and reporting](#contact-and-reporting)), and it is the relay for App Store and TestFlight builds because it holds the signing team's Apple key. It runs on Cloudflare Workers with Cloudflare's request logging off. Cloudflare runs the relay's HTTPS endpoint, so it handles everything below in transit along with the relay's stored data, and Cloudflare's privacy policy applies. The in-app disclosure describes this relay. The relay code is in the Oppi repository (`relay/`), and its protocol and threat model are in `protocol/push/spec.md`.

The relay receives and can see:

- your device's Apple push token and whether it is a development or production build;
- whether your device passed Apple's App Attest check, and its App Attest public key;
- your server's IP address when it sends an alert, the time of each alert, and its fixed size;
- your device's IP address when it talks to the relay: registering, turning push on for a server, and syncing a card;
- an opaque per-device collapse ID, so a newer alert for the same session can replace an older one;
- with Live Activities on (below), the card's two counts and the time of each card update.

The relay stores the push token, environment, App Attest public key and counter, hashes of its access secrets, the send permissions you created (one per server), the current day's and minute's alert counts for its per-device limits, and which registration is current for your push token. With Live Activities on, it also stores the Live Activity tokens Apple issues for this device, a random name for each server's card and which send permission may update it, when each card's token arrived, which cards you dismissed, and daily and per-minute Live Activity counts. App Store and TestFlight builds turn push on only on devices that pass App Attest. The relay does not store alerts, card counts, IP addresses, or request logs, keeps no analytics, and cannot decrypt alerts: it has no key and no decryption code. Cloudflare, which runs the relay's HTTPS endpoint, does keep its own HTTP analytics for the hostname — client address, method, path, and time — for as long as that product retains them, so your device's address reaches Cloudflare even though the relay stores none.

It deletes a registration when Apple reports the token invalid, after 90 days with no push (for a registration made before this change was deployed, the count starts at its next push), or when your device asks. Turning push off for a server, or removing the server, deletes that server's send permission, and when no other server on your device still has push on through that relay, your device asks the relay to delete the whole registration. A registration the relay could not be reached to delete stays until 90 days pass without a push, Apple reports the token invalid, or the device registers again. The relay's per-device limits (today 100 pushes a day, alerts and Live Activity updates together, with 30 kept for alerts) are preliminary and may change.

**Apple.** Apple Push Notification service sees the same push token, environment, timing, size, and collapse ID, the alert's expiry, and the relay's IP address (not your server's), and delivers the encrypted alert to your device. Your device gets its push token from Apple. On devices that support App Attest, turning push on also asks Apple's App Attest service to attest a key, so Apple learns that this Oppi install uses push. Apple's privacy policy applies.

**Live Activities.** Off by default. With **Live Activities** on for a server (Server Settings, Notifications section), the Lock Screen and Dynamic Island show one card for that server with two numbers: how many agents are running and how many need you, and never session names, tool names, or other text. While Oppi runs, the app updates the card on the device. If push is also on for that server, your server keeps the card current while Oppi is closed by sending the two counts to the relay, which passes them to Apple in a fixed format. These counts are not encrypted, so the relay, Cloudflare, and Apple can see them and when they change. Updates go out at most once a minute and share the relay's 100 pushes a day per device with alerts, which come first: Live Activity updates stop at 70, plus 8 more past the day's 100 for ending a card so a card is never left showing finished work. These limits are preliminary and may change. Starting a card this way shows Apple's required alert, "Oppi: Agents are working." Without push, nothing about the card leaves your device. Turning Live Activities on while push is on, or push on while Live Activities is on, first shows a disclosure of what the counts reveal. The app tells the relay which servers may update a card, and the relay refuses every other server. Dismissing a card keeps it away until nothing is running or waiting on that server, even if Oppi is closed or restarted. Turning Live Activities off for a server ends its card and takes that server off the relay's list; if the relay cannot be reached, the app keeps trying, including each time it opens.

**Turning it off.** Turning push off for a server, or revoking this device on the server, deletes this device's push registration on that server and asks the relay to delete the send permission. Removing the server from the app asks the relay to delete the send permission, and the server deletes its registration the next time it tries to push and the relay refuses it. When that server was the last one with push on through the relay, your device asks the relay to delete this device's relay registration instead, which takes the send permission with it. Your device deletes the server's push keys when you turn push off or remove the server.

## SSH Terminal

SSH Terminal connects from this device directly to an SSH host you add, not through the Oppi server. A host under `*.ts.net` connects through Oppi's Tailscale node while it runs, and Tailscale may relay the encrypted traffic; other hosts use your current network. Nothing connects until you add a host and tap Connect. Oppi shows the host's key fingerprint first and sends no credentials until you trust it. Everything you type, paste, or dictate into a terminal goes to that host, and its programs decide what to do with it.

A pasted image or file attached from the terminal is saved on the host in a private owner-only folder (`oppi-ssh-<uid>`) under its `$TMPDIR` (or `/tmp` without one), and its path is typed into the shell. Oppi does not delete it; it stays until the host's temporary-folder cleanup removes it. A program on the host can copy text to this device's clipboard while you view its terminal. That copy stays on this device (it does not reach Universal Clipboard), and a host can never read your clipboard or a file on this device. Terminal notifications appear only as cards inside Oppi. If the SSH host is also a server you paired, opening a path from the terminal reads that file through the paired server, not over SSH.

Saved hosts (address, port, user name, sign-in method, Run on Connect command) are stored in this device's preferences. Saved passwords, sudo passwords, and trusted host keys are stored in this device's private Keychain, never synced, and never placed in preferences or logs. Reading a saved password needs Face ID, Touch ID, or your passcode, and Oppi remembers a sign-in approval for 5 minutes. **Fill Password**, which types a saved password at a terminal password prompt, asks every time, names the host, types only into the prompt you confirmed, and never presses Return. Deleting a host deletes its saved passwords. See [SSH Terminal](ssh-terminal.md#credentials-and-host-trust).

## Network metadata

After pairing, Oppi uses authenticated HTTPS/WSS. Automatic routing evaluates verified LAN HTTPS and paired HTTPS, and Tailscale HTTPS is supported. The local CLI stays on an owner-only Unix socket. The network path, DNS resolver, and any TLS terminator you configure can observe ordinary connection metadata: IP addresses, hostnames, SNI, timing, duration, and approximate traffic volume. See [SECURITY.md](../SECURITY.md) and [Onboarding](onboarding.md).

## Optional diagnostics

Public release builds upload no Oppi diagnostics until you enable **Settings → Privacy & Security → Send Diagnostics**. The destination is the currently paired Oppi server, and no external crash-reporting service is linked in public iOS builds.

Diagnostics can include bounded MetricKit summaries, crash, hang, CPU, disk, and app-launch information, app and OS/build details, resource samples, connection and lifecycle outcomes, low-cardinality session, workspace, and app-instance identifiers, and redacted client logs. They exclude prompt text, assistant output, tool arguments, command output, dictation transcript text, relay URLs and hosts, IP addresses, tokens, tickets, node IDs, endpoint IDs, secrets, credentials, raw URLs, and local file paths.

| Diagnostic data | Default retention | Operator override |
| --- | ---: | --- |
| MetricKit payloads | 14 days | `OPPI_METRICKIT_RETENTION_DAYS` |
| Chat metrics | 14 days | `OPPI_CHAT_METRICS_RETENTION_DAYS` |
| Client logs | 14 days | `OPPI_CHAT_METRICS_RETENTION_DAYS` |
| Server resource metrics | 30 days | `OPPI_SERVER_METRICS_RETENTION_DAYS` |
| Server operations metrics | 30 days | `OPPI_SERVER_OPS_METRICS_RETENTION_DAYS` |

The server operator can change these values, stop accepting uploads through telemetry mode, delete diagnostic files, or retain backups. Development and internal builds can have different defaults; the public-build opt-in is the App Store behavior.

## Choices and consent

You control whether to:

- Pair a server and keep or remove its device credential.
- Choose on-device or server dictation.
- Select, send, or cancel a prompt attachment.
- Connect or disconnect a model-provider credential on the paired server.
- Enable or disable public-build diagnostics upload.
- Turn push notifications on or off for each paired server.
- Delete sessions and clear the local timeline cache.
- Configure or disable speech-to-text, text-to-speech, and model providers on the server.

Turning off diagnostics stops new uploads and clears the client-side upload queues, but cannot recall diagnostics the paired server already received. Changing dictation or provider settings does not delete content already sent to an earlier backend.

## Contact and reporting

Oppi is developed by Da Chen, who also operates the push relay and is responsible for the data it holds. Oppi has no hosted account or central data-request system. For data held by a paired server, contact the person who operates that server or use its local filesystem and provider controls.

For product support, privacy questions, and deletion help, email [duh@chaosdonkey.dev](mailto:duh@chaosdonkey.dev) or use the [Oppi Support page](support.md). For security reports, read [SECURITY.md](../SECURITY.md) and send sensitive details by email, not through a public issue.

## Changes to this policy

This page is versioned with the repository. Current code, server configuration, provider, network, and platform behavior control the facts described here. When those boundaries change, this page must be reviewed with the release.
