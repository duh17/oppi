# Browser automation video extension

This Oppi-compatible Pi extension package uses public Pi package and tool APIs to register `browser_automation_video`. The tool drives Chrome with `agent-browser`, records the run, and converts it to H.264 MP4.

Under Oppi, the tool uses Oppi's documented `ctx.attachments.addFile()` helper to store the MP4 as a session attachment and return it in `details.media[]`. In standalone Pi, pass `outputDir` to keep the MP4 on disk.

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

Pi auto-discovers extensions in `~/.pi/agent/extensions/`, so new Oppi sessions load `browser-automation-video` automatically. Use the workspace editor's extension toggles to enable or disable it per workspace; they write Pi resource settings. Oppi loads the extension through Pi's normal loader and renders its returned `details.media[]` video attachment.

## Example tool call

```json
{
  "url": "https://example.com",
  "steps": [{ "action": "wait", "ms": 1000 }, { "action": "snapshot" }],
  "tailWaitMs": 700
}
```

In Oppi, the MP4 is copied to session attachment storage and appears in the expanded tool row as a playable video card.

In standalone Pi sessions, `ctx.attachments.addFile()` is unavailable. Pass `outputDir` to keep the MP4 on disk:

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
- `commands`: raw `agent-browser` commands without the `agent-browser` prefix; they run after `steps`.
- `outputDir`: workspace-relative or absolute directory for a local MP4 copy. Required outside Oppi.
- `renderInOppi`: attaches the MP4 to the Oppi tool row through Oppi's attachment helper when available. Defaults to `true`.
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

Oppi renders `details.media[]` with `kind: "video"` in the native video attachment row. Standalone Pi still receives the text result and local output path when `outputDir` is set.
