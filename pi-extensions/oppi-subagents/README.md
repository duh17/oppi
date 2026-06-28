# Oppi subagents extension (parked)

This directory preserves the old Oppi `subagents` Pi extension code. It is not part of the active Oppi server extension path.

Current status:

- Oppi server no longer injects this extension from `SdkBackend`.
- `subagents` is not an Oppi built-in workspace extension.
- The code is kept here as reference material for Agent launch/API work.
- If someone loads this manually as a Pi extension, it still expects Oppi workspace/session HTTP APIs and an Oppi API descriptor.

The old tool surface mixed delegated launch, inspection, and message sending in one extension.

The useful ideas to carry forward are generic session creation, parent/session identity, idempotent launch, and explicit tool/runtime targets. Those belong in AgentLaunchService and injected server-agent extensions, not hidden `SdkBackend` built-in injection.

There is no active delegated-launch tool in v1. Do not revive this parked tool surface. If a concrete caller needs delegated launch, build a new narrow Oppi-owned extension that calls AgentLaunchService with explicit source, target, idempotency, and approval behavior.
