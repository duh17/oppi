# Sandbox workspaces

A sandbox workspace runs agent file tools and shell commands in a local [Gondolin](https://www.npmjs.com/package/@earendil-works/gondolin) Linux micro-VM, so an agent can inspect or change a project without broad access to the host filesystem or environment. Network policy is explicit and configurable. Oppi routes `read`, `bash`, `edit`, `write`, `ls`, `find`, and `grep` into the VM.

The host side (Oppi and Pi) runs the model loop, provider authentication, session storage, UI extensions, and server APIs. The guest side (the VM) runs the file tools and shell commands.

## Quick start

QEMU must be installed on the server host (Node.js 22.19+, like the rest of Oppi).

```bash
brew install qemu                 # macOS
sudo apt install qemu-system-arm  # Debian/Ubuntu on ARM64
```

In the app: **Workspaces → +**, turn on **Sandbox**, pick a project path (or leave it empty for a dedicated sandbox folder), create the workspace, and start a new session. The first session boots the VM. The agent sees the workspace at `/workspace/<workspace-slug>`; host paths such as `/Users/alice/...` are not in its prompt or cwd.

## Behavior

- **Folder:** with no path selected, Oppi creates `~/sandbox/<slug>` on the server host and keeps it when you rename the workspace. You browse artifacts on the host mount, and guest `/workspace/<slug>` paths are accepted and mapped.
- **File tools** (`read`, `edit`, `write`, `ls`, `find`, `grep`) are limited to the workspace mount. A path outside it, including `~` and `..` escapes, fails instead of being remapped. Use `bash` to inspect the VM's own filesystem, such as `/etc/os-release`.
- **`bash`** runs in the VM with its cwd in the mount. Host paths are unavailable unless mounted.
- **Secrets:** model API calls run on the host, so the VM needs no provider keys. Provider keys and per-command host environment variables are not forwarded. Pi passes only `PI_PROVIDER`, `PI_MODEL`, `PI_REASONING_LEVEL`, and `PI_SESSION_ID`. Use the workspace's `sandboxConfig.env` for non-secret guest config such as `PATH` and `LANG`, never credentials.
- **Skills and context:** the model sees the workspace's `AGENTS.md` and `CLAUDE.md` (rewritten to sandbox paths), the Oppi workspace prompt from **Workspace Settings → Instructions**, the workspace's `.agents/skills`, and each directory (or symlink to one) in its `.pi/skills`, mounted read-only at `/workspace/<slug>/.pi/skills/<name>/`. Global host files (`~/.pi/agent/AGENTS.md`, global skills) and loose `.md` files in `.pi/skills` are not exposed. A saved Agent that selects any other skill fails to start with `agent_skills_unavailable`. Skills and context files over 1 MiB are skipped, and project `.pi/settings.json` skill filters are not applied. Put sandbox instructions in `AGENTS.md` or the workspace prompt, not global host files.
- **Host extensions** (including an installed `ask`) run in the trusted host process, not the VM, unless they explicitly delegate into the sandbox. Enable them deliberately.

Running sessions keep their cwd and VM until stopped, so start a new session after changing settings that affect cwd, hosts, or environment (a server restart is not needed). Skill mounts are read when the VM boots, so a skill added to `.pi/skills` appears at the next boot. The VM stops 15 minutes after the workspace's last sandbox session stops, and a ready session keeps it running.

## Defaults

| Surface | Default | Change it |
| --- | --- | --- |
| Compute | Commands run in a QEMU Linux micro-VM | Needs QEMU on the server |
| Workspace path | `/workspace/<workspace-slug>` in the VM | The workspace name sets the slug |
| Host filesystem | Only the workspace backing directory is mounted | Pick a project path, or leave blank for `~/sandbox/<slug>` |
| Secret files | Common secret paths are hidden from the mount: `.ssh`, `.aws`, `.config/gcloud`, `.pi`, `.kube` and other directories, plus `.env*`, `.npmrc`, `.git-credentials`, `.docker/config.json`, `.pgpass`, `*.pem`, `*.key`, `*.p12`, `*.pfx` | Keep secrets outside the mounted project |
| Network egress | Omitted `allowedHosts` allows all HTTP/TLS egress | **Allowed Hosts** in Workspace Settings; an empty list denies all |
| Provider secrets | Not injected into the VM | Do not use env |
| Tools | VM-backed `read`, `bash`, `edit`, `write`, `ls`, `find`, `grep`; host `rg` and `fd` are not registered | See below |

## Network access

Open **Workspace Settings → Network Access**, edit **Allowed Hosts**, and tap **Save**. Existing workspaces keep their saved settings. Start a new session after a change.

| Field | Result |
| --- | --- |
| Never edited (`allowedHosts` omitted) | Allow all HTTP/TLS egress (Gondolin's default) |
| Empty | Store `allowedHosts: []`: deny all |
| One host per line, wildcards allowed (`*.github.com`) | Allow those hosts |
| `*` | Allow all |

```text
# allow GitHub API and raw content
api.github.com
raw.githubusercontent.com
```

Allowed hosts can receive any data the guest can read, so treat each one as an exfiltration destination. Do not add `api.openai.com`, `api.anthropic.com`, or another model provider just to make the agent work: model requests happen on the host. Allow a provider only if you want VM commands to call it, and even then the VM holds no credential.

## Tools and extensions

When neither an Agent nor a launch allowlist is set, `workspace.tools` is the fallback allowlist, intersected with the sandbox set (other names are dropped). If it is unset too, all sandbox file tools are active. An Agent or launch allowlist replaces that fallback: file builtins stay guest-backed, selected host-side extension tools stay registered and run on the host, and unknown or stale names are dropped with a session warning. `grep` and `find` are guest versions (Alpine `find`; guest `rg` when present, otherwise `grep`), never host ones. Installed Pi package tools run in the host process.

## MCP servers in a sandbox

A sandbox loads only the global MCP servers (`~/.pi/agent/mcp.json`) that you turn on under **Workspace Settings → MCP Servers**, saved in the workspace's `sandboxConfig.mcpServers` outside the VM, so the agent cannot add servers. The workspace's own `.pi/mcp.json` is never read, and servers that other extensions register with `pi.registerMcpServer` are refused.

| Server | Where it runs | Allowed when |
| --- | --- | --- |
| HTTP (`url`) | Pi's normal transport on the host. OAuth, tokens, and `${NAME}` headers resolve there, so the agent sees only tool results. | The URL's host matches **Allowed Hosts** (same patterns as the VM: unset allows all, empty denies all). A private or local host (loopback, `10/8`, `172.16/12`, `192.168/16`, link-local, `100.64/10` tailnet, IPv6 unique-local and link-local, IPv4 inside IPv6, `localhost`, `*.local`, `*.internal`, `*.home.arpa`, `*.ts.net`) must also be listed exactly, not through a wildcard (IPv6 without brackets, such as `::1`), because the host can reach what the VM cannot. A header or OAuth `clientSecret` starting with `!` (a host shell command) is blocked because the agent can trigger reconnects, and so is `auth.provider`, which can run a provider's `!command` key or extension code. Use MCP OAuth or a `${NAME}` header instead. |
| stdio (`command`) | Inside the VM, started at the workspace's guest folder over stdin and stdout. The command must exist in the guest image (Alpine with `node` and `python3`); `~` is not expanded. | `env` has only literal values. A `$NAME`, `${NAME}`, or `!command` value is blocked, so host secret references never enter the VM. Literal `env` and `args` values do, and the agent can read them. |

A ticked server that is blocked, disabled, or missing from `mcp.json` does not load, and the session's `/mcp` lists why. The phone list has no live status for sandbox servers, because probing would need the VM. A stdio server stops with its session.

Sandboxes run no agent-written code on the host, so they get Pi's `tool-search` but not `codemode`. Servers on the default `codemode` exposure switch to `deferred`, and `tool_search` makes their tools callable; `direct` and `hidden` stay as configured. A workspace **Tools** list turns MCP off, because Pi admits tools by exact name and MCP names are known only after connecting. With picked servers and a Tools list, the session shows a warning; clear the Tools list to use the servers. An Agent or launch allowlist keeps host extension tools without a warning, so list each `mcp__<server>__<tool>` name there, plus `tool_search` for servers not on `direct` exposure.

Trust you take on when you pick a server:

- An HTTP server acts with your authority on that service, even though the token stays on the host.
- Allowed Hosts is checked against the configured URL only. The host-side client follows redirects, and OAuth discovery and refresh contact the provider's authorization server, without rechecking those hosts. A name that resolves to a private address is not caught.
- Large or binary results are saved to the host's temporary folder (owner-only), and the model gets a host path its VM tools cannot open.
- Host extensions you install still run on the host; one that exposes its own code-running tool would bring host code execution back.
- A stdio server the agent can modify in the VM feeds the host MCP client. Its log lines go to `sandbox-mcp-logs/<workspace id>.log` in the Oppi data folder, never the shared `~/.pi/agent/mcp.log` that host agents read.

## Security boundary

Gondolin runs untrusted code in a real Linux VM while host-controlled code mediates I/O. Guest code never runs directly on the host OS. Host files appear only through explicit mounts, which can be read-only and can hide secret paths. HTTP and TLS egress goes through host hooks and allowlists. Internal IP ranges are blocked by default and redirects are rechecked. Other traffic is dropped unless an SSH or mapped-TCP exception is configured. HTTP/2, HTTP/3, QUIC, and WebRTC are not supported. Guest WebSocket upgrades are off.

Gondolin does not defend against a malicious host, VM escape bugs, same-user local attackers, side channels, or denial of service. Default egress is broad until you configure it, so a sandbox does not make untrusted code safe to run without judgment. Pi itself ships no sandbox; Oppi's is broader than Pi's example `sandbox` extension because it routes the file tools and bash into the same VM-backed workspace.

## Troubleshooting

- **QEMU is missing:** install QEMU on the server host and start a new session.
- **A command should not reach the network:** clear **Allowed Hosts** to deny all, or add only the hosts it needs.
- **A command cannot reach an expected host:** add it to **Allowed Hosts** and start a new session. A server restart is not required.
- **A command cannot read `.env` or `.ssh`:** this is expected, because common secret paths are hidden.
- **A file tool cannot read `/etc/passwd` or another absolute path:** this is expected. Use `bash` for guest-only system files.
- **The session shows the wrong cwd:** stop it and start a new session so it picks up the sandbox cwd.

## Upstream references

- [Gondolin repository](https://github.com/earendil-works/gondolin) and [documentation](https://earendil-works.github.io/gondolin/)
- [Security design](https://earendil-works.github.io/gondolin/security/), [networking](https://earendil-works.github.io/gondolin/sdk-network/), and [limitations](https://earendil-works.github.io/gondolin/limitations/)
