# Oppi subagents extension (parked)

This directory preserves the old Oppi `subagents` Pi extension code. The active Oppi server extension path does not use it.

Current status:

- Oppi server no longer injects this extension from `SdkBackend`.
- `subagents` is not an Oppi built-in workspace extension.
- This directory keeps the code as reference material for Agent launch and API work.
- A manual Pi-extension load still expects Oppi workspace and session HTTP APIs plus an Oppi API descriptor.

The old tool surface combined delegated launch, inspection, and message sending in one extension.

The useful ideas to carry forward are generic session creation, parent and session identity, idempotent launch, and explicit tool and runtime targets. They belong in AgentLaunchService and injected server-agent extensions, rather than hidden `SdkBackend` built-in injection.

v1 has no active delegated-launch tool. Do not revive this parked tool surface. When a concrete caller needs delegated launch, build a narrow Oppi-owned extension that calls AgentLaunchService with explicit source, target, idempotency, and approval behavior.
