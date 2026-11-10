# Run tools on another machine

A subagent can run its commands and file edits on another computer, such as a Mac mini with Xcode or a Linux build box, while its conversation stays on your Oppi server. Use it for work that does not fit the server's machine: heavy builds, tests that need another OS, or hardware that stays where it is.

This page calls the machine `build-mac`.

## What runs where

| On the Oppi server                                   | On the other machine                                     |
| ---------------------------------------------------- | -------------------------------------------------------- |
| The conversation, the model calls and their API keys | The subagent's `bash`, `read`, `edit`, and `write` calls |
| The parent session, wake-ups, and the thread         | Its background jobs                                      |
| Skills, MCP servers, and the app's connection        | A git worktree of your project, under `~/.oppi/pool`     |
| Your repository, where the work comes back           | A small helper program that Oppi installs                |

The server connects to the machine over SSH. The machine never connects back, and it needs no Pi, Oppi, or model keys.

## Requirements

On the server:

- [Durable Sessions](usage.md#durable-sessions) on. Only a durable session's `subagent` tool can start a worker on a machine.
- A host workspace in a git repository. Sandbox sessions cannot use machines.

On the machine:

- **SSH login.** On macOS, turn on **System Settings → General → Sharing → Remote Login**. The server must reach the machine by name or address, for example over Tailscale.
- **`git`.** Oppi keeps a copy of your repository and the workers' worktrees in `~/.oppi/pool` of the account you log in as.

Oppi checks nothing else. Toolchains, a git name and email for commits, disk space, and sleep settings are your setup. A command that needs a missing tool fails with that tool's own error. The worker uses the `PATH` of the account's login shell, which Oppi reads once when you add the machine. To read it again after you install something, run `oppi machines add` again.

## Add a machine

On the server, as the account that runs Oppi:

```bash
oppi machines add build-mac --ssh alex@build-mac.local
```

`--ssh` takes `[user@]host[:port]`. Without a user, Oppi uses the server account's name. The name `build-mac` is yours to pick: lowercase letters, digits, and dashes.

`add` then:

1. Creates this server's own SSH key (once) and shows the line for the machine's `~/.ssh/authorized_keys`. The line starts with `restrict`, which blocks port, agent, and X11 forwarding. With `--from <address>`, the line becomes `restrict,from="<address>"` and the machine accepts the key only from that address.
2. Asks to install the line with your own `ssh` and its config. `--yes` installs it without asking. If you say no, add the line yourself and confirm.
3. Checks the machine's host key. If your `~/.ssh/known_hosts` has the same key, Oppi trusts it and says so. If it has a different key, or marks the key `@revoked`, `add` stops. Otherwise Oppi shows the fingerprint and asks you to confirm it; `--host-key SHA256:…` confirms it up front.
4. Logs in with the new key, installs the helper in `~/.pi/mobile/tools` on the machine, and reads the login `PATH`.
5. Tests the connection: it connects and runs one command. Oppi saves the machine only if this test passes.

Without a terminal, `add` cannot ask, so pass `--yes` and `--host-key`.

Other commands:

| Command                          | What it does                                                                                     |
| -------------------------------- | ------------------------------------------------------------------------------------------------ |
| `oppi machines test build-mac`   | Runs the connection test again and saves the result. Never prompts. Exits 1 when the test fails. |
| `oppi machines list`             | Shows each machine, its last test, and its running workers.                                      |
| `oppi machines remove build-mac` | Forgets the machine. See [Remove a machine](#remove-a-machine).                                  |
| `oppi doctor`                    | Adds one line per machine from its last test. It does not connect.                               |

The `machines` commands take `--json` and work while the server is stopped.

## Start a worker on it

A parent session starts a worker with the `subagent` tool, `host`, and `worktree`. Ask in plain words:

> Start a subagent named `suite` on `build-mac` with a new worktree. It should run the server tests and fix what fails.

The tool call is `subagent spawn` with `host: "build-mac"` and `worktree: "new"` (or a branch name). Oppi then:

1. Pushes the parent's current commit to a bare mirror of your repository on the machine, `~/.oppi/pool/<workspace>.git`. The first worker on a machine copies the whole repository, which can take a few minutes; the spawn waits for it. This push skips your repository's git hooks, because it is Oppi's own transport to a mirror it owns. Your own commits and pushes still run them.
2. Adds a worktree for the worker under `~/.oppi/pool/worktrees`.
3. Runs the worker there. Its prompt says that paths, programs, and `localhost` mean the machine.
4. Fetches the worker's branch into your repository on the server when the worker ends: when it finishes, fails, or you stop it. The branch is a normal local branch with no worktree on the server. Merge it, or check it out to review it.

Only committed work comes back. Changes the worker did not commit stay in the worktree on the machine.

The worker's row in `subagent list` and in its answers shows where the branch is:

| Row                                                             | Meaning                                                                            |
| --------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `worktree: <branch> · on build-mac · 2 commits ahead · fetched` | The server has the branch with the worker's commits.                               |
| `worktree: <branch> · on build-mac · no commits`                | The worker made no commits, so there is no branch to fetch and none on the server. |
| `worktree: <branch> · on build-mac · not fetched`               | The fetch failed, usually because the machine was offline.                         |

`list` and the parent's answers fetch again while a worker runs and after a failed fetch. After a failed fetch, they wait a minute before they ask that machine again.

The spawn fails with a message when:

- `host` names a machine that is not set up, or that failed its last test.
- `worktree` is missing, or names an existing worktree id (that worktree is on the server).
- A branch you name already exists in your repository. (`"new"` picks a free name.)
- The parent is a sandbox session.

## What is different in a worker on a machine

A worker on a machine is a normal session in the app, with these limits:

- **Files and diffs:** the app cannot show its files or diffs. Those screens say "This session's files are on build-mac." Review its commits on the server after they come back.
- **Fork:** you cannot fork it.
- **Tools:** it has `bash`, `read`, `edit`, and `write`, but not `ls`, `find`, or `grep`, which search the server's disk. It runs `ls`, `find`, or `rg` through `bash` instead.
- **Skills:** they stay on the server. The worker sees each skill as `skill://<name>/SKILL.md` and reads it with `read`, only inside that skill's folder. `/skill:` commands work as usual.
- **MCP servers:** they run on the server, as for any session, and cannot see the machine's files.
- **The `oppi` command:** Oppi does not install it on the machine. If the machine runs its own Oppi server, `oppi` there talks to that server, not to this one. To start more work, the worker uses the `subagent` tool.

## When the connection drops

The worker's commands stop when its connection stops: when the server restarts, when the machine sleeps or loses its network, or after 30 seconds without traffic. A command that was running is gone. Files and commits stay on the machine, and the worker's next command opens a new connection. Only a process that moves itself out of its process group (for example with `setsid`) keeps running.

Because of this, a long build that must survive a server restart does not fit yet. Test runs, scouting, and edits do.

## Security

The key gives a full shell as the account you log in as. `restrict` blocks forwarding, not commands. If that account can reach more than you want a subagent to reach, create a separate account for Oppi on the machine and use it in `--ssh`.

The key belongs to this server, not to you. Removing it does not touch your own logins, and the machine's SSH log shows Oppi's logins apart from yours.

Oppi keeps the machine's host key in its own known-hosts file. It never replaces a key on its own and refuses to connect when the key changes. Its connections do not read your `~/.ssh/config`; only `add` and `remove` use your own `ssh` to install or remove the key line.

## Remove a machine

```bash
oppi machines remove build-mac
```

`remove` refuses while a worker runs on the machine or a worker's branch is not fetched yet; `--force` removes it anyway. It asks to delete the key line from the machine's `authorized_keys` with your own `ssh` (`--yes` does it without asking). If you say no, it prints the key so you can delete that line yourself. It also forgets the host key.

The mirror and worktrees in `~/.oppi/pool` and the helper in `~/.pi/mobile/tools` stay on the machine. Delete those folders when you no longer need them.

## On macOS

- **Full Disk Access:** Oppi's worktrees in `~/.oppi/pool` need none. A command that reads Documents, Desktop, or Downloads does: give SSH access in **System Settings → Privacy & Security → Full Disk Access** (add `sshd-keygen-wrapper`), or turn on **Allow full disk access for remote users** in the Remote Login settings.
- **Keychain:** the login keychain is locked over SSH. A build that needs a signing identity or stored credentials must unlock it or use another keychain.
- **Sleep:** a sleeping Mac drops the connection. Oppi does not keep it awake; change its energy settings if workers need it.

## Errors

| Message                                                    | What to do                                                                                                                                         |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `build-mac is offline or unreachable; its files are kept.` | Check the machine and the network, then run `oppi machines test build-mac`. The worker's next command reconnects.                                  |
| `build-mac's host key changed or is not trusted.`          | Make sure the machine was reinstalled, not replaced. Then run `oppi machines remove build-mac --force` and add it again.                           |
| `build-mac refused Oppi's key`                             | The `authorized_keys` line is missing or edited, or the server's address does not match `--from`. Run `oppi machines add build-mac --ssh …` again. |
| `Could not install Oppi's helper on build-mac: …`          | The reason follows. Usually disk space, a read-only home folder, or none of `sha256sum`, `shasum`, or `openssl` on the machine.                    |
| `Unknown machine "…"` or `… failed its last check`         | Run `oppi machines list`, or `oppi machines test <name>` and fix what it reports.                                                                  |
