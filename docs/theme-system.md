# Oppi Theme System

Create custom color themes for the Oppi iOS app. A theme is a single JSON file with 49 color tokens. Upload it to your server, then import it from Settings in the app.

## File format

```json
{
  "name": "My Theme",
  "colorScheme": "dark",
  "colors": {
    "bg": "#1a1b26",
    ...
  }
}
```

- `name` — display name shown in the app
- `colorScheme` — `"dark"` or `"light"` (controls status bar, system chrome)
- `colors` — object with all 49 keys below, each a `#RRGGBB` hex string

All 49 keys are required. Use `""` (empty string) to fall back to the default for that token.

## Color tokens

### Base palette (14)

The foundation. Every other group derives from these when using defaults.

| Key | Purpose |
|-----|---------|
| `bg` | Primary background (main chat surface) |
| `bgDark` | Darker background (code blocks, inset areas) |
| `bgHighlight` | Elevated background (headers, selections) |
| `fg` | Primary text color |
| `fgDim` | Secondary/dimmed text |
| `comment` | Tertiary/muted text (timestamps, placeholders) |
| `blue` | Accent — links, headings, functions |
| `cyan` | Accent — types, inline code, teal elements |
| `green` | Accent — strings, success, diff additions |
| `orange` | Accent — numbers, list bullets, warnings |
| `purple` | Accent — keywords, hunk headers |
| `red` | Accent — errors, diff removals, strings (Xcode style) |
| `yellow` | Accent — decorators, horizontal rules |
| `thinkingText` | Text color inside thinking blocks |

### User message (2)

| Key | Purpose |
|-----|---------|
| `userMessageBg` | Background of the user's chat bubbles |
| `userMessageText` | Text color in user chat bubbles |

### Tool state (5)

Colors for tool call rows (read, edit, bash, etc.) in different states.

| Key | Purpose |
|-----|---------|
| `toolPendingBg` | Background while tool is running |
| `toolSuccessBg` | Background after tool succeeds |
| `toolErrorBg` | Background after tool fails |
| `toolTitle` | Tool name / title text |
| `toolOutput` | Tool output body text |

### Markdown (10)

Rendered markdown in assistant messages.

| Key | Purpose |
|-----|---------|
| `mdHeading` | Heading text (`#`, `##`, etc.) |
| `mdLink` | Link label text |
| `mdLinkUrl` | Link URL text (dimmed) |
| `mdCode` | Inline code spans |
| `mdCodeBlock` | Fenced code block text |
| `mdCodeBlockBorder` | Border around code blocks |
| `mdQuote` | Blockquote text |
| `mdQuoteBorder` | Blockquote left border |
| `mdHr` | Horizontal rule color |
| `mdListBullet` | Bullet / list marker color |

### Diffs (3)

Unified diff rendering in tool output.

| Key | Purpose |
|-----|---------|
| `toolDiffAdded` | Added line accent (text + left bar) |
| `toolDiffRemoved` | Removed line accent (text + left bar) |
| `toolDiffContext` | Context line text |

### Syntax highlighting (9)

Code blocks use tree-sitter tokenization mapped to these colors.

| Key | Purpose |
|-----|---------|
| `syntaxComment` | Comments |
| `syntaxKeyword` | Keywords (`if`, `let`, `return`, etc.) |
| `syntaxFunction` | Function / method names |
| `syntaxVariable` | Variable names |
| `syntaxString` | String literals |
| `syntaxNumber` | Numeric literals |
| `syntaxType` | Type names / annotations |
| `syntaxOperator` | Operators (`+`, `=`, `->`, etc.) |
| `syntaxPunctuation` | Punctuation (brackets, commas, semicolons) |

### Thinking level indicators (6)

The thinking budget indicator changes color based on how much thinking the model is doing.

| Key | Purpose |
|-----|---------|
| `thinkingOff` | Thinking disabled |
| `thinkingMinimal` | Minimal thinking |
| `thinkingLow` | Low thinking |
| `thinkingMedium` | Medium thinking |
| `thinkingHigh` | High thinking |
| `thinkingXhigh` | Maximum thinking |

## Creating a theme

Start from a bundled example in `server/themes/`. The bundled themes are:

- `tokyo-night.json` — dark, Tokyo Night color scheme
- `tokyo-night-storm.json` — dark, Tokyo Night Storm variant
- `tokyo-night-day.json` — light, Tokyo Night Day variant
- `nord.json` — dark, Nord color scheme

### Tips

- For dark themes: `bg` should be dark (#1a1b26 range), `fg` should be light (#c0caf5 range)
- For light themes: invert that. `bg` light, `fg` dark
- Tool state backgrounds should be very subtle — use low-opacity tints of your accent colors (e.g. blue at 12% for pending, green at 8% for success, red at 10% for error)
- Diff backgrounds are rendered as accent + left bar; the app adds its own background opacity
- Ensure enough contrast between `bg` and `fg` (aim for WCAG AA, 4.5:1 ratio minimum)
- Syntax colors should be distinguishable from each other against `bgDark`

## Installing a theme

Write the theme JSON file to the server's theme directory:

```bash
mkdir -p ~/.config/oppi/themes
# Write your theme file here — filename becomes the theme ID
cp my-theme.json ~/.config/oppi/themes/my-theme.json
```

The server picks it up automatically. Then in the iOS app: **Settings > Import Theme > select server > select your theme**.

All 49 color keys must be present. Each value must be `#RRGGBB` or `""` (empty = use default). Filename should use `[a-zA-Z0-9_-]` only.

## Relationship to pi TUI themes

Oppi's theme tokens are a subset of the [pi TUI theme system](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/themes.md). Pi's TUI uses 51 color tokens; Oppi uses 49 — the shared tokens (markdown, syntax, diffs, tool state, thinking) are identical. Oppi drops TUI-only tokens (`border`, `borderAccent`, `borderMuted`, `selectedBg`, `customMessage*`, `bashMode`) and adds mobile equivalents (`bg`, `bgDark`, `bgHighlight`, `fg`, `fgDim`, `comment`).

You can ask pi to create a theme for you — point it at this doc and describe what you want. If you already have a pi TUI theme, reuse the same color palette — map the overlapping tokens and fill in the Oppi-specific ones.

## Complete example

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
