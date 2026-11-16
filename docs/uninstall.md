# Uninstall Oppi

Remove the Oppi server from a Mac or Linux machine, and everything installing and running it added there.

## Remove Oppi

Run this on the machine that runs the server, as the user that installed it:

```bash
oppi uninstall
```

At the end it asks whether to delete the data folder too. Answer `y` to delete it, or press Enter to keep it.

To answer that question in advance, for a script or an SSH command without a terminal, add a flag:

```bash
oppi uninstall --delete-data   # also delete the data folder
oppi uninstall --keep-data     # keep the data folder
```

Without a terminal and without a flag, it keeps the data folder.

If `oppi` is not found, the installer's link is gone or not on `PATH`. Run `~/.oppi/bin/oppi uninstall` instead.

## What it removes

| What | Where |
| --- | --- |
| The background service | macOS: the LaunchAgent `~/Library/LaunchAgents/dev.chaosdonkey.oppi.plist`. Linux: the systemd user service `~/.config/systemd/user/oppi.service`. |
| A server the installer started without a service | The `oppi serve` process recorded in `~/.oppi/serve.pid` (`--no-service`, or Linux without systemd). |
| Linux lingering | Only if Oppi turned it on when it installed the service. If lingering was on before, it stays on. |
| Oppi's Auto-Name entry in Pi's settings | The [Auto-Name](extensions.md#auto-name) package entry in `~/.pi/agent/settings.json`, if you turned it on. Your other Pi settings stay. |
| The `PATH` line in your shell profile | The line the installer added below `# Added by the Oppi installer`, in `~/.zprofile`, `~/.bash_profile`, `~/.bash_login`, `~/.profile`, or `~/.config/fish/conf.d/oppi.fish`. If you changed that line, it stays. |
| The `oppi` link | `~/.local/bin/oppi`, if it still points into `~/.oppi`. |
| The installer's folder | `~/.oppi`: the Node.js it downloaded, the server releases, the launcher, the installer's npm cache, and its logs. |
| Folders the installer created | Such as `~/.local/bin`, if the installer created it and it is now empty. |
| The data folder, if you say yes | `~/.config/oppi`, or `OPPI_DATA_DIR`: config, TLS certificates, paired devices, chats, worktrees, and logs. |

The command removes the service and stops the server first. If another server on the same data folder is still running, such as an `oppi serve` you started in a terminal, it removes nothing else and asks you to stop that server and run it again.

## What stays

- **An npm install.** If you installed with `npm install -g oppi-server`, `oppi uninstall` removes everything above and then shows the command that removes the package: `npm uninstall -g oppi-server`.
- **Pi and its settings.** Oppi runs sessions with [Pi](https://github.com/badlogic/pi-mono). Pi's `~/.pi/agent` (provider sign-ins, sessions, skills, extensions, and settings you changed in Oppi) belongs to Pi and stays. That includes `~/.pi/agent/auto-name.json`, the model you picked for Auto-Name.
- **The sandbox image cache.** Sandbox workspaces keep VM images in `~/.cache/gondolin`. Delete the folder if you no longer use sandboxes.
- **Your repositories.** Worktrees Oppi made live in the data folder; when it is deleted, run `git worktree prune` in a repository to forget them.

## Only the service

`oppi server uninstall` stops and removes the background service and nothing else. Oppi stays installed, and `oppi server install` puts the service back.

## The app

Delete the Oppi app from your iPhone or iPad as you would any app. To remove a device from a server that keeps running, revoke it with `oppi devices` on the server.
