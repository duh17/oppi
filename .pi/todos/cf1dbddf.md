{
  "id": "cf1dbddf",
  "title": "P1: iOS — file preview views (markdown, image, code, HTML)",
  "tags": [
    "pi-remote",
    "ios",
    "files",
    "preview",
    "phase-1"
  ],
  "status": "backlog",
  "created_at": "2026-02-07T07:41:42.496Z"
}

## Context

File browser (TODO-15956340) lets user navigate files. This TODO adds
the ability to actually view file contents on the phone.

Depends on: TODO-15956340 (file browser)
Tracker: TODO-992ad1a6

## What to do

### A. FilePreviewView router

New `ios/PiRemote/Features/Files/FilePreviewView.swift`:

Routes to type-specific preview based on file extension:
- .md → MarkdownPreviewView
- .png/.jpg/.gif/.svg → ImagePreviewView
- .html → HTMLPreviewView
- .py/.ts/.js/.swift/.json/.yaml/.toml → CodePreviewView
- .pdf → PDFPreviewView (UIKit PDFView wrapper)
- .csv → CodePreviewView (v1 — table view is v2)
- default → CodePreviewView (monospaced text)

### B. MarkdownPreviewView

Fetch content as string, render via SwiftUI `Text` with `AttributedString`
markdown support. ScrollView + padding. Good enough for v1.

### C. ImagePreviewView

`AsyncImage(url:)` pointed at file content URL. Resizable, aspect fit.
Pinch to zoom is v2.

### D. HTMLPreviewView

`WKWebView` wrapper (UIViewRepresentable). Load URL pointing at server
file content endpoint. Allow JavaScript (agent-generated content is trusted
within sandbox).

### E. CodePreviewView

Fetch content as string. Display in `ScrollView` with monospaced font.
Syntax highlighting is v2 — plain monospaced text is fine for v1.

### F. Share sheet

Long-press or toolbar button on any preview → iOS share sheet:
- Save to Files app
- AirDrop
- Copy (text files)

## Files

- `ios/PiRemote/Features/Files/FilePreviewView.swift` — NEW (router)
- `ios/PiRemote/Features/Files/MarkdownPreviewView.swift` — NEW
- `ios/PiRemote/Features/Files/ImagePreviewView.swift` — NEW
- `ios/PiRemote/Features/Files/HTMLPreviewView.swift` — NEW
- `ios/PiRemote/Features/Files/CodePreviewView.swift` — NEW

## Done when

- Tap .md file → rendered markdown on screen
- Tap .png file → image displayed
- Tap .html file → rendered in WebView
- Tap .py file → monospaced code view
- Long-press → share sheet with Save/AirDrop options
