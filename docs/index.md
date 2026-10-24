# Oppi docs

Oppi is a native Apple client for a server you run yourself. It shows [Pi](https://github.com/badlogic/pi-mono) coding sessions on iPhone and iPad.

The docs have two tracks: **daily use** and **extension authoring**. Pi owns the coding-agent manual: slash commands, skills, compaction, and the TUI are in [Pi's usage guide](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/usage.md).

## Daily use

- [Onboarding and pairing](onboarding.md): install the server, pair devices, approve new devices
- [Using Oppi](usage.md): screens, prompt vs steer vs follow-up, Quick Session, files, voice, Agents and schedules, **Edit with Oppi**, server settings
- [Custom themes](themes.md): JSON themes on the server, tokens, contrast
- [Server configuration](server-configuration.md): config CLI, voice, push, MCP, project trust, auth module
- [Reverse proxy](reverse-proxy.md): put Oppi behind Caddy, nginx, or Cloudflare Tunnel
- [Sandbox workspaces](sandbox.md): run agent tools in a VM
- [Oppi Mirror](oppi-mirror.md): show a live terminal Pi session in Oppi
- [SSH Terminal](ssh-terminal.md): shell on a saved host
- [Document viewers](document-viewers.md): viewers, wiki links, file editing
- [Provider quotas](provider-quotas.md): remaining quota and pace
- [Deep links](deeplinks.md): `oppi://` links
- [Support](support.md) and [Privacy](privacy.md)
- [Screenshots](demo/README.md)

## Extension authoring

Pi owns the extension API ([Pi extensions](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/extensions.md)). These pages cover what Oppi adds.

- [Oppi extension behavior](extensions.md): what Oppi loads, mobile rules, Oppi event channels, durable extensions
- [Extension native UI](extension-native-ui.md): API reference for prompts, widgets, and native blocks
- [Attachment rendering](attachment-rendering.md): images, audio, video, and inline Markdown embeds
