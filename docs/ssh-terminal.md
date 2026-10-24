# SSH Terminal

SSH Terminal opens an interactive shell on a host saved on this iPhone or iPad. It connects straight from the device, not through the Oppi server, and does not change Pi session ownership.

## Set up a host

1. Open **Settings → SSH Hosts**, or **Terminal** below **MCP Servers** in the workspace sidebar. Opening the list does not dial and does not read the Keychain, so it asks for no Face ID.
2. Tap **Add**. Enter a host, port (default 22), and username. The host has no default. Enable Remote Login or `sshd` on it. **Edit** reopens the form for a saved host.
3. Choose **Password** or **This Device's Key**.
   - **Password:** enter it at connect. **Save Password** is optional.
   - **This Device's Key:** copy the public key and add it as one line to `~/.ssh/authorized_keys` on the host; Oppi does not install it. A **Sudo Password** is optional, for [Fill Password](#filling-a-password).
4. Tap **Connect**. Compare the displayed host-key fingerprint with the host's through an independent channel, and trust it only if they match. Oppi sends no credentials before host-key validation succeeds. You can also tap **Save Host** and connect later.

For a Mac with an Ed25519 host key, `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` prints the fingerprint.

The host list leads with **Add Host** when none is saved. A row shows `user@host`, the port when it is not 22, the Run on Connect command or **Login shell**, and each folder a terminal is open in. Two rows can use the same machine with different Run on Connect commands. Swipe **Delete Host** removes that host and its saved passwords only. **Edit Host** in a live terminal opens the form for the connected host. **Tailscale → Check a Machine for Oppi** is a separate check.

## Run on Connect

**Run on Connect** runs one command instead of a login shell, as `ssh -t host 'command'` does. Enter `herdr` to attach Herdr, or `tmux new -A -s main` for tmux. The connection ends when the command exits, and **Reconnect** runs it again. The command must be on the `PATH` that non-interactive SSH commands see. Leave it empty for a login shell.

## Open Terminal here

A workspace's **Terminal** button (top right, beside **Config**) and a chat's **Terminal** button open a folder on the saved host that serves the workspace's server:

- from a workspace: its root folder;
- from a chat: the session's own worktree when it has one, else the workspace root. If the chat's worktree cannot be looked up (the server is disconnected or no longer lists it), the chat shows **Cannot Open Terminal** with the reason instead of opening a folder it never ran in.

The host's Run on Connect command decides where the folder opens, by its first word (a path such as `/Users/you/.local/bin/herdr` counts):

| First word | Where the folder opens |
|---|---|
| `herdr` | Inside the Herdr session the host's own terminal already runs |
| `tmux` | A terminal of its own, attached to that folder's tmux session |
| anything else, or none | A login shell in the folder |

- **Herdr:** Oppi asks Herdr, over that terminal's side channel, to show the folder; nothing is typed into Herdr. If a Herdr workspace already has a pane in the folder (symlinked spellings such as macOS `/tmp` count as the same), Oppi focuses it. Otherwise it creates a workspace there, or for a chat in a git worktree opens that checkout as a Herdr worktree, labelled with the Oppi workspace (and worktree name). Focusing moves the Herdr session's focus for every client attached. If Herdr is not running or refuses, a notice offers **Retry** and leaves you in the Herdr terminal; start Herdr there, then Retry opens the folder without reconnecting.
- **tmux:** the terminal enters the folder, then runs `tmux new -A -s <session>`, which creates the session the first time and attaches it afterwards, so it survives a disconnect. A missing folder is reported rather than opening a session elsewhere. The session is named after the workspace (and worktree) plus a short hash of the folder, so same-named workspaces never share a session; `.` and `:` become `-`.
- **Anything else:** a login shell in the folder that ignores Run on Connect and never types into a program the host already runs. The host list's row still opens the host's own shell or command.

Server-supplied values (folder, workspace name, worktree name) reach the host as octal-escaped bytes in one quoted command word, so none is read as shell code, and spaces, quotes, `$`, backticks, newlines, and non-ASCII all work. A `~` folder expands to the host's home. A missing folder prints `oppi: /that/path: no such folder` and ends. A sandbox workspace, or one whose folder is relative to the server's working directory, offers no Terminal.

Oppi picks the host by matching the workspace's server host against saved hosts, ignoring case and a trailing dot, and treating a tailnet short name (`mac-studio`) and full name (`mac-studio.tail1234.ts.net`) as one machine. An exact address match comes first, then a short-name match. Among matches, a host whose command starts a multiplexer (`herdr`, `tmux`) wins over a host with no command, then any other, then the first saved, so a machine saved twice still opens the folder inside Herdr. With no match, **Add Host** opens with the server's host filled in.

A folder terminal is kept while connected: leaving the workspace or chat keeps it, and tapping Terminal again returns to the same shell. Oppi keeps one terminal per saved host and folder; under Herdr there is one client per host that shows whichever folder you last asked for. Editing or deleting the host ends them, and so does the background grace ([Network and reconnect](#network-and-reconnect)). Which chat top-bar buttons show, and why Terminal can be missing, is in [Using Oppi](usage.md#chat-display).

## Font, icons, and colors

The terminal uses **Settings → Text → Code Font** and **Code Text Size** (13 pt at 100%). Changing either redraws an open terminal and resizes the remote shell. Prompt icons from starship, powerlevel10k, oh-my-posh, and similar come from the bundled Nerd Fonts Symbols font.

### Colors

The terminal takes its colors from the host's [Ghostty](https://ghostty.org) theme. Each connect, Oppi reads the host's Ghostty config over the connection's side channel and paints with it. A host without Ghostty or a config keeps Oppi's theme. Nothing else is read:

- `theme`: a name, an absolute path, or `light:X,dark:Y` (the side matching Oppi's appearance). A name is looked up in `$XDG_CONFIG_HOME/ghostty/themes` (default `~/.config/ghostty/themes`), then `$GHOSTTY_RESOURCES_DIR/themes`, the macOS app's resources, and `/usr/share/ghostty/themes` and `/usr/local/share/ghostty/themes` on Linux.
- `palette = N=#rrggbb`, `background`, `foreground`, `cursor-color`, `cursor-text`, `selection-background`, `selection-foreground`. Colors are `#rrggbb` or `#rgb`, with or without `#`; color names and `cell-foreground` are not read.
- Config files: `$XDG_CONFIG_HOME/ghostty/config` and `config.ghostty`, plus the same two under `~/Library/Application Support/com.mitchellh.ghostty` on macOS. A `config-file` line is followed one level deep.

As in Ghostty, values in the config win over the theme file's entry by entry, and later lines win. Fonts, size, opacity, blur, and keybinds are ignored. Colors apply to the default foreground and background, the 16-color palette, the cursor, and the selection highlight. The bottom bar, buttons, and key strip follow the terminal background, and the screen switches to light or dark chrome by that background, clock and battery included. The input bar, banners, and notices use your Oppi theme when it is on the same side, and Oppi's built-in Light or Dark otherwise, so text stays readable. A program's own OSC 4, 10, and 11 changes still apply. `cursor-text` and `selection-foreground` are read but not drawn, and `background-opacity` is not applied.

Each file is cut at 64 KB and the whole read at 256 KB, and parsing happens on this device. Oppi keeps the last theme read per host, so the next connect paints at once and then refreshes. If the host changes its theme while a terminal is open, reconnect to pick it up; switching Oppi between light and dark rereads a `light:`/`dark:` pair.

**Terminal Colors** in the host form chooses the source per host:

| Choice | Result |
|---|---|
| Host's Ghostty theme (default) | The theme above. The row shows the name last read, such as `tokyonight`, or `not found`. |
| Oppi theme | Oppi's own colors; nothing is read. |
| A named theme | One theme from the host's theme folders instead of its config. |

The named-theme list comes from the host when the picker opens, so it needs an open terminal for that host (open the form from the terminal's **…** menu, **Edit Host**). Otherwise the picker offers the first two choices and the one already chosen. The choice applies to an open terminal at once without ending it or asking you to sign in again.

## Images

The terminal draws images sent with the [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/), so `kitten icat`, chafa, timg, `viu`, Yazi previews, and an agent's image output appear in the grid. A program that asks whether images are supported (`a=q`, as `kitten icat` does first) is told yes.

- **Accepted:** images sent inside the escape code (direct `t=d` medium) as RGBA, RGB, zlib-compressed, or PNG data. PNG is decoded on this device with ImageIO, and only PNG; anything marked PNG without the PNG signature is refused with `EINVAL: invalid data`. The file, temporary-file, and shared-memory mediums are refused with `EINVAL: unsupported medium`, so a host over SSH can never make this app open a local file.
- **Limits:** each screen keeps up to 64 MB of decoded images, dropping the oldest, and an image over the limit is rejected. A PNG over 64 MB or 10000 pixels a side is refused from its header. A frame draws at most 256 images and 1024 placements. A hostile image can briefly push memory use to about 1.1–1.2 GB while it arrives, which may end the app on a device short of memory; this is a known limit of the bundled libghostty.
- **Placement:** images draw at their cell, honoring the source rectangle, size, aspect ratio, and z-index (negative z under the text, below −1073741824 under the cell background too, otherwise over the text), clipped to the grid, and scroll with history. Delete (`a=d`), retransmission of the same id, and reset (RIS) replace or remove the picture.
- **Not drawn yet:** the Unicode-placeholder form (`U=1` virtual placements, used to show images through tmux). Those cells stay blank, so `kitten icat` shows nothing inside tmux and works outside it.

## Input bar, touch, and keyboard

The terminal picks its input from what the host reports; it does not inspect host processes. A program that reports [OSC 7501](#program-status-osc-7501) on the root as a coding agent gets the chat input bar. Agent ids are `pi`, `claude`, `codex`, `opencode`, `gemini`, `amp`, `aider`, `goose`, `crush`, `droid`, `cursor-agent`, `qwen`, `kimi`, `copilot`, `kilo`, and `grok`, also with a suffix such as `claude-code`. When Run on Connect starts `herdr`, the terminal gets the chat bar while Herdr's focused pane runs an agent. Anything else (a shell, `vim`, `tmux`, a program that does not report, a cleared root, or a report from before the shell's latest prompt, OSC 133) gets direct terminal typing: the bar is hidden and a tap opens the keyboard with its Esc/Tab/Ctrl/arrow bar. Agents that do not report yet (OpenCode, Copilot CLI, Gemini CLI, and others) and Herdr started by typing `herdr` in a login shell start in direct typing. Switch by hand with **Use Chat Bar** or **Type in Terminal** in the **…** menu, or the chat button on the terminal keyboard's bar. Your choice stands until the detected program changes.

**Chat input bar.** Oppi's chat composer: type or dictate, edit, then **Send**. Oppi pastes the text as one block (bracketed paste when supported) and presses Enter; Send on an empty bar presses Enter alone. Autocorrect, capitals, and smart punctuation are off. While focused, a key strip offers the program's keys (such as Thinking and Model), the arrows, then Esc, Tab, Ctrl-C, and Ctrl-D in one row; swipe for keys that do not fit. The keyboard button at its right end switches to typing straight into the terminal. The bar grows over the terminal rather than shrinking it, so the remote shell is not resized while you compose and the program does not redraw; the picture shifts up by the fewest whole rows that keep the program's cursor row above the bar, and returns when it shrinks. The remote terminal resizes when the keyboard appears or goes away, on rotation, and when the bar appears or goes.

**Terminal keyboard.** A two-row bar: Esc, Ctrl, Alt, Tab, and the arrows, then Paste and the program's keys. Swipe either row to reach keys that do not fit; both move together. The chat button and ⌄ (hide keyboard) stay pinned at the right end. A tap with the keyboard down opens it. While it is up and the app asked for mouse input (Herdr, tmux with `mouse on`, many TUIs), a tap is a click at the cell and the keyboard stays; hide it with ⌄. Otherwise a tap hides it, after a short wait so a second tap can copy.

### Program shortcuts

The key strip and the terminal keyboard add buttons for the agent that reports itself (or the shell), named by what they do. Each sends the key the program has bound now:

| Program | Buttons (default key) | User file read |
|---|---|---|
| Shell | History (^R), Clear (^L) | none |
| pi | Thinking (⇧Tab), Model (^L), Tools (^O); Stop when interrupt is not Esc | `${PI_CODING_AGENT_DIR:-~/.pi/agent}/keybindings.json` |
| Claude Code | Mode (⇧Tab), Model (⌥P), Transcript (^O), Todos (^T), Background (^B) | `${CLAUDE_CONFIG_DIR:-~/.claude}/keybindings.json`, contexts Global, Chat, Task |
| Codex | Transcript (^T), Effort − (⌥,), Effort + (⌥.); Stop when interrupt is not Esc | `[tui.keymap.*]` in `${CODEX_HOME:-~/.codex}/config.toml` |

The file is read once whenever the program changes, through a side command on the same connection, and follows that program's rules: pi and Codex entries replace an action's keys (`[]` removes it), and Claude Code entries add keys (a default key bound to `null` or another action stops counting). A missing or unreadable file means defaults. For Codex only the `tui` tables leave the host, and only table headers, dotted keys, and string arrays are read. The variables are those of a non-interactive SSH command, which may differ from the agent's. Actions bound to Esc, ^C, Tab, ↑ or ↓ are not repeated, `super` and `cmd` keys are left out, and Claude Code chords go as one write. Other agents get fixed keys only. Under Herdr, buttons follow the agent in the focused pane.

### Attachments and secure input

Photos and files from **+**, and a pasted image, are saved on the host before Send in an owner-only (`700`) `oppi-ssh-<your uid>` folder under `$TMPDIR` (or `/tmp` without one) over the same SSH connection. The prompt then lists each file's path on its own line so the agent can read it. Each file is limited to 32 MB. The save is refused, with the reason shown instead of the path, when that folder is a symlink, not a directory, or owned by another user. On a shared `/tmp`, another local user could create that folder first to block your uploads, and they then fail with that reason rather than writing anywhere unsafe. Oppi never deletes these files; the host's temporary-folder cleanup does.

A password prompt on screen turns on the keyboard's secure entry, and the bar shows **Secure Input** with a lock. Third-party keyboards, dictation, and keyboard learning then do not see what is typed. Oppi recognizes the prompt from the cursor's own line on the live screen, so it works for `sudo`, `su`, `ssh`, and `ssh-agent`, in a shell or a Herdr pane, and typing `echo Password:` does not trigger it. It stays on while the secret is typed (including echoed `*`) and ends when the cursor leaves the line, not when you read history. If the chat bar was the input, typing moves to the terminal until the prompt ends, then back. Two painted frames of new output must agree before it ends, so rotating or showing the keyboard does not end it early. A password is never typed into the chat bar's draft. With a saved password, the bar also offers [Fill Password](#filling-a-password).

### Touch

- **Delete:** holding ⌫ repeats; after about a second each repeat deletes a word (Ctrl-W) instead of a character, only on the normal screen. Full-screen apps on the alternate screen (vim, nano, less, Emacs) keep getting ⌫.
- **Space-bar trackpad:** touch and hold the space bar, then slide, to move the cursor one ← or → per cell and one ↑ or ↓ per row. In a shell, ↑ and ↓ walk history. It moves nothing while a keyboard such as Japanese is composing.
- **Dictation:** the keyboard's mic dictates into the shell as you speak. Each revision reaches the shell at once (backspaces to the first changed character, then the new text); revisions of text from before an arrow, paste, tap, Return, or hardware key are dropped.
- **Text handed over in one piece** (a dictated phrase, sliding across keys) goes to the shell at once and leaves an armed Ctrl or Alt for the next key. Text with a newline or control character asks first, like a multi-line paste. On the terminal keyboard, **Alt** then Return sends Alt+Enter; Shift-Return needs a hardware keyboard.
- **Double-tap a word** to copy it. The first tap still runs (opens the keyboard or clicks), and the second only copies the word under the first. Paths and URLs count as one word, a trailing colon is dropped (`src/x.swift:42:` copies `src/x.swift:42`) unless the word is a URL with a port or an IPv6 address. **Copied N characters** appears. This copy is yours, not OSC 52.
- **Touch and hold, then lift** without moving opens an edit menu at the finger: **Open**, **Copy Link**, **Copy**, and **Paste** where they apply ([Links, paths, and the shell's folder](#links-paths-and-the-shells-folder)). **Paste** saves a clipboard image to the host like a chat-bar attachment and pastes its path (text wins when both are present); the keyboard bar's **Paste** does the same.
- **Touch and hold, then drag** selects a range in a plain shell and copies it on release. Selection never sends bytes to the host. In a mouse-reporting app the same gesture is a mouse drag, and a hold that has not moved sends nothing.
- **Scrolling:** in a mouse-reporting app a drag sends wheel steps, three rows of finger travel per notch, at the cell under the finger so split panes scroll the pane you flicked, in one SSH write per frame. On the alternate screen without mouse reporting (`less`, `man`, a pager, vim without mouse), a vertical drag sends ↑ and ↓ per row (DEC 1007 alternate scroll, on by default as in Ghostty). If the remote changes screens or mouse reporting mid-gesture, the gesture is dropped. Otherwise a drag reads local history with native momentum and rubber-banding. A drag released within half a row of the bottom is back at live, and **Back to Live** returns there.
- **Back and bar:** the terminal has no navigation bar. **Back** (‹) is a small glass button at the bottom left, and swiping from the left edge goes back too. A second bar at the bottom right holds the program-status symbol, Herdr (when the host has it), the [terminal switcher](#switching-terminals) (with more than one terminal open), and **…**. The **…** menu's header names the screen (the shell's title or the saved host) and the shell's folder when it reports one (OSC 7). While a docked keyboard is up the bar goes away and the grid takes its rows, and it returns when the keyboard goes down. A broken connection keeps the bar so Back and Reconnect stay in reach. An orange dot on Back means Herdr or a blocked program wants you (VoiceOver: **Attention pending**).

A healthy connection shows no banner. Connecting, disconnected, network-changed, paste, open, and input messages float at the top edge of the grid and never resize it. **Edit Host**, **Disconnect**, and **Reconnect** are in the **…** menu.

### Hardware keyboard

While typing in the terminal (not the chat bar), hold ⌘ to see ⌘C and ⌘K in the shortcut overlay.

| Keys | What happens |
|---|---|
| ⌘C | Copies the highlighted selection with the same **Copied N characters** note; with nothing highlighted it does nothing and sends nothing |
| ⌘K | Clears like Ghostty. Local history is deleted. At a shell prompt reported with OSC 133 the screen clears and Ctrl-L redraws the prompt; elsewhere the rows above the cursor are removed and nothing is sent. Does nothing on the alternate screen |
| ⌘. | Esc (iOS maps it for every app, so it is not in the overlay) |
| ⌘V | Paste, with the same confirmation as **Paste** |
| Option | Meta: Option with a key sends Alt with it, as Ghostty does with `macos-option-as-alt = true` (Option-B and Option-F move by word). Option-Shift works with letters only. Option does not type the characters a Mac layout puts on it (∫, é, or @ on some layouts) |
| Shift-Return | Shift+Enter (`ESC [ 27 ; 2 ; 13 ~`, or `ESC [ 13 ; 2 u` with the Kitty keyboard protocol); pi reads it as a new line |
| Option-Return | Alt+Enter (`ESC` then Return, or `ESC [ 13 ; 3 u` with Kitty); pi reads it as a queued follow-up |

Other keys, including other ⌘ shortcuts, are sent as before.

## Filling a password

At a password prompt (the one that turns on **Secure Input**), the keyboard bar and the chat bar's key strip show **Fill Password** when this host has a password to fill. It types the saved password so you do not retype a long `sudo` password on a phone.

- **Which password:** a host that signs in with a password and has **Save Password** on fills that sign-in password. A host that signs in with **This Device's Key** fills its optional **Sudo Password** from the host form. A host with neither never shows the key.
- **Every tap asks** for Face ID, Touch ID, or the passcode, and names the host (**Fill the password for duh@mac-studio**). It never reuses the [5-minute approval](#approval-reuse). Cancelling or failing the check sends nothing.
- **What is sent:** the bytes are typed as a keyboard would (not a bracketed paste), and **Return is not pressed**, so you decide when to answer. A **Filled password** note confirms it, and Oppi keeps nothing after sending.
- **When it is offered:** only while the prompt is on the live screen. Scrolling into history hides it, and so does the prompt ending or the connection closing. Right before sending, Oppi rechecks the live screen: if the prompt ended, its line changed, or the cursor left it while Face ID was up, nothing is sent and a note says so. Output elsewhere (another Herdr pane redrawing) does not stop a fill.
- **Where it goes:** to whatever program on this terminal shows that prompt, not necessarily the host's own `sudo`. In a Herdr pane that ran `ssh` to another machine, the prompt is that machine's, and Fill Password would type this host's saved password into it. Read the host name in the confirmation before approving.
- **VoiceOver:** the key reads **Fill password for** `user@host`.

## Links, paths, and the shell's folder

The terminal reads the shell's folder from OSC 7 `file://host/path`. Only a `file:` URL is accepted. The host in the URL must match the first host the connection reported; a report from a different machine (a nested `ssh`, `tmux` on another host) leaves the folder unknown rather than resolving this server's paths against someone else's. When known, the **…** menu's header shows it.

A touch-and-hold menu depends on the cell: on an OSC 8 hyperlink, a URL, or a path it offers **Open** beside **Copy** and **Paste**, and a hyperlink also offers **Copy Link**. A word with something to copy but nothing to open offers **Copy** and **Paste**, and a blank cell offers **Paste** alone. **Copy** takes the text you see, and **Copy Link** takes the address an OSC 8 link carries, which the text may not show. Words follow the same rules as a double tap. A trailing `:line` or `:line:column` is dropped for **Open** and kept for **Copy**; a URL is read whole.

- **Open on an `http` or `https` URL** opens the browser chosen in **Settings → General → Open Links** (the in-app browser by default), and the item names the site. Other schemes (`mailto:`, `vscode:`, `ftp:`) can only be copied. An OSC 8 link wins over the text it covers.
- **Open on a path** opens the file in Oppi's viewer when the SSH host is also a paired Oppi server: the two must name the same machine, a tailnet name and its short name included. Two paired servers that could both be that machine match neither, so the terminal does not guess. A relative path resolves against the shell's folder, and with no folder reported can only be copied. A folder opens the Files browser there.
- Owner-host files are rooted at the user's home on the server, so a path outside it offers only **Copy**. A host that is not a paired server offers **Copy** for paths, never **Open**.

**Browse Files Here** in the **…** menu opens the Files browser at the shell's folder when the shell reported one and the host is a paired server. Files are read through that server, not over SSH. Each Open and Browse replaces the one before it.

## Herdr

When `herdr` is on the host, the terminal checks Herdr's API (`herdr api snapshot`) every few seconds over the same connection, in a separate command channel. A button beside **…** at the bottom right turns orange while agents wait at an approval or question. It lists workspaces and agents, each with the status symbol and label of the program-status glyph: Working (animated), Question, Done, or Idle. The focused workspace and agent are bold. An unrecognized state shows as Unknown.

Herdr decides the state from the agent's screen or its integration and does not pass OSC 7501 through. A Herdr version that lists a pane's OSC 7501 records (`program_status`) is read like a plain terminal's records, including the blocked kind (Needs approval, Sign-in, Question). Without records, Herdr cannot say what kind of wait it is, so a blocked agent reads as Question, and a question Herdr does not recognize reads as Done. Oppi's `ask` extension tells Herdr's Pi integration when it waits, so a pi question reads as Question. Tapping a row runs `herdr workspace focus` or `herdr agent focus` on the host, which moves focus for every attached client. Hosts without `herdr` are checked once per connection and then left alone.

## Clipboard

When a program on the host copies text with OSC 52, the text goes on this device's clipboard and a **Copied N characters** note appears. Herdr forwards a pane's copy this way (copy-on-select, an agent's `/copy`), as does tmux with `set-clipboard on`. Only UTF-8 text up to 1 MB sent to the standard clipboard (`c`) is copied. Requests to clear it and writes to the X11 selection or primary buffer are ignored. Copying is write-only: the host never reads this device's clipboard, and clipboard queries get no reply. A remote copy applies only while that terminal is on screen and Oppi is in front. Your own double-tap or selection copy is allowed regardless. Paste is always your action, through **Paste** or ⌘V.

## Program status (OSC 7501)

The terminal answers the Program Status Protocol support query (`ESC ] 7501 ; ? ST`) with the revision 0.4 reply (`?:states=idle,working,done,blocked,error:kinds=permission,question,auth`), so programs that detect support first, such as Pi 1.1.0, start reporting. This is the only OSC reply the terminal sends. Reports (idle, working, done, blocked, error, with an optional app, title, and message) follow the [specification](https://www.superlogical.com/rex/docs/build/program-status): one record per id, `clear` removes a record and its children, at most 256 records. `working` and `blocked` records drop when the shell shows its next prompt (OSC 133 A) or the shell or connection ends, while `done` and `error` stay. Reset (RIS) clears everything.

While a program has reported, the bottom-right button shows a status symbol: a blue progress mark while working, an orange hand, question, or lock while blocked, and a grey dot at rest. Tap it for the list of programs, with this host named at the top. Done and Error show green and red only until this terminal is on screen, then settle to Idle. A blocked record wins over a working root, as in a thread. Nothing shows until a program reports.

When any record is blocked, a card floats over the top of the terminal naming the kind, the saved host, and the program's message. It does not resize the terminal and is not a dialog: you answer in the terminal or chat bar. If it covers the program's prompt, tap it or swipe it up (VoiceOver: **Dismiss**); it folds into the status symbol, which stays orange and lists the message. It stays away while the program repeats the same report and returns for a different kind of wait, the next time the program blocks, or a new message after the program's reports pause for a second.

## Progress (OSC 9;4)

A program can report progress with OSC 9;4 (`ESC ] 9 ; 4 ; state ; percent ST`; cargo, `brew`, `winget`, and `systemd` tools send it). The status glyph draws it as a ring:

| Report | Ring |
|---|---|
| `1;N` set | Blue, filled clockwise from the top to N% |
| `3` indeterminate | Blue, a short arc that spins |
| `2` or `2;N` error | Red, filled to N%; with no number, a full still ring (the work stopped) |
| `4` or `4;N` pause | Orange and dashed, filled to N%; with no number, a full ring |
| `0` remove | No ring |

With an OSC 7501 report too, its symbol stays in the middle and the ring goes around it. Progress alone is the whole glyph and not a button. VoiceOver reads **Progress 40%** (also **Progress paused at 60%**, **Progress failed**, **Progress, in progress**) after the status. With **Reduce Motion** on, an indeterminate report is a dotted full ring. Each report replaces the previous one, and one not renewed for 15 seconds goes away, as in Ghostty. A reset (RIS) or the end of the connection clears it. Progress shows no card and no haptic.

## Notifications and the bell

A program can notify the terminal with OSC 9 (`ESC ] 9 ; text ST`, iTerm2) or OSC 777 (`ESC ] 777 ; notify ; title ; body ST`, rxvt and Ghostty). The same card shows it, headed **Notification**, and leaves after six seconds or when you tap it. Notifications less than a second apart become one that updates its text. A blocked program's card comes first, and a notification waits behind it. A new card gives a warning haptic, at most once a second. A bell (BEL) gives a light haptic and no card, and bells within one second count once. The terminal hears these while its connection is open, including after you leave its screen ([Keeping a terminal open](#keeping-a-terminal-open)). Programs inside Herdr usually notify Herdr, and Herdr's own notifications use Kitty's OSC 99, which is not read yet.

## Credentials and host trust

- **Metadata:** host, port, username, sign-in choice, and Run on Connect are stored in app preferences. Passwords never are, and are never logged. Each host has its own id, and changing its hostname, port, username, or sign-in method removes its saved password and sudo password without touching another host's.
- **Unsaved password:** used for one connection attempt; Reconnect asks again.
- **Saved and sudo passwords** live in the app's private, this-device-only Keychain, never synced or migrated, behind Face ID, Touch ID, or the passcode (a device passcode is required to save one). Each is bound to its host's id, so copying one host's secret onto another host's item does not sign in. The form never shows a saved sudo password: type a new one to replace it, or tap **Remove Saved Sudo Password**. Reading at connect needs approval that Oppi [reuses for 5 minutes](#approval-reuse).
- **Device key:** on a physical device the per-device P-256 SSH key lives in the Secure Enclave, and signing needs user presence (reused 5 minutes). The simulator uses a labelled software key, which is not evidence of hardware protection. Password sign-in creates no key.
- **Trusted host keys** are stored in the same Keychain, shared by SSH Terminal and Check a Machine. A changed host key blocks sign-in. **Forget Trusted Key** asks for confirmation; verify independently why the key changed before trusting its replacement.
- **Delete Host** deletes that host and its saved passwords, not the device key or trusted host keys, which stay keyed by host and port. If the host list cannot be read, saving is blocked until **Reset Host List** removes it; add hosts again afterward. Reset does not search the Keychain.

## Keeping a terminal open

While Oppi is in the foreground, a connected terminal stays connected when you leave its screen (Back, another tab, another session). Tap that host in the list (it reads **Connected**) to return to the same live channel and grid, with no reconnect or sign-in. Oppi keeps one terminal per saved host and folder, and connecting an identity that already has one shows it; **Reconnect** and a connect after the shell ended open a new one.

A terminal ends when you tap **Disconnect**, when the remote shell or command exits or the connection drops, when you save changes to the host or delete it, or when the background grace ends. Saving the host unchanged keeps it, and so does saving or removing only a password. While off screen, Oppi still reads its output, answers its terminal queries, and checks the connection after a network change. The Herdr list and program shortcuts load again when you return.

### Switching terminals

With more than one terminal open, a **Switch terminal** button (stacked rectangles) sits beside **…**. Its menu lists every open terminal, each as `user@host` over the folder's last component, or over the Run on Connect command or **Login shell** for a host's own terminal. A green dot marks a connected terminal. A terminal whose program is blocked shows that status symbol and what it waits on. The terminal on screen is checked, and the order is hosts by name, a host's own terminal first, then its folders.

Choosing one swaps to that terminal's live channel with no dialing or sign-in, and the one you left stays open and keeps reading. **Reconnect** and **Edit Host** then act on the terminal now shown, from whichever screen opened this one: a Reconnect that needs a password asks for that terminal's host, names it in the sheet, and **Save Password** edits that host. Chat-bar text and attachments stay with their terminal until you leave the terminal screen. The button is hidden with one terminal open, and VoiceOver reads **Switch terminal** with the count.

## Approval reuse

Face ID, Touch ID, or the passcode is asked when a sign-in needs your device key or a saved password. Oppi remembers that approval for 5 minutes, separately for the device key and for each host's saved password, so a reconnect in that window does not ask again. Oppi keeps its own approval and does not widen the system's biometric reuse. It ends early when the 5 minutes pass, when App Lock locks or covers Oppi, and on any sign-in or approval failure. Approvals are never saved to disk, and a connected terminal does not depend on them.

## Network and reconnect

When Oppi's in-app Tailscale node runs, tailnet names (`*.ts.net` or `*.beta.tailscale.net`, with or without a trailing dot) use it. Other hosts, and tailnet names while the node is stopped, use direct TCP through your current network, including a system Tailscale VPN.

Oppi checks SSH liveness every 60 seconds by opening and closing an empty session channel (15-second reply timeout, no shell, command, or PTY), and direct TCP also uses kernel keepalives. Failure closes the connection and shows **Disconnected** with **Reconnect**. After a Wi-Fi or cellular change, one SSH round trip decides: a live shell carries on, a dead one shows **Disconnected**.

Going to the background keeps the shell running and reading output for about 25 seconds under an iOS background task. Return within that time and nothing reconnects. A connect still signing in or dialing when Oppi backgrounds is cancelled, and one that finishes there is closed again. Otherwise Oppi closes the connection before iOS can suspend it (**Oppi went to the background.**), because a suspended app would silently lose the bytes the host sends. On return, a terminal that was on screen reconnects on its own and signs in like **Reconnect** ([Approval reuse](#approval-reuse)), after you unlock if App Lock is on. A terminal you had left is not reconnected. If that sign-in fails or is cancelled, it shows **Disconnected** with **Reconnect**. These notices float over the grid and do not resize it. Reconnect always opens a fresh shell and does not replay input, so use `tmux` on the host if work must survive a disconnect.

## Limits

- Hosts are saved on this device only. There is no private-key import, keyboard-interactive sign-in, or forwarding.
- Images use the direct medium only, and Unicode-placeholder (tmux) images do not draw ([Images](#images)).
- The SSH library supports Ed25519 and ECDSA host and user keys, Curve25519 and ECDH key exchange, and AES-GCM. RSA-only and legacy-only servers fail with an unsupported-algorithm error, and a server offering only keyboard-interactive cannot accept password sign-in here.
- Connection, authentication, and terminal-opening waits are bounded, and a rejected credential, changed host key, unreachable host, or unsupported algorithm shows a visible error.
- Secure Enclave and biometric approval need physical-device testing.
