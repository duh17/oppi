# Theme System

How Oppi themes work end-to-end: palette, tokens, color scheme, server loading, and iOS rendering.

## Architecture

```
┌─────────────────────────────────┐
│  Server (Node.js)               │
│                                 │
│  server/themes/*.json  (bundled)│──┐
│  data/themes/*.json    (user)   │──┤ GET /themes   → list
│                                 │  │ GET /themes/x → full palette
│  PUT /themes/x ← iOS imports   │  │ DELETE /themes/x
└─────────────────────────────────┘  │
                                     ▼
┌─────────────────────────────────────────────────────────────────┐
│  iOS                                                            │
│                                                                 │
│  ThemeStore ─── selectedThemeID ──→ ThemeRuntimeState (global)   │
│       │                                                         │
│       ├── .dark        ──→ built-in ThemePalette (hardcoded)    │
│       ├── .light       ──→ built-in ThemePalette (hardcoded)    │
│       └── .custom(name)──→ CustomThemeStore (UserDefaults)      │
│                              ↑ imported via ThemeImportView      │
│                                                                 │
│  Color.theme*  ←── ThemeRuntimeState.currentPalette()           │
│  palette.md*   ←── passed directly to MarkdownTextStorage       │
│  theme.diff.*  ←── AppTheme.from(palette:)                      │
└─────────────────────────────────────────────────────────────────┘
```

## Palette: 49 Tokens

Every theme defines exactly 49 color tokens. Maps 1:1 with `ThemePalette`.

### Base (13) — direct palette colors
| Token | Role | Example usage |
|-------|------|---------------|
| `bg` | Primary background | Chat view, collection view |
| `bgDark` | Darker background | Code blocks, output containers, full-screen code |
| `bgHighlight` | Elevated surfaces | Toolbar backgrounds, cards, input bar |
| `fg` | Primary text | Body text, labels, code default |
| `fgDim` | Secondary text | Subtitles, breadcrumbs, line numbers |
| `comment` | Tertiary text/chrome | Placeholders, separators, muted borders |
| `blue` | Accent: info/links | Headings, language badges, model picker selection |
| `cyan` | Accent: interactive | Tool icons, "Done" buttons, expand button |
| `green` | Accent: success/add | Bash mode, send enabled, session complete, freshness |
| `orange` | Accent: caution | In-progress badges, pending permissions |
| `purple` | Accent: agent/AI | Stop/steer button, assistant icon, audio player |
| `red` | Accent: error/danger | Error states, stop button, recording indicator |
| `yellow` | Accent: highlight | ANSI yellow output (minimal direct usage) |

### Semantic (36) — content-specific
| Group | Tokens | Consumed by |
|-------|--------|-------------|
| **thinkingText** (1) | `thinkingText` | `AssistantTimelineRowContent` |
| **User message** (2) | `userMessageBg`, `userMessageText` | User message bubble styling |
| **Tool state** (5) | `toolPendingBg`, `toolSuccessBg`, `toolErrorBg`, `toolTitle`, `toolOutput` | Tool row backgrounds and text |
| **Markdown** (10) | `mdHeading`, `mdLink`, `mdLinkUrl`, `mdCode`, `mdCodeBlock`, `mdCodeBlockBorder`, `mdQuote`, `mdQuoteBorder`, `mdHr`, `mdListBullet` | `MarkdownTextStorage`, `MarkdownText` |
| **Diff** (3) | `toolDiffAdded`, `toolDiffRemoved`, `toolDiffContext` | `DiffContentView`, `FullScreenCodeView`, `ToolRowTextRenderer`, `ToolTimelineRowContent`, `SessionChangesView` |
| **Syntax** (9) | `syntaxComment`, `syntaxKeyword`, `syntaxFunction`, `syntaxVariable`, `syntaxString`, `syntaxNumber`, `syntaxType`, `syntaxOperator`, `syntaxPunctuation` | `SyntaxHighlighter` |
| **Thinking levels** (6) | `thinkingOff` → `thinkingXhigh` | Thinking progress indicator |

### Why 49, not 51?

Pi's TUI defines 51 tokens. We exclude 2 that are truly TUI-only:

- `border`, `borderAccent`, `borderMuted` — TUI box borders; no iOS equivalent
- `customMessageBg`, `customMessageText`, `customMessageLabel` — TUI extension `hook.message()`; not in RPC events
- `selectedBg` — TUI selection highlight; no iOS equivalent
- `bashMode` — TUI editor mode indicator

## Color Access Patterns

Three ways views access theme colors, each for a different context:

### 1. `Color.theme*` / `.theme*` (SwiftUI views)
```swift
// Static accessor — resolves from ThemeRuntimeState at call time
.foregroundStyle(.themeFg)
.background(Color.themeBgDark)
.foregroundStyle(.themeDiffAdded)       // diff semantic
.foregroundStyle(.themeToolTitle)       // tool state semantic
.foregroundStyle(.themeUserMessageText) // user message semantic
```
Used by: all SwiftUI views, UIKit views via `UIColor(Color.theme*)`.

### 2. `palette.*` (MarkdownTextStorage)
```swift
// Direct palette access — receives ThemePalette instance
styleLine(lineRange, color: palette.mdHeading, font: headingFont)
```
Used by: `MarkdownTextStorage` which receives a palette at init time.

### 3. `theme.diff.*` (AppTheme group)
```swift
// Semantic group on AppTheme
return theme.diff.addedAccent
return theme.diff.removedBg
```
Used by: `DiffContentView`, `FullScreenCodeView` — views that receive `AppTheme` via environment.

### What NOT to use for content
- `themeGreen`/`themeRed` for diff line counts → use `themeDiffAdded`/`themeDiffRemoved`
- `themeYellow`/`themePurple` for syntax highlighting → use `themeSyntax*` tokens
- `themeBlue`/`themeCyan` for markdown → use `themeMd*` tokens via palette

Base colors (`themeBlue`, `themeRed`, etc.) are correct for **UI chrome**: badges, icons, borders, status indicators, ANSI terminal output.

## Color Scheme (Light/Dark)

### The problem
`.fullScreenCover` and `UIHostingController.present()` create new presentation contexts that don't inherit the parent's `preferredColorScheme`.

### The solution
1. **SwiftUI full-screen covers** — add `.preferredColorScheme(ThemeRuntimeState.currentThemeID().preferredColorScheme)` on the view body
2. **UIKit presentations** — set `controller.overrideUserInterfaceStyle` on the `UIHostingController`

```swift
// UIKit path (ToolTimelineRowContent)
let controller = UIHostingController(rootView: view)
controller.overrideUserInterfaceStyle = 
    ThemeRuntimeState.currentThemeID().preferredColorScheme == .light ? .light : .dark
```

### Built-in scheme mapping
| ThemeID | Color scheme |
|---------|-------------|
| `.dark` | `.dark` |
| `.light` | `.light` |
| `.custom(name)` | From `RemoteTheme.colorScheme` field (`"dark"` or `"light"`) |

## Server Theme Loading

### File locations
| What | Path | Priority |
|------|------|----------|
| Bundled themes | `server/themes/*.json` | Lower — shipped with server |
| User themes | `~/.config/oppi/data/themes/*.json` | Higher — user overrides bundled |

### API
| Method | Path | Description |
|--------|------|-------------|
| `GET /themes` | List all | Returns `{ themes: [{ name, filename, colorScheme }] }`. Merges bundled + user; user overrides by filename. |
| `GET /themes/:name` | Get one | Returns full `{ theme: { name, colorScheme, colors: { ...49 keys } } }` |
| `PUT /themes/:name` | Create/update | Validates 49 required keys, hex format. Saves to user dir. |
| `DELETE /themes/:name` | Remove | Only deletes from user dir (can't delete bundled). |

### Validation rules (PUT)
1. Body must have `{ theme: { colors: { ... } } }`
2. All 49 required keys must be present
3. Each value must be `""` (empty = use default) or `#RRGGBB` hex
4. Name is sanitized to `[a-zA-Z0-9_-]`

### Theme hot-reload
Currently: **no hot-reload**. Themes are read from disk on each API call (`readFileSync`). This means:
- Editing a JSON file on disk is immediately reflected on next `GET /themes/:name`
- No caching, no file watcher needed
- iOS re-fetches when entering ThemeImportView

For future consideration:
- **FSWatcher** on `data/themes/` for push-based notifications to connected iOS clients
- **WebSocket event** `theme_updated` so the app can re-apply without manual refresh
- **Session-start reload** — re-scan theme dirs when a pi session starts

### Creating a custom theme
```bash
# Create via API
curl -X PUT http://localhost:7749/themes/my-theme \
  -H 'Content-Type: application/json' \
  -d '{ "theme": { "name": "My Theme", "colorScheme": "dark", "colors": { ...49 keys... } } }'

# Or drop a JSON file directly
cp my-theme.json ~/.config/oppi/data/themes/
```

## iOS Theme Persistence

### Import flow
```
Settings → Import Theme → ThemeImportView
    │
    ├── GET /themes → list available
    ├── User taps theme → GET /themes/:name → full RemoteTheme
    ├── CustomThemeStore.save(remoteTheme) → UserDefaults (JSON)
    ├── themeStore.selectedThemeID = .custom(name)
    │       │
    │       ├── ThemeRuntimeState.setThemeID(.custom(name))
    │       ├── Color.theme* accessors resolve to new palette
    │       └── Views re-render with new colors
    │
    └── Theme works offline — full palette stored on device
```

### CustomThemeStore
- **Storage**: `UserDefaults` under key `dev.chenda.Oppi.customThemes`
- **Format**: `[String: RemoteTheme]` dict encoded as JSON data
- **Survives**: app restarts, no server needed after import
- **Operations**: `save(_:)`, `load(name:)`, `loadAll()`, `delete(name:)`, `names()`

### ThemeID persistence
- Selected theme stored in `UserDefaults` as raw string (`"dark"`, `"light"`, `"custom:Tokyo Night"`)
- On app launch: `ThemeID.loadPersisted()` reads and resolves
- Legacy migration: `"apple-dark"` → `.dark`, `"apple-light"` → `.light`, `"tokyo-night"` → `.custom("Tokyo Night")`

## Theme JSON Schema

```json
{
  "name": "Tokyo Night",
  "colorScheme": "dark",
  "colors": {
    "bg": "#1a1b26",
    "bgDark": "#16161e",
    "bgHighlight": "#292e42",
    "fg": "#c0caf5",
    "fgDim": "#a9b1d6",
    "comment": "#565f89",
    "blue": "#7aa2f7",
    "cyan": "#7dcfff",
    "green": "#9ece6a",
    "orange": "#ff9e64",
    "purple": "#bb9af7",
    "red": "#f7768e",
    "yellow": "#e0af68",
    "thinkingText": "#a9b1d6",

    "userMessageBg": "#292e42",
    "userMessageText": "#c0caf5",
    "toolPendingBg": "#1e2a4a",
    "toolSuccessBg": "#1e2e1e",
    "toolErrorBg": "#2e1e1e",
    "toolTitle": "#c0caf5",
    "toolOutput": "#a9b1d6",

    "mdHeading": "#7aa2f7",
    "mdLink": "#1abc9c",
    "mdLinkUrl": "#565f89",
    "mdCode": "#7aa2f7",
    "mdCodeBlock": "#9ece6a",
    "mdCodeBlockBorder": "#565f89",
    "mdQuote": "#565f89",
    "mdQuoteBorder": "#565f89",
    "mdHr": "#e0af68",
    "mdListBullet": "#ff9e64",

    "toolDiffAdded": "#449dab",
    "toolDiffRemoved": "#914c54",
    "toolDiffContext": "#545c7e",

    "syntaxComment": "#565f89",
    "syntaxKeyword": "#9d7cd8",
    "syntaxFunction": "#7aa2f7",
    "syntaxVariable": "#c0caf5",
    "syntaxString": "#9ece6a",
    "syntaxNumber": "#ff9e64",
    "syntaxType": "#2ac3de",
    "syntaxOperator": "#89ddff",
    "syntaxPunctuation": "#a9b1d6",

    "thinkingOff": "#505050",
    "thinkingMinimal": "#6e6e6e",
    "thinkingLow": "#5f87af",
    "thinkingMedium": "#81a2be",
    "thinkingHigh": "#b294bb",
    "thinkingXhigh": "#d183e8"
  }
}
```

## Token Audit Summary

After the full sweep (Feb 2026), all rendering paths use semantic tokens consistently:

| Renderer | Token source | Before | After |
|----------|-------------|--------|-------|
| `SyntaxHighlighter` | `Color.themeSyntax*` | Mixed base + syntax | All `themeSyntax*` |
| `MarkdownTextStorage` | `palette.md*` | Mixed base colors | All `palette.md*` |
| `MarkdownText` code block border | `Color.themeMdCodeBlockBorder` | `themeComment` | `themeMdCodeBlockBorder` |
| `ToolRowTextRenderer` inline diff | `Color.themeDiffAdded/Removed/Context` | `themeGreen/themeRed` | `themeDiff*` |
| `ToolTimelineRowContent` `+3/-2` labels | `Color.themeDiffAdded/Removed` | `themeGreen/themeRed` | `themeDiff*` |
| `SessionChangesView` line counts | `Color.themeDiffAdded/Removed` | `themeGreen/themeRed` | `themeDiff*` |
| `DiffContentView` | `theme.diff.*` (AppTheme) | Already correct | No change |
| `FullScreenCodeView` diff | `theme.diff.*` (AppTheme) | Already correct | No change |
| `ANSIParser` | `Color.themeRed/Green/Blue/...` | Base colors | No change (correct: ANSI codes map to base palette) |
| All UI chrome | `Color.themeBlue/Red/Green/...` | Base colors | No change (correct: badges, icons, borders) |
