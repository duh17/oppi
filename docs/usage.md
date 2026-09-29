# Using Oppi

Daily phone and tablet use after you have paired a server. Pairing is in [Onboarding](onboarding.md).

Pi slash commands, skills, compaction, and the TUI stay in [Pi's usage guide](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/usage.md).

![Session and search](demo/session-combined.png)

![Timeline and files](demo/timeline-combined.png)

## Screen map

The Workspaces tab opens **All Sessions** for the active server.

- **Your Turn** — sessions waiting on you: a question, confirmation, or other prompt.
- **Working** — sessions that are busy.
- Stopped sessions sit below, grouped by day. Each row shows the workspace name.

All Sessions opens in **Threads**: sessions that other sessions launched sit under the session that launched them. A thread with work in progress stays in **Working** even while its root waits. The view button in the top bar, next to the server switcher, flips to the flat **Sessions** list until Oppi next opens; Settings → Sessions → **All Sessions opens in** changes the default. Open a thread and use its pill for two views:

- **Outline** — the launch tree. Finished children fold into one row under their parent.
- **Timeline** — one lane per session, with launches, stops, and messages or control commands sent between sessions with `oppi session`. Filter chips hide or show each kind. Messages to sessions in other threads appear as cross-thread rows.

The sidebar or drawer manages saved Agents and schedules, collapses the workspace list, opens App Settings, or browses a workspace's sessions, files, and settings.

Open a session to see the chat timeline. Tap a tool row to inspect command, output, diff, or file content. The changed-files bar lists files this session touched. If an extension shows a card or sheet, answer it in the app; you do not need to go back to a Mac.

## Prompt, steer, follow-up, and stop

When the session is idle, the composer says **Message…**. Send starts a new turn.

While the agent is working, choose how to send:

| Mode | Composer | What it does |
| --- | --- | --- |
| **Steering** | Steer agent… | Guides the current turn. |
| **Follow-up** | Queue follow-up… | Queues the next instruction after this turn. |

Toggle **Steering** / **Follow-up** on the composer. If an Ask card is visible, the composer answers that prompt instead of creating a steer or follow-up.

When the composer is empty during a busy turn, the primary action is **Stop**.

## Siri, Quick Session, and the share sheet

**Siri** starts a session with a prompt and opens that live chat. Say "Start session in Oppi", "Open session in Oppi", or "New session in Oppi", and optionally "in <workspace>". If you don't give a prompt, Siri asks "What should Pi do?".

**Quick Session** opens the composer without creating a session yet. Launch it from Oppi, Control Center, the Action Button, or the Shortcuts **New Session** action. That action can add optional text and one image to the composer.

The iOS share extension accepts text, URLs, images, and files. Choose a paired-server workspace in its Quick Session composer, then start the session from the share sheet.

## Files and photos

Attach files from the Files picker, photos and videos from the library, or a camera capture. A selected photo, video, or file uploads with the session turn; canceling before send does not upload. Videos are uploaded as files, not as model image input. The Share extension stages shared files until the Quick Session handoff succeeds or is cancelled.

Assistant output can open markdown, code, diffs, and other documents in full-screen viewers. See [Document viewers](document-viewers.md).

## Voice

**Settings → Voice → Dictation Engine** is **On-device** or **Server**.

- **On-device** uses Apple's speech APIs on the phone. Audio stays on the device. Submitting the transcript still sends the prompt to the paired server.
- **Server** streams audio to the paired server, which forwards it to the configured speech-to-text backend.

**Settings → Chat Display → Dictation indicator** chooses the listening control: **Composing** and **Breathing** are voice-reactive Metal orbs, and **Ring** is the older stroke. New installs default to Composing; a saved Ring choice stays. The button size does not change.

**Settings → Chat Display → Working indicator** chooses the busy-row animation: **Working**, **Searching**, and **Solving** Metal orbs, plus **Pi** and **GoL**. New installs default to Working; saved Pi or GoL choices stay.

Those indicators adapt Thinking Orbs geometry; they are not original Oppi artwork. Jakub Antalik created the original [thinking-orbs](https://github.com/Jakubantalik/thinking-orbs) designs and engine. Haplo LLC made the Swift [ThinkingOrbs](https://github.com/haplollc/ThinkingOrbs) port. Oppi adds Metal rasterization and voice-reactive motion. The full MIT notice lives with the orb source in `clients/apple/Shared/Renderers/Orbs/LICENSE`.

Voice replies are produced by the paired server and its configured voice extension. See [Server configuration](server-configuration.md) for ASR and TTS setup.

## Agents and schedules

The sidebar holds saved **Agents** and **Schedules**.

- Agents store reusable definitions and can use one Unicode emoji or SF Symbol as an icon.
- Schedules support `at`, `every`, and `cron` triggers. Each schedule can target a workspace, saved Agent, or existing session. Oppi keeps run history for manual and approved automatic runs.

Create and edit sheets can open a **Pi Control** session (ordinary Pi with global settings, tools, Skills, Extensions, `SYSTEM.md`, and `APPEND_SYSTEM.md`) or use the native forms.

## Sandbox and Mirror

- [Sandbox workspaces](sandbox.md) run agent file tools in a Gondolin VM.
- [Oppi Mirror](oppi-mirror.md) shows a live terminal Pi session in Oppi.

## Models and quota

Pick models from the in-app picker. Remaining provider quota and pace live on **Server** detail → **Model Providers**. The CLI also has `oppi quota` and `oppi models`. See [Provider quotas](provider-quotas.md).

## Server settings

**Server** (host switcher → Server Settings) shows the paired server version.

When a newer `oppi-server` is on npm and this host is a global npm install, the screen shows **Update available** and an **Update** button. Confirming names the version and warns that running sessions will be interrupted. Oppi installs that exact version, restarts the server, and reconnects.

Git checkouts, Docker images, and other non-npm installs show a copyable `npm install -g oppi-server@…` command instead of a button. `oppi update` on the host uses the same install check.

If this app build needs a newer server than the one you are connected to, All Sessions shows a single notice that opens Server. That notice goes away after you update and reconnect.

**Server** detail also lists **Paired Devices**. Your device is marked **This device** and has no Revoke button. Other devices show when they were last used; **Revoke** asks for confirmation, then signs that device out immediately. See [Onboarding](onboarding.md#paired-devices).

## What stays Pi

Oppi does not replace Pi's coding-agent manual. Use [Pi's usage guide](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/usage.md) for slash commands, skills, compaction, the TUI, and the extensions API. Oppi documents only mobile daily use and the [extension overlay](extensions.md).
