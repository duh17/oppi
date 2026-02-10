{
  "id": "c6dda8b7",
  "title": "Rename project to Oppi (server + iOS app)",
  "tags": [
    "rename",
    "ios",
    "server",
    "open-source"
  ],
  "status": "open",
  "created_at": "2026-02-09T00:10:36.396Z"
}

Rename `pi-remote` → `oppi` across the entire project. Server will be open-sourced.

## Scope
- iOS display name: `PiRemote` → `Oppi`
- iOS bundle ID: `dev.chenda.PiRemote` → `dev.chenda.Oppi`
- iOS directory: `ios/PiRemote/` → `ios/Oppi/`
- Server package: `pi-remote` → `oppi`
- CLI binary: `pi-remote` → `oppi`
- Config paths: `~/.config/pi-remote/` → `~/.config/oppi/`
- Data dirs: `~/.pi-remote/` → `~/.oppi/` (or similar)
- All internal references, imports, logs, README, AGENTS.md
- Repo name TBD

## Prerequisites
- New App ID in Apple Developer portal (`dev.chenda.Oppi`)
- New provisioning profiles (automatic signing should handle)
- Do AFTER TestFlight pipeline works so first build ships under correct name

## Notes
- "Oppi" — sounds Nordic, `pi` embedded in the name, subtle nod
- Server bits will be open-sourced
- Do as a single dedicated commit
