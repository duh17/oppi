# Oppi server architecture: Cleanup targets and code map

Part of [Oppi server architecture](../architecture-server.md). Open cleanup targets and file pointers by area.

## Server cleanup targets

Keep these high-churn modules small and explicit:

- `server/src/routes/sessions.ts` — keep as a transport adapter. Put lifecycle, list, trace, diff, and file-read policy in the session application services.
- `server/src/stream.ts` and `server/src/ws-message-handler.ts` — keep WebSocket framing and client-message mapping separate from runtime ownership decisions.
- `server/src/session-lifecycle-service.ts`, `server/src/session-list-service.ts`, and `server/src/session-trace-service.ts` — keep the services separate; do not merge lifecycle, list, and trace behavior into one controller.
- `server/src/server.ts` — keep as composition root; move local policy helpers out when they grow beyond startup/transport wiring.
- `server/src/sessions.ts` and `session-*` — continue pushing managed-runtime behavior into coordinators rather than adding new facade logic.
- `server/src/sdk-backend.ts` — keep SDK and sandbox setup isolated from HTTP and route concerns.
- `server/src/pi-tui-mirror-runtime.ts` — preserve shared projection with managed sessions; avoid creating a second projection path.

## Where to look in code

| Concern                                     | Files                                                                                                                                                                                  |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Server composition and listeners            | `server/src/server.ts`, `server/src/local-api-socket.ts`, `server/src/cli.ts`                                                                                                          |
| Route dispatch                              | `server/src/routes/index.ts`, `server/src/routes/*`                                                                                                                                    |
| Workspace catalog summaries                 | `server/src/routes/workspaces.ts`, `server/src/storage/session-sqlite-store.ts`                                                                                                        |
| Workspace detail recent list                | `server/src/routes/sessions.ts`, `server/src/session-list-service.ts`, `server/src/local-sessions.ts`                                                                                  |
| Session lifecycle HTTP actions              | `server/src/routes/sessions.ts`, `server/src/session-lifecycle-service.ts`                                                                                                             |
| Saved Agent definitions and launches        | `server/src/routes/agents.ts`, `server/src/agent-definitions.ts`, `server/src/agent-launch-service.ts`                                                                                 |
| Schedule definitions and automatic runs     | `server/src/routes/schedules.ts`, `server/src/agent-schedules.ts`, `server/src/agent-schedule-runner.ts`, `server/src/agent-schedule-dispatch.ts`, `server/src/agent-schedule-cron.ts` |
| Session trace, diff, and changed-file reads | `server/src/routes/sessions.ts`, `server/src/routes/session-files.ts`, `server/src/session-trace-service.ts`                                                                           |
| Focused session stream                      | `server/src/stream.ts`, `server/src/ws-message-handler.ts`                                                                                                                             |
| Global app event stream                     | `server/src/app-event-stream.ts`, `server/src/session-broadcast.ts`                                                                                                                    |
| Managed runtime                             | `server/src/sessions.ts`, `server/src/session-*.ts`, `server/src/sdk-backend.ts`                                                                                                       |
| Terminal mirror runtime                     | `server/src/runtime-router.ts`, `server/src/pi-tui-mirror-runtime.ts`, `server/src/pi-tui-mirror-contract.ts`, `pi-extensions/oppi-mirror/extensions/oppi-mirror.ts`                   |
| Extension UI relay                          | `server/src/sdk-ui-bridge.ts`, `server/src/extension-ui-contract.ts`, `server/src/extension-ui-state.ts`, `server/src/session-agent-events.ts`                                         |
| Workspace files and media                   | `server/src/routes/workspace-files.ts`, `server/src/workspace-file-edit.ts`, `server/src/current-file.ts`, `server/src/file-serving-policy.ts`, `server/src/routes/uploads.ts`, `server/src/session-attachments.ts`, `server/src/http-range.ts` |
| Current-file and host file reads            | `server/src/routes/host-files.ts`, `server/src/current-file.ts`, `server/src/workspace-file-edit.ts`, `server/src/host-file-path.ts`, `server/src/file-serving-policy.ts`, `server/src/http-range.ts`                      |
| Protocol contract                           | `server/src/types/protocol.ts`, `server/src/types.ts`, `protocol/*.json`                                                                                                               |
| Pi model/auth and pricing                   | `server/src/session-title-generator.ts`, `server/src/token-usage.ts`, `server/src/model-catalog.ts`                                                                                    |
| Provider usage quotas                       | [provider-quotas.md](../../docs/provider-quotas.md); `server/src/provider-quota/` (built-in adapters and generic extension quota declarations share the DTO and Apple compact/detail presentation) |
| Pi event projection                         | `server/src/session-events.ts`, `server/src/session-agent-events.ts`, `server/src/session-protocol.ts`, `server/src/session-agent-event-media.ts`                                      |
