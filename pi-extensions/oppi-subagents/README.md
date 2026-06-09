# Oppi subagents extension (parked)

This directory preserves the old Oppi `subagents` Pi extension code. It is not part of the active Oppi server extension path.

Current status:

- Oppi server no longer injects this extension from `SdkBackend`.
- `subagents` is not an Oppi built-in workspace extension.
- The code is kept here as reference material for the Clanker control-plane/API work.
- If someone loads this manually as a Pi extension, it still expects Oppi workspace/session HTTP APIs and an Oppi API descriptor.

The old tool surface was:

- `spawn_agent`
- `inspect_agent`
- `send_message`

The useful ideas to carry forward are generic session creation, parent/session identity, idempotent launch, and explicit permission/runtime boundaries. Those belong in the Clanker control plane, not hidden `SdkBackend` built-in injection.
