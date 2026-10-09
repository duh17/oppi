# SSH Terminal experiment

SSH Terminal opens an interactive shell on a host saved on this iPhone or iPad. It is an opt-in experiment, off by default. It does not run through the Oppi server and does not change Pi session ownership.

## Set up a host

1. Turn on **Settings → Experiments → SSH Terminal**.
2. Open **Settings → SSH Hosts**. That opens the host list. Opening the list does not dial and does not read the Keychain, so it does not ask for Face ID.
3. Tap **Add**. Enter a host, port (default 22), and username. The host has no default. Enable Remote Login or `sshd` on that host. **Edit** opens the same form for a saved host.
4. Choose **Password** or **This Device’s Key**.
   - **Password:** enter the password at connect. **Save Password** is optional.
   - **This Device’s Key:** copy the public key and add it as one line to `~/.ssh/authorized_keys` on the host. Oppi does not install it for you.
5. Tap **Connect**. Compare the displayed host-key fingerprint with the host’s fingerprint through an independent, trusted channel. Trust it only after they match. Oppi sends no credentials before host-key validation succeeds. You can also tap **Save Host** and connect later from the list.

For example, on a Mac with an Ed25519 host key:

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

After you save a host, **Terminal** appears directly below **MCP Servers** in the workspace sidebar. Tap it to open the same list. Tap a row to connect and open the shell. The password sheet and host-key prompt appear on the list or the form, whichever you tapped Connect from. A row shows `user@host`, the port when it is not 22, and the Run on Connect command, or **Login shell**. Two rows can use the same machine with different Run on Connect commands. Swipe **Delete Host** removes that saved host and its password only. An existing single host moves into the list without a Face ID prompt; its password stays in this phone’s Keychain until the next connect. **Edit Host** in the live terminal opens the form for the connected host. Turning the experiment off hides both entry points and does not create a key. **Tailscale → Check a Machine for Oppi** remains available independently.

## Font and icons

The terminal uses **Settings → Text → Code Font** and **Code Text Size**, like code blocks and tool output. At 100% it is 13 pt. Changing either redraws an open terminal and resizes the remote shell to the new cell size.

Prompt icons from starship, powerlevel10k, oh-my-posh, and similar (Powerline separators, git, folder, and language icons) come from the bundled Nerd Fonts Symbols font, which works with every code font.

## Run on Connect

**Run on Connect** runs one command in the terminal instead of a login shell. This is the same exec-with-TTY request as `ssh -t host 'command'` or OpenSSH `RemoteCommand` with `RequestTTY yes`. Enter `herdr` to attach your Herdr session, or `tmux new -A -s main` for tmux. The connection ends when the command exits and the status names the command; **Reconnect** runs it again. The command must be on the `PATH` that non-interactive SSH commands see. Leave it empty for a normal login shell.

## Input bar, touch, and keyboard

The terminal picks its input from what runs in the foreground. About every two seconds, Oppi runs `ps` in a side command channel on the same connection to find the process in front of this terminal's PTY. A coding agent (`pi`, `claude`, `codex`, `opencode`, `gemini`, `amp`, `aider`, and similar) gets the chat input bar. A Herdr client gets it when Herdr's focused pane runs an agent. Anything else, such as a shell, `vim`, or `tmux`, gets direct terminal typing: the bar is hidden and a tap opens the keyboard with the Esc/Tab/Ctrl/arrow bar. To switch by hand, use **Use Chat Bar** or **Type in Terminal** in the … menu, or the chat button on the terminal keyboard's bar; the automatic choice returns when the foreground program changes.

The chat input bar is Oppi's chat composer. Type or dictate (same dictation as chat), edit, then **Send**: Oppi pastes the text as one block (bracketed paste when the app supports it) and presses Enter. Send with an empty bar presses Enter alone. Autocorrect, capitals, and smart punctuation are off. While the bar is focused, a key strip offers Esc, Ctrl-C, Tab, ↑ and ↓ immediately, and a keyboard button switches to typing straight into the terminal with the Esc/Tab/Ctrl/arrow bar. That switch stays in direct typing. A tap with the keyboard down opens it, including when the app asked for mouse input. While that keyboard is up and the app asked for mouse input, a tap is a click at the cell and the keyboard stays up; hide it with ⌄ on the keyboard bar. Otherwise a tap hides the keyboard. **Use Chat Bar** (in the … menu, or the chat button on the terminal keyboard) returns to the input bar. Starting an agent from the terminal keyboard moves typing to the input bar.

### Program shortcuts

The key strip and the terminal keyboard's bar add buttons for the program in front, named by what they do. Each button sends the key that program has bound right now:

| Program | Buttons (default key) | User file read |
|---|---|---|
| Shell | History (^R), Clear (^L) | none |
| pi | Thinking (⇧Tab), Model (^L), Tools (^O); Stop when interrupt is not Esc | `${PI_CODING_AGENT_DIR:-~/.pi/agent}/keybindings.json` |
| Claude Code | Mode (⇧Tab), Model (⌥P), Transcript (^O), Todos (^T), Background (^B) | `${CLAUDE_CONFIG_DIR:-~/.claude}/keybindings.json`, contexts Global, Chat, Task |
| Codex | Transcript (^T), Effort − (⌥,), Effort + (⌥.); Stop when interrupt is not Esc | `[tui.keymap.*]` in `${CODEX_HOME:-~/.codex}/config.toml` |

The file is read once each time the program takes the foreground, through the same side channel, and follows that program's rules: pi and Codex entries replace an action's keys and `[]` removes it; Claude Code entries add keys, and a default key bound to `null` or to another action stops counting. A missing or unreadable file means the defaults. For Codex only the `tui` tables leave the host, and only table headers, dotted keys, and string arrays are read (not inline tables, profiles, or project `.codex/config.toml`). The variables are those of a non-interactive SSH command, which may differ from the agent's own environment. Actions bound to Esc, ^C, Tab, ↑ or ↓ are not repeated, `super`/`cmd` keys are left out, and Claude Code chords are sent as one write. Other agents get the fixed keys only. Under Herdr, the buttons follow the agent in the focused pane.

Photos and files from **+** or a pasted image are saved on the host before Send, in an owner-only `oppi-ssh` folder under `$TMPDIR` (or `/tmp`), over the same SSH connection. The prompt then lists each file's path on its own line, so the agent can read it. Each file is limited to 32 MB.

- With the keyboard hidden, a tap starts typing: into the terminal when that is the input (a shell, or after the keyboard button or **Type in Terminal**), even if the app asked for mouse input; into the input bar for an agent.
- While the direct keyboard is up and an app asks for mouse input (Herdr, tmux with `mouse on`, many TUIs), a tap is a click at the cell and the keyboard stays up. Hide that keyboard with ⌄ on its bar. A tap hides the keyboard only when the app did not ask for mouse input.
- While the chat bar is the input and an app asks for mouse input, that tap is a click at the cell. Dragging still sends scroll-wheel steps to the app whenever it asked for mouse input.
- Otherwise, dragging reads local history; **Back to Live** returns to the bottom.
- Scrolling does not show or hide the navigation bar. That resize would change the remote terminal's row count, so it is a separate action: **Hide Bar** in the … menu puts it away for more rows, and the chevron at the top brings it back (tap, or pull the chevron down). A broken connection always shows it.

A healthy connection shows no status row. **Edit Host**, **Disconnect**, and **Reconnect** are in the … menu.

## Herdr

When `herdr` is on the host, the terminal checks Herdr's API (`herdr api snapshot`) every few seconds over the same SSH connection, in a separate command channel. A grid button appears in the navigation bar, with a count of agents waiting at an approval or question prompt. It opens a list of workspaces and agents showing whether each is working, needs you, done, or idle. Tapping a row runs `herdr workspace focus` or `herdr agent focus` on the host. Hosts without `herdr` are checked once per connection and then left alone.

## Program status (OSC 7501)

The terminal answers the Program Status Protocol support query (`ESC ] 7501 ; ? ST`), so programs that detect support first, such as Pi 1.1.0, start reporting. Reports (idle, working, done, blocked, error, with an optional app, title, and message) are kept per terminal following the [specification](https://www.superlogical.com/rex/docs/build/program-status): one record per id, a `clear` removes a record and its children, at most 256 records. `working` and `blocked` records are dropped when the shell shows its next prompt (OSC 133 A) or the shell or connection ends; `done` and `error` stay. Reset (RIS) clears everything. Records do not appear anywhere yet. This reply is the only OSC reply the terminal sends; clipboard queries still get none.

## Credentials and host trust

- Profile metadata (host, port, username, sign-in choice, and Run on Connect) is stored in app preferences. Passwords are never stored there or logged. Each saved host has its own id. Changing that host’s hostname, port, username, or sign-in method cannot keep its password, and does not change another host’s password.
- An unsaved password is used for one connection attempt. Reconnect asks for it again.
- A saved password is in the app’s private Keychain, not the app group. It does not sync or migrate to another device. A device passcode is required to save it; reading it at connect requires Face ID, Touch ID, or device-passcode approval. The saved secret is bound to that host’s id, so copying one host’s secret onto another host’s item does not sign in.
- A host saved before the list keeps its password at the previous Keychain item. The next connect reads it, writes the per-host item, and then deletes the previous item. Opening the list does not. If that write fails, the previous item stays.
- On a physical device, the per-device P-256 SSH key is in the Secure Enclave. Signing requires user presence. The simulator uses an explicitly labelled software key. Selecting password sign-in does not create a key.
- Trusted host keys are stored in the app-private, this-device-only Keychain, shared by SSH Terminal and Check a Machine. A changed host key blocks sign-in. **Forget Trusted Key** requires confirmation; independently verify why it changed before trusting its replacement.
- **Delete Host**, including swipe delete on the list, deletes that saved host and its saved password. It does not remove the per-device key or trusted host keys. Trusted host keys stay keyed by host and port. The device key stays one per device. If the host list cannot be read, **Delete Saved Password** removes only the previous single-host password item. It does not search the Keychain.

## Network and reconnect

When Oppi’s in-app Tailscale node is running, `*.ts.net` hosts use that node. Other hosts use direct TCP through your current network, including a system Tailscale VPN if active.

Oppi checks SSH round-trip liveness every 60 seconds by opening and closing an empty session channel, with a 15-second reply timeout. It requests no shell, command, or PTY on that probe. Direct TCP also uses kernel keepalive probes. Failure closes the connection and shows **Disconnected** with **Reconnect**.

Entering the background disconnects the shell. On return, tap **Reconnect**. After a Wi-Fi or cellular path change, Oppi checks the connection with one SSH round trip: a live shell carries on, and a dead one shows **Disconnected** with **Reconnect**. Reconnect always opens a fresh shell; it does not replay input. Use `tmux` on the host if work must survive a disconnect.

## Limits

- Hosts are saved on this device only. No private-key import, keyboard-interactive, or forwarding.
- The SSH library supports Ed25519/ECDSA host and user keys, Curve25519/ECDH key exchange, and AES-GCM encryption. RSA-only and legacy-only servers fail with an unsupported-algorithm error. A server that offers only keyboard-interactive cannot accept password sign-in here.
- Connection, authentication, and terminal-opening waits are bounded. A rejected credential, changed host key, unreachable host, or unsupported algorithm produces a visible error.
- Secure Enclave and biometric approval need physical-device testing. A simulator software key is not evidence of hardware protection.
