# Support and contact

_Last updated: 2026-08-27_

Oppi is a native Apple client for an Oppi server that you run and pair yourself. There is no hosted Oppi account service. Contact support by email, or use GitHub Issues for public bug reports and feature requests.

## Contact route

- **Product support and private reports:** [duh@chaosdonkey.dev](mailto:duh@chaosdonkey.dev)
- **Public bug reports and feature requests:** [Open an Oppi issue](https://github.com/duh17/oppi/issues/new) (GitHub sign-in required)
- **Existing reports and answers:** [Browse Oppi issues](https://github.com/duh17/oppi/issues)
- **Security reports:** Read [SECURITY.md](../SECURITY.md) first. Send sensitive details to [duh@chaosdonkey.dev](mailto:duh@chaosdonkey.dev), not to a public issue.
- **Source and release context:** [Oppi repository](https://github.com/duh17/oppi)

This page does not promise a response time or claim a separate legal entity.

## Before opening an issue

1. Check whether the problem is in the Apple app, the paired server, the network path, or a model/speech provider.
2. Record the app version from **Settings → About**.
3. Record the server version and transport mode without including its host, token, certificate, or invite link.
4. If the problem involves dictation, note whether **Settings → Voice → Dictation Engine** is **On-device** or **Server**.
5. If you enabled diagnostics, you can describe the approximate time and the paired server that received them. Diagnostics are optional and go only to that paired server.

## Redact private data

Remove the following before posting:

- Pairing QR codes, invite links, bearer tokens, API keys, OAuth codes, and certificate fingerprints.
- Prompt text, assistant output, tool arguments, command output, dictation transcripts, and workspace paths.
- Photos, files, screenshots containing private content, IP addresses, hostnames, invite links, and session identifiers.

A short description of the action, the expected result, the observed result, the app/server versions, and a redacted error message is usually enough to start.

## Common paths

- [Using Oppi](usage.md)
- [Onboarding and pairing](onboarding.md)
- [Dictation / ASR](../server/docs/asr.md)
- [Privacy Policy](privacy.md)

### Pairing or connection problems

Use a fresh invite. Invites are single-use and expire after a short period. Check the server's `oppi status` and `oppi doctor` output locally, then report only the redacted result. For HTTPS or Tailscale issues, say whether the path was LAN or remote; do not include hosts, tokens, certificate fingerprints, or invite links.

### Dictation problems

Switch to **On-device** dictation to separate microphone and Apple speech issues from server or STT-backend issues. For **Server** dictation, the audio path is iPhone → paired server → configured STT endpoint. The server does not persist dictation audio locally, but the configured STT backend has its own processing and retention rules.

### Data and deletion questions

Removing a paired server from the app removes the local pairing credential and local server list entry. It does not delete the server or its data. Deleting a session uses the paired server's deletion path for session metadata, referenced Pi session files, generated media, and session-scoped attachment copies; it does not undo ordinary workspace changes or remove provider-side copies. See the [Privacy Policy](privacy.md) for the current storage and retention boundaries.

If you operate the server, you control its data directory, workspace files, provider credentials, TLS/network configuration, diagnostic files, and backups. If someone else operates it, ask that operator about data they control.

## Scope of this page

This page documents the support route and current troubleshooting boundaries. It does not promise a response time, uptime, account service, deletion deadline, or external publication state.
