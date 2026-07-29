# Sandbox workspaces

Sandbox workspaces run agent file tools and shell commands in a local Gondolin Linux micro-VM. They let an agent inspect or modify a project without giving generated code broad access to the host filesystem or host environment, while keeping network policy explicit and configurable.

Oppi uses [`@earendil-works/gondolin`](https://www.npmjs.com/package/@earendil-works/gondolin) as the sandbox runtime and Pi's SDK tool plumbing to route `read`, `bash`, `edit`, and `write` into the VM.

## Quick start

Prerequisite: install QEMU on the server host.

```bash
brew install qemu                 # macOS
sudo apt install qemu-system-arm  # Debian/Ubuntu on ARM64
```

Create a sandbox workspace from the app:

1. Open **Workspaces**.
2. Tap **+**.
3. Turn on **Sandbox**.
4. Pick a project path, or leave it empty for a dedicated sandbox folder.
5. Create the workspace.
6. Start a new session.

The first session boots the workspace VM. In that session, the agent sees the workspace at:

```text
/workspace/<workspace-slug>
```

Host paths such as `/Users/alice/...` are not part of the sandbox prompt or tool cwd.

## Expected behavior

A sandbox workspace has two parts:

- **Trusted host side:** Oppi and Pi run the model loop, provider authentication, session storage, UI extensions, and server APIs.
- **Sandbox guest side:** Gondolin runs agent file tools and shell commands in the VM.

New sandbox sessions behave as follows:

- The visible cwd is `/workspace/<workspace-slug>`.
- If no host path is selected, Oppi creates a backing directory under `~/sandbox/<slug>` on the server host.
- `read`, `edit`, and `write` use Gondolin's guest filesystem API and reject paths outside the configured workspace mount.
- `bash` runs inside the VM with cwd mapped to the workspace mount. Shell commands can inspect the guest filesystem, but host paths remain unavailable unless explicitly mounted.
- Model API calls run from the host process; the VM does not need provider API keys for normal agent operation.
- Oppi/Pi provider API keys and per-command host environment variables are not forwarded into the VM by default. Pi may forward only non-secret session metadata (`PI_PROVIDER`, `PI_MODEL`, `PI_REASONING_LEVEL`, and `PI_SESSION_ID`) per command; workspace sandbox environment variables are injected at VM creation time.
- Network egress follows Gondolin's default: omitted `allowedHosts` means allow all. Set an explicit allowlist, or set `allowedHosts: []` to deny all.
- Selected skills are mounted read-only under `/workspace/<slug>/.pi/skills/<name>/`.
- Workspace-local `AGENTS.md` and `CLAUDE.md` are rewritten to sandbox paths before they are shown to the model.
- Global host agent instructions are not exposed to sandbox sessions.

Running sessions keep their current cwd and VM until restarted. Start a new session after changing sandbox settings that affect cwd, mounts, or network policy.

## Default safety model

Sandbox workspaces separate host and guest environments. Configure network access deliberately for the task.

| Surface          | Default                                                                                                                                                                                    | How to change it                                                              |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------- |
| Compute          | Commands run in a QEMU Linux micro-VM                                                                                                                                                      | Requires QEMU on the server                                                   |
| Workspace path   | `/workspace/<workspace-slug>` inside the VM                                                                                                                                                | Workspace name determines the slug                                            |
| Host filesystem  | Only the selected workspace backing directory is mounted                                                                                                                                   | Pick a project path, or leave blank for `~/sandbox/<slug>`                    |
| Secret files     | Common secret paths are hidden from the workspace mount, including `.env*`, `.npmrc`, `.ssh`, `.aws`, `*.pem`, and `*.key`                                                                 | Keep secrets outside the mounted project when possible                        |
| Network egress   | Gondolin default: omitted `allowedHosts` allows all HTTP/TLS egress                                                                                                                        | Edit **Allowed Hosts** in the workspace editor; use an empty list to deny all |
| Host environment | Per-command host env is ignored except non-secret Pi session metadata (`PI_PROVIDER`, `PI_MODEL`, `PI_REASONING_LEVEL`, `PI_SESSION_ID`); workspace sandbox env is injected at VM creation | Configure explicit sandbox env on the workspace                               |
| Provider secrets | Not injected into the VM                                                                                                                                                                   | Future secret bridging must be explicit and scoped                            |
| Tools            | VM-backed `read`, `bash`, `edit`, `write`                                                                                                                                                  | Server/API/admin can set an authoritative tool allowlist                      |
| Context          | Workspace-local context is allowed; global host agent config is hidden                                                                                                                     | Put sandbox-specific instructions in the workspace or Oppi workspace prompt   |

Existing sandbox workspaces keep their saved network settings. Omitted `allowedHosts` and `allowedHosts: ["*"]` both allow all. Clear the Allowed Hosts field to store `allowedHosts: []` and deny all.

## Configure network access

Open **Edit Workspace → Sandbox → Allowed Hosts**.

- Omitted `allowedHosts`: follow Gondolin's default and allow all HTTP/TLS egress.
- Empty field in the editor: store `allowedHosts: []` and deny all network egress.
- One host per line: allow those hosts.
- Wildcards are supported, for example `*.github.com`.
- `*` also allows all HTTP/TLS egress.

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
# allow all, same effective behavior as omitted allowedHosts
*
```

Allowed hosts can receive any data the guest can read. Treat every allowed destination as an exfiltration destination.

## Provider keys and guest network are separate

Do not add `api.openai.com`, `api.anthropic.com`, or another model provider host just to make the agent work. Normal model requests happen on the trusted host side.

Allow a provider host only if you intentionally want commands inside the VM to call that provider. Even then, the VM has no provider credential unless you explicitly provide one through a future scoped secret bridge or a workspace-specific environment variable.

## Configure tools and extensions

Oppi's sandbox replaces Pi's host-backed built-in tools with VM-backed versions for:

- `read`
- `bash`
- `edit`
- `write`

If `workspace.tools` is unset, those tools are active by default. If `workspace.tools` is set, it becomes an allowlist across built-in, custom, and extension tools.

File tools are workspace-scoped. A `read`, `edit`, or `write` request for a path outside the workspace fails instead of being remapped to a guest absolute path. Use `bash` when you intentionally need to inspect the VM's own Linux filesystem, such as `/etc/os-release`.

Host-side extensions are different from VM tools. Installed Pi package tools, including an installed `ask` extension, run in the trusted Oppi/Pi host process unless they explicitly delegate work into the sandbox. Enable extensions deliberately.

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

## Security boundary and limitations

Gondolin's security model runs untrusted code in a real Linux VM while host-controlled code mediates I/O.

Relevant Gondolin guarantees and constraints:

- Guest code does not directly run on the host OS.
- Host filesystem access exists only through explicit VFS mounts.
- `RealFSProvider` exposes a host directory; `ReadonlyProvider` makes mounts read-only; `ShadowProvider` can hide secret paths.
- HTTP/TLS egress is mediated by host hooks and host allowlists.
- Raw Gondolin treats omitted `allowedHosts` as allow-all. Oppi follows that default. Set `allowedHosts: []` to deny all.
- `createHttpHooks` blocks internal IP ranges by default and rechecks redirects.
- Non-HTTP/TLS traffic is dropped unless an explicit SSH or mapped-TCP exception is configured.
- HTTP/2, HTTP/3, QUIC, and WebRTC are not supported today.
- Gondolin is not a defense against a malicious host, VM escape bugs, same-user local attackers, side channels, or denial of service.

The sandbox keeps provider secrets out of the VM by default and hides common workspace secret paths, but default network egress is broad unless you configure it. It does not make untrusted code safe to run without judgment.

## How this differs from Pi's sandbox story

Pi itself does not ship a first-party sandbox boundary. Pi keeps the core small and gives integrators building blocks:

- tool allowlists: `--tools`, `--no-builtin-tools`, `--no-tools`
- context controls: `--no-context-files`, `--system-prompt`, `--append-system-prompt`
- offline startup mode: `PI_OFFLINE=1`
- extension hooks such as `tool_call` and `user_bash`
- pluggable tool operations for delegating tools to SSH, containers, or other runtimes
- example extensions for approval prompts, protected paths, and sandboxed bash

Pi's example `examples/extensions/sandbox/` uses `@anthropic-ai/sandbox-runtime` to wrap bash commands with OS-level sandboxing. That example is useful as a reference for overriding tools. Oppi's sandbox is broader: it uses Gondolin and routes file tools plus bash into the same VM-backed workspace.

## Troubleshooting

- **QEMU is missing:** install QEMU on the server host and start a new session.
- **A command should not reach the network:** clear **Allowed Hosts** to deny all, or add only the required hosts.
- **A command cannot reach an expected host:** add that host to **Allowed Hosts**, then start a new session if the VM was already running.
- **A command cannot read `.env` or `.ssh`:** this is expected. Common secret paths are hidden from the workspace mount.
- **A file tool cannot read `/etc/passwd` or another absolute path:** this is expected. File tools are limited to the workspace mount; use `bash` to inspect guest-only system files when needed.
- **The session shows the wrong cwd:** stop that session and start a new one so the session picks up the sandbox cwd.

## Upstream references

- Gondolin package: <https://www.npmjs.com/package/@earendil-works/gondolin>
- Gondolin repository: <https://github.com/earendil-works/gondolin>
- Gondolin documentation: <https://earendil-works.github.io/gondolin/>
- Gondolin security design: <https://earendil-works.github.io/gondolin/security/>
- Gondolin VFS providers: <https://earendil-works.github.io/gondolin/vfs/>
- Gondolin networking: <https://earendil-works.github.io/gondolin/sdk-network/>
- Gondolin limitations: <https://earendil-works.github.io/gondolin/limitations/>
- Pi README and extension docs in `@earendil-works/pi-coding-agent`
