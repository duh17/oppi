# Browser automation video extension

This is an Oppi-compatible Pi extension package. It uses public Pi package and tool APIs to register `browser_automation_video`, a tool that drives Chrome with `agent-browser`, records the run, and converts it to H.264 MP4.

When the tool runs under Oppi, it uses Oppi's documented `ctx.attachments.addFile()` helper to store the MP4 as a session attachment and return it in `details.media[]`. In standalone Pi, pass `outputDir` so the MP4 stays on disk.

## Prerequisites

- `agent-browser`
- `ffmpeg` and `ffprobe`
- Google Chrome for the default Chrome engine path on macOS

On macOS:

```bash
brew install agent-browser ffmpeg
```

## Local install for Oppi development

From the Oppi repo root:

```bash
ln -sfn "$PWD/pi-extensions/browser-automation-video" ~/.pi/agent/extensions/browser-automation-video
```

Then enable `browser-automation-video` in the workspace extension allowlist. Oppi loads it through Pi's normal extension loader, filters it through the workspace allowlist, and renders the returned `details.media[]` video attachment.

## Example tool call

```json
{
  "url": "https://example.com",
  "steps": [{ "action": "wait", "ms": 1000 }, { "action": "snapshot" }],
  "tailWaitMs": 700
}
```

In Oppi, the MP4 is copied into session attachment storage and appears in the expanded tool row as a playable video card.

In standalone Pi sessions, `ctx.attachments.addFile()` is not available. Pass `outputDir` so the tool keeps the MP4 on disk:

```json
{
  "url": "https://example.com",
  "outputDir": ".pi/browser-recordings",
  "steps": [{ "action": "wait", "ms": 1000 }]
}
```

## Parameters

- `url`: initial URL. Defaults to `https://example.com`.
- `steps`: structured browser actions: `click`, `fill`, `type`, `keyboardType`, `press`, `wait`, `scroll`, `hover`, `focus`, `eval`, `snapshot`, or `screenshot`.
- `commands`: raw `agent-browser` commands without the `agent-browser` prefix. These run after `steps`.
- `outputDir`: workspace-relative or absolute directory for a local MP4 copy. Required outside Oppi.
- `renderInOppi`: attach the MP4 to the Oppi tool row through Oppi's attachment helper when available. Defaults to `true`.
- `keepWebM`: keep the intermediate WebM when using `outputDir`.
- `headed`, `viewportWidth`, `viewportHeight`, `tailWaitMs`, and `timeoutMs`: browser and recording controls.

## Development checks

```bash
cd pi-extensions/browser-automation-video
npm install
npm run check
npm test
```

## Output shape

The tool returns concise text for the model and structured details for clients:

```ts
{
  details: {
    expandedText: "Browser automation video recorded.\n...",
    presentationFormat: "markdown",
    media: [
      {
        kind: "video",
        id: "att_...",
        mimeType: "video/mp4",
        fileName: "example-com-2026-06-13.mp4",
        sizeBytes: 1842112,
        width: 1280,
        height: 720,
        durationSeconds: 9.4
      }
    ]
  }
}
```

Oppi renders `details.media[]` with `kind: "video"` through the native video attachment row. Standalone Pi still receives the text result and local output path when `outputDir` is set.
