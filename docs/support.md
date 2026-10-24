# Support and contact

_Last updated: 2026-08-27_

Oppi is a native Apple client for an Oppi server that you run and pair yourself. There is no hosted Oppi account service. Contact support by email, or use GitHub Issues for public bug reports and feature requests. This page does not promise a response time, uptime, account service, deletion deadline, or external publication state, and it does not claim a separate legal entity.

## Contact

- **Product support and private reports:** [duh@chaosdonkey.dev](mailto:duh@chaosdonkey.dev)
- **Public bug reports and feature requests:** [Open an Oppi issue](https://github.com/duh17/oppi/issues/new) (GitHub sign-in required), or [browse existing issues](https://github.com/duh17/oppi/issues)
- **Security reports:** read [SECURITY.md](../SECURITY.md) first, and send sensitive details to [duh@chaosdonkey.dev](mailto:duh@chaosdonkey.dev), not to a public issue
- **Source and releases:** [Oppi repository](https://github.com/duh17/oppi)

## Before opening an issue

1. Decide whether the problem is in the Apple app, the paired server, the network path, or a model or speech provider.
2. Record the app version (**Settings → Storage & About**), and the server version and transport mode, without its host, token, certificate, or invite link.
3. For dictation problems, note whether **Settings → Voice & Dictation → Dictation Engine** is **On-device** or **Server**.
4. If you enabled diagnostics, describe the approximate time and the paired server that received them. Diagnostics are optional and go only to that server.

Remove these before posting:

- Pairing QR codes, invite links, bearer tokens, API keys, OAuth codes, and certificate fingerprints.
- Prompt text, assistant output, tool arguments, command output, dictation transcripts, and workspace paths.
- Photos, files, screenshots with private content, IP addresses, hostnames, and session identifiers.

A short description of the action, expected result, observed result, app and server versions, and a redacted error message is usually enough.

## Common problems

- **Pairing or connection:** use a fresh invite, since invites are single-use and expire quickly. Run `oppi status` and `oppi doctor` on the host and report only the redacted result, saying whether the path was LAN or remote. See [Onboarding and pairing](onboarding.md).
- **Dictation:** switch to **On-device** to separate microphone and Apple speech issues from server or speech-backend issues. With **Server**, audio goes iPhone → paired server → configured STT endpoint. The server does not persist dictation audio, but the STT backend has its own processing and retention rules ([Dictation / ASR](../server/docs/asr.md)).
- **Data and deletion:** removing a paired server from the app removes the local pairing credential and server list entry, not the server or its data. Deleting a session uses the server's deletion path for session metadata, referenced Pi session files, generated media, and session-scoped attachment copies. It does not undo workspace changes or remove provider-side copies. If you operate the server, you control its data directory, workspace files, provider credentials, TLS and network configuration, diagnostics, and backups; otherwise ask that operator. See the [Privacy Policy](privacy.md) and [Using Oppi](usage.md).
