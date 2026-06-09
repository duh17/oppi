# Oppi dev Pi extension

Project-local Pi extension source for Oppi development workflows.

The active project extension shim lives at `.pi/extensions/oppi-dev.ts` and re-exports this module so Pi sessions started in `~/workspace/oppi` auto-discover it.

## Tools

- `oppi_install` — install or fast-install the iOS app on Duh Ifone.
- `oppi_server_restart` — restart the local Oppi server runtime through `oppi-workflow.sh`.
- `oppi_live_debug` — run live triage, diagnostics, metrics, server-log, build-errors, and tool-analysis lanes.

Each tool asks for extension UI approval before running. The extension also gates direct `bash` calls that invoke `oppi-workflow.sh install`, `dev-install`, or `server-restart`, nudging agents back to the dedicated tools.

Reload existing sessions with `/reload`; new sessions in this workspace load the shim automatically.
