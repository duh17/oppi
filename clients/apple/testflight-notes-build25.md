# Build 25 (1.1.0) — What's New Since Build 20

## Ask Extension
- Agent questions appear as interactive cards with tappable answer options
- Pending ask requests persist per-session and restore when switching back
- Full-screen expanded view for complex multi-option questions

## Sub-Agent Sessions
- Agents can spawn child sessions for parallel work
- Collapsible tree view shows child status, elapsed time, and accumulated cost
- Parent breadcrumb bar for navigating the session tree
- send_message and stop_agent controls from the parent session

## Inline Rendering
- Mermaid diagrams render directly in the chat timeline
- LaTeX math blocks render inline with a native Core Graphics layout engine
- Online URL images load and display inline in markdown
- Pinch-to-zoom and tap-to-fullscreen on all inline media

## File Browser and Document Viewers
- Browse workspace files with breadcrumb navigation and swipe-back
- Fuzzy filename search with match highlighting
- Disk cache for instant re-loads of previously viewed files
- Renders markdown, HTML, PDF, code, org mode, LaTeX, mermaid, images, video
- Share sheet export (image, PDF, source) across all document surfaces
- Pi quick action menu on text selection in file and code views

## Themes and Appearance
- Four built-in color themes: Dark, OLED, Light, Night
- Custom theme import from server
- Code blocks adjusted for WCAG AA contrast
- Configurable assistant avatar with emoji/Genmoji picker
- Configurable code font (SF Mono, Fira Code, JetBrains Mono, Cascadia Code, Source Code Pro, Monaspace Neon)
- New app icon

## Server
- Server stats dashboard with usage analytics and model breakdown
- Multi-server picker on Server tab
- Git commit browsing from session view
- Workspace creation flow after pairing

## Composer
- @file reference pills with autocomplete
- Slash command autocomplete
- App Intents and Control Center widget for quick session creation

## Performance and Stability
- Session list lazy loading — reduced daily API transfer significantly
- ANSI parser rewritten for large output handling
- Streaming text uses lightweight rendering during output, crossfades to full markdown on completion
- Tool rows show elapsed time during execution
- Hardened WebSocket protocol handling
- LAN endpoint TLS compatibility fix for release builds
- Agent error events now surface to iOS client
- Session list grouped into Your Turn / Working / Stopped sections
