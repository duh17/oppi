# Pi Remote — Setup Guide (V0)

Control your coding agent from your iPhone. Your Mac runs the server, your phone supervises.

## Prerequisites

- **macOS 15+** (Sequoia or later)
- **Node.js 22+** (`brew install node`)
- **pi CLI** — the coding agent (`npm install -g @mariozechner/pi-coding-agent`)
- **Anthropic API key** — for Claude access
- **Tailscale** (recommended) — for secure remote access (`brew install tailscale`)
- **iPhone** with the Oppi app installed via TestFlight

## Quick Start

### 1. Clone and install

```bash
git clone https://github.com/user/pios.git
cd pios/pi-remote
npm install
```

### 2. Set up pi credentials

Pi needs an API key to talk to Claude. Create the auth file:

```bash
mkdir -p ~/.pi/agent
cat > ~/.pi/agent/auth.json << 'EOF'
{
  "anthropic": {
    "type": "api_key",
    "key": "sk-ant-api03-YOUR-KEY-HERE"
  }
}
EOF
chmod 600 ~/.pi/agent/auth.json
```

### 3. Start the server

```bash
npx tsx src/index.ts serve
```

On first run, the server will:
- Create `~/.pi-remote/` data directory
- Generate a server identity (Ed25519 keypair)
- Start listening on port 7749

### 4. Pair your iPhone

In a separate terminal:

```bash
npx tsx src/index.ts pair "YourName"
```

This shows a QR code. Open the Oppi app on your iPhone and scan it.

### 5. Start coding

From the app:
1. Tap **+** to create a workspace (pick a project directory)
2. Start a session — type a message
3. The agent runs on your Mac, you supervise from your phone
4. Permission requests appear in the chat — tap Allow/Deny

## How It Works

```
iPhone (Oppi app)  ←— Tailscale/LAN —→  Your Mac (pi-remote server)
                                              ↕
                                         pi (coding agent)
                                              ↕
                                         Your code
```

- **All code stays on your Mac.** Nothing leaves your machine except API calls to Anthropic.
- **Permissions are enforced.** The agent can't run commands without your approval (unless you've set up auto-allow rules).
- **Sessions are isolated.** Each workspace gets its own pi instance.

## Networking

### Option A: Same network (LAN)

If your phone and Mac are on the same WiFi, the pairing QR will use your Mac's local IP. No extra setup needed.

### Option B: Tailscale (recommended)

For access from anywhere:

1. Install Tailscale on your Mac and iPhone
2. Sign in on both devices
3. The pairing QR will automatically use your Tailscale hostname

## Troubleshooting

### "pi not found"

Make sure pi is installed globally and in your PATH:

```bash
npm install -g @mariozechner/pi-coding-agent
which pi  # Should print a path
```

Or set the path explicitly:

```bash
PI_REMOTE_PI_BIN=/path/to/pi npx tsx src/index.ts serve
```

### "auth.json not found"

The agent needs API credentials. See step 2 above.

### Connection issues

- Check that both devices are on the same network (or both on Tailscale)
- Verify the server is running: `curl http://localhost:7749/health`
- Check firewall settings: port 7749 must be accessible

### "Permission denied" for everything

This is expected on first use! The server defaults to asking for approval on everything. As you approve commands, you can set up auto-allow rules in the app's settings.

## Runtime Modes

### Container Mode (recommended)

Sessions run inside Apple containers — lightweight macOS VMs with filesystem isolation. The agent can't access your host filesystem outside the workspace bind mount. Requires macOS 15+ (Sequoia).

When creating a workspace in the app, choose **Container** runtime. The server will build the container image on first use (takes ~1 minute).

### Host Mode

Sessions run directly on your Mac. Faster startup, full access to your tools and environment, but no isolation — the agent can access anything your user can. Good for trusted projects where you want the agent to use your local toolchain.

When creating a workspace, choose **Host** runtime.

## V0 Limitations

- **No push notifications.** You need the app open to see permission requests. If the app is backgrounded, the agent will wait until you return.
- **Single user.** The server supports one owner.

## Advanced: Port and Host Configuration

```bash
# Custom port
npx tsx src/index.ts serve --port 8080

# Custom hostname in pairing QR
npx tsx src/index.ts pair "YourName" --host my-mac.local
```

## Security Notes

- The server identity key is stored in `~/.pi-remote/identity/`
- Your Anthropic API key is stored in `~/.pi/agent/auth.json` (permissions: 600)
- The pairing token is stored in `~/.pi-remote/config.json`
- All communication between phone and server is encrypted (Tailscale) or on your local network
