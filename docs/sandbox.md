# Sandbox workspaces

Sandbox workspaces run Oppi sessions inside a Gondolin Linux micro-VM instead of executing tools directly on the host. Use them when you want the agent to inspect or change a project without giving generated code broad access to your host filesystem, host environment, or network.

Oppi uses Gondolin for the sandbox boundary and Pi's SDK tool plumbing to route `read`, `bash`, `edit`, and `write` into the VM.

## Quick start

Prerequisite: install QEMU on the server host.

```bash
brew install qemu              # macOS
sudo apt install qemu-system-arm # Debian/Ubuntu on ARM64
```

Create a sandbox workspace from the app:

1. Open **Workspaces**.
2. Tap **+**.
3. Turn on **Sandbox**.
4. Pick a project or leave the path empty.
5. Create the workspace.
6. Start a session.

The first session boots a VM for that workspace. Inside the session, the agent sees the workspace at:

```text
/workspace/<workspace-name>
```

Host paths such as `/Users/alice/...` are not part of the sandbox prompt or tool cwd.

## Default safety model

New sandbox workspaces start restrictive. Loosen them only when the task needs it.

| Surface | Default | How to change it |
| --- | --- | --- |
| Compute | Runs commands in a QEMU Linux micro-VM | Requires QEMU on the server |
| Workspace path | `/workspace/<workspace-name>` inside the VM | Workspace name determines the slug |
| Host filesystem | Only the selected workspace backing directory is mounted | Pick a project path, or leave blank for a dedicated `~/sandbox/<slug>` backing directory |
| Secret files | Common secret paths are hidden from the workspace mount, including `.env*`, `.npmrc`, `.ssh`, `.aws`, `*.pem`, and `*.key` | Keep secrets outside the mounted project when possible |
| Network egress | Denied: `allowedHosts: []` | Edit **Allowed Hosts** in the workspace editor |
| Secrets | No Oppi/Pi provider API keys are injected into the VM by default | Future explicit secret bridge only |
| Tools | VM-backed `read`, `bash`, `edit`, `write` | Server/API/admin can set an authoritative tool allowlist |
| Context | Workspace-local `AGENTS.md` / `CLAUDE.md` are allowed; global host agent config is hidden | Put sandbox-specific instructions in the workspace or Oppi workspace prompt |

Existing sandbox workspaces keep their saved network settings. If an older workspace has `allowedHosts: ["*"]`, clear the Allowed Hosts field to return to deny-all.

## Configure network access

Open **Edit Workspace → Sandbox → Allowed Hosts**.

- Empty field: deny all network egress.
- One host per line: allow those hosts.
- Wildcards are supported, for example `*.github.com`.
- `*` allows all HTTP/TLS egress and is rarely the right default.

Examples:

```text
# deny all

```

```text
# allow GitHub API and raw content
api.github.com
raw.githubusercontent.com
```

```text
# broad, use only when you intentionally accept exfiltration risk
*
```

Allowed hosts can receive any data the guest can read. Treat every allowed destination as an exfiltration destination.

## Configure tools and extensions

Oppi's sandbox replaces Pi's host-backed built-in tools with VM-backed versions for:

- `read`
- `bash`
- `edit`
- `write`

If `workspace.tools` is unset, those tools are active by default. If `workspace.tools` is set, it becomes an allowlist across built-in, custom, and extension tools.

Host-side extensions are different from VM tools. Extensions such as `ask`, `subagents`, `voice`, or installed Pi package tools run in the trusted Oppi/Pi host process unless they explicitly delegate work into the sandbox. Enable them deliberately.

## Context files in sandbox workspaces

Pi normally loads global and project context files:

- `~/.pi/agent/AGENTS.md`
- parent-directory `AGENTS.md` / `CLAUDE.md`
- project `AGENTS.md` / `CLAUDE.md`
- `.pi/SYSTEM.md` / `APPEND_SYSTEM.md`

Sandbox workspaces do not expose the global host agent files to the model. Oppi uses a sandbox-specific base prompt and then allows:

- workspace-local `AGENTS.md` / `CLAUDE.md`, rewritten to sandbox paths
- the Oppi workspace prompt from the workspace editor
- selected skills, mounted read-only under `/workspace/<slug>/.pi/skills/<name>/`

Put public project instructions in `AGENTS.md`. Put workspace-specific operating instructions in the Oppi workspace prompt. Do not rely on global host agent files for sandbox behavior.

## What Gondolin provides

Gondolin's security model is: untrusted code runs in a real Linux VM, while host-controlled code mediates I/O.

Relevant Gondolin guarantees and constraints:

- Guest code does not directly run on the host OS.
- Host filesystem access exists only through explicit VFS mounts.
- `RealFSProvider` exposes a host directory; `ReadonlyProvider` makes mounts read-only; `ShadowProvider` can hide secret paths.
- HTTP/TLS egress is mediated by host hooks and host allowlists.
- `allowedHosts: undefined` means allow all in raw Gondolin; Oppi passes an explicit empty list for deny-all.
- `createHttpHooks` blocks internal IP ranges by default and rechecks redirects.
- Non-HTTP/TLS traffic is dropped unless an explicit SSH or mapped-TCP exception is configured.
- HTTP/2, HTTP/3, QUIC, and WebRTC are not supported today.
- Gondolin is not a defense against a malicious host, VM escape bugs, same-user local attackers, side channels, or denial of service.

## How this differs from Pi's sandbox story

Pi itself does not ship a first-party sandbox boundary. Pi keeps the core small and gives integrators building blocks:

- tool allowlists: `--tools`, `--no-builtin-tools`, `--no-tools`
- context controls: `--no-context-files`, `--system-prompt`, `--append-system-prompt`
- offline startup mode: `PI_OFFLINE=1`
- extension hooks such as `tool_call` and `user_bash`
- pluggable tool operations for delegating tools to SSH, containers, or other runtimes
- example extensions for permission gates, protected paths, and sandboxed bash

Pi's example `examples/extensions/sandbox/` uses `@anthropic-ai/sandbox-runtime` to wrap bash commands with OS-level sandboxing. That example is useful as a reference, but it mostly demonstrates how to override tools. Oppi's sandbox is broader: it uses Gondolin and routes file tools plus bash into the same VM-backed workspace.

## Teaching users

Use this framing in product copy and docs:

1. **Start with the promise:** “Run this workspace in an isolated Linux VM.”
2. **Show the visible result:** “The agent works in `/workspace/<name>`, not your host home directory.”
3. **Name the default:** “Network is off until you allow hosts.”
4. **Teach one safe exception:** “Add `api.github.com` when a task needs GitHub API access.”
5. **Warn about allowed hosts:** “Anything the VM can read can be uploaded to an allowed host.”
6. **Explain host-side extensions separately:** “Some tools are VM-backed; extensions may still run on the server.”

Short user-facing version:

> Sandbox workspaces run agent commands in a local Linux micro-VM. Files live under `/workspace/<name>` inside the VM. Network access starts off; add allowed hosts only when a task needs them. Avoid `*` unless you intentionally trust any destination to receive workspace data.

## References

- Gondolin documentation: <https://earendil-works.github.io/gondolin/>
- Gondolin security design: <https://earendil-works.github.io/gondolin/security/>
- Gondolin VFS providers: <https://earendil-works.github.io/gondolin/vfs/>
- Gondolin networking: <https://earendil-works.github.io/gondolin/sdk-network/>
- Gondolin limitations: <https://earendil-works.github.io/gondolin/limitations/>
- Pi README and extension docs in `@earendil-works/pi-coding-agent`
