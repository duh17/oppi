# Run tools on another machine

A subagent can run its shell commands and file edits on another computer, such as a Mac mini with Xcode or a Linux build box, while the conversation stays on your Oppi server. This is for work the server's own machine is a poor fit for: heavy builds, test suites that need another OS, hardware you do not want to move.

This page uses `build-mac` as the machine's name.

## What runs where

| On the Oppi server                                   | On the other machine                                     |
| ---------------------------------------------------- | -------------------------------------------------------- |
| The conversation, the model calls and their API keys | The subagent's `bash`, `read`, `edit`, and `write` calls |
| Wake-ups, the parent session, the thread             | Its background jobs                                      |
| Skills, MCP servers, and the Oppi app's connection   | A git worktree of your project, in `~/.oppi/pool`        |
| Landing the work                                     | A small helper program that Oppi installs                |

Only the parent session starts work: the server connects to the machine over SSH, and the machine never connects back. Nothing on the machine needs Pi, Oppi, or any model key.

A session that runs on a machine is a normal session in the app, with these limits:

- **Files:** the app cannot browse or diff its files, because they are on the other machine. The file and diff screens answer "This session's files are on build-mac." Its commits come back to the server's repository when it finishes, and you review them there.
- **Fork:** you cannot fork it.
- **Tools:** it has `bash`, `read`, `edit`, and `write`, but no `ls`, `find`, or `grep`; it uses `ls`, `find`, and `rg` through `bash`.
- **`oppi` command:** Oppi does not install it there, and the worker is not identified to this server. If the machine has its own Oppi, its `oppi` talks to that server, not to this one. The subagent tool starts further work.

## What the machine needs

- **SSH (Remote Login):** on macOS, turn on **System Settings → General → Sharing → Remote Login**. The server must be able to reach it by name or address, for example over Tailscale.
- **`git`:** Oppi keeps a mirror of your repository and worktrees under `~/.oppi/pool` in the account's home folder.
- **Everything else is yours.** Oppi does not inspect or manage the machine: toolchains, a git identity for commits, disk space, and sleep settings are your setup, and a command that needs something missing fails with that tool's own error. The subagent runs with the `PATH` of the machine's login shell, which Oppi captures once when you add the machine; run `oppi machines add` again to capture it anew. The login shell can be fish or zsh.

## Set it up

On the server, as the account that runs Oppi:

```bash
oppi machines add build-mac --ssh alex@build-mac.local
```

`add` does the following, and saves the machine only if the connection test passes:

1. Creates this server's own SSH key (once) and shows the line to put in the machine's `~/.ssh/authorized_keys`. It starts with `restrict`, so the key cannot forward ports or an agent. With `--from <address>` it also accepts the key only from that address.
2. Offers to install the line with your own `ssh` (it asks once; `--yes` answers for you). Otherwise you paste it yourself.
3. Shows the machine's host key. If your `~/.ssh/known_hosts` already lists the same key, Oppi trusts it and says so. Otherwise it shows the fingerprint and asks you to confirm it (`--host-key SHA256:…` confirms it up front).
4. Logs in with the new key, installs its helper in `~/.pi/mobile/tools` on the machine, and records the machine's `PATH`.
5. Tests the connection: it connects and runs one command.

`oppi machines test build-mac` repeats that test and never prompts. It exits with 1 if it fails.

`oppi machines list` shows each machine, its last test, and how many workers run on it. `oppi doctor` adds one line per machine from the last test, without touching the network.

## Use it

A parent session starts a worker with the subagent tool's `host` argument, together with `worktree`:

> Start a subagent named `suite` on `build-mac` with a new worktree. It should run the server tests and fix what fails.

In tool terms: `subagent spawn` with `host: "build-mac"` and `worktree: "new"` (or a branch name). Oppi then:

1. Keeps a bare mirror of your repository on the machine (`~/.oppi/pool/<workspace>.git`) and pushes your current commit to it from the server.
2. Adds a worktree of it for the child, under `~/.oppi/pool/worktrees`.
3. Runs the child there. In its prompt, paths, programs, and `localhost` mean the machine.
4. When the child finishes (or fails, or you stop it), fetches its branch into your repository. The branch is an ordinary local branch there, with no worktree on the server: merge it, or check it out to review it. The parent's answer and `list` fetch again if the machine was offline at that moment. The first worker on a machine copies the repository to it, which can take minutes, and the spawn shows that while it runs.

The child's `list` row and answers say `worktree: <branch> · on build-mac · 2 commits ahead · fetched`. Work that is not committed on the machine is not in the branch.

Spawning is refused, with a message, when `host` names a machine that is not set up or failed its last test, when `worktree` is missing, when `worktree` is an existing worktree id (those are on the server), and from a sandbox session.

## If the connection drops

The commands of a worker die when the connection dies: when the server restarts, when the machine sleeps or loses its network, and after 30 seconds without traffic. Committed work and the worktree stay on the machine. A command that was running when the link dropped is gone; the worker's next command starts a new connection. A process that detaches itself from its process group can outlive the connection.

Long builds that must survive a server restart do not fit this yet. Server test files, scouting, and edits do.

## Skills, MCP, and `oppi`

- **Skills** stay on the server. The worker sees each skill as a `skill://<name>/SKILL.md` location and reads it with `read`, from the skill's own folder on the server only. `/skill:` commands work as usual.
- **MCP servers** keep running on the server, as for any session. A tool that needs the machine's files does not see them.
- **The `oppi` command** on the machine, if there is one, belongs to that machine's own server, so the worker cannot manage this server's sessions with it.

## Safety

The key is a full shell as that user. `restrict` blocks forwarding, not commands. If the machine holds more than you want a subagent to reach, create a separate account for Oppi on it and use that account in `--ssh`. The key is this server's own, not your personal one, so revoking it does not touch your logins, and the machine's SSH log shows Oppi's logins separately.

Oppi pins the machine's host key in its own known-hosts file, never replaces a key silently, and refuses to connect if the key changes. It reads none of your `~/.ssh/config` when it connects.

Revoke a machine with:

```bash
oppi machines remove build-mac
```

It refuses while a worker runs there or a branch is not fetched yet (`--force` overrides). It offers to remove the key from the machine's `authorized_keys` with your own `ssh`; without that, it prints the line to delete. It also forgets the host key. Worktrees and the mirror under `~/.oppi/pool` stay on the machine; delete that folder when you no longer need it.

## On macOS

- **Full Disk Access:** a project in Documents, Desktop, or Downloads is protected. Give the SSH service access (**Privacy & Security → Full Disk Access**, add `sshd-keygen-wrapper`, or turn on **Allow full access for remote users** in the Remote Login settings), or keep projects elsewhere.
- **Keychain:** the login keychain is locked over SSH. Builds that need signing identities or stored credentials must unlock it or use a different keychain.
- **Sleep:** a sleeping Mac drops the connection. Oppi does not keep it awake; change the machine's energy settings if workers need it.

## Errors

| Message                                                    | What to do                                                                                                                                            |
| ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `build-mac is offline or unreachable; its files are kept.` | Check the machine and the network, then run `oppi machines test build-mac`. The next command reconnects.                                              |
| `build-mac's host key changed or is not trusted.`          | Check that the machine was reinstalled and not replaced. Then `oppi machines remove build-mac --force` and add it again.                              |
| `build-mac refused Oppi's key`                             | The `authorized_keys` line is missing, was edited, or comes from an address `--from` does not allow. Run `oppi machines add build-mac --ssh …` again. |
| `Could not install Oppi's helper on build-mac: …`          | The reason follows. Usually disk space, a read-only home folder, or no `sha256sum`/`shasum`.                                                          |
| `Unknown machine "…"` / `… failed its last check`          | `oppi machines list`, or `oppi machines test` and fix what it reports.                                                                                |
