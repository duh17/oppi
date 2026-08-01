# Oppi Theme System

Create custom color themes for the Oppi iOS app. A theme is one JSON file with 49 color tokens. Write it to the server's theme directory, then import it from Settings in the app.

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

- `name` — display name in the app
- `colorScheme` — `"dark"` or `"light"`; controls the status bar and system chrome
- `colors` — object with all 49 keys below; each is a `#RRGGBB` hex string

All 49 keys are required. Use `""` (an empty string) to use the default for that token.

## Color tokens

### Base palette (14)

The foundation. With default values, every other group derives from these tokens.

| Key            | Purpose                                               |
| -------------- | ----------------------------------------------------- |
| `bg`           | Primary background (main chat surface)                |
| `bgDark`       | Darker background (code blocks, inset areas)          |
| `bgHighlight`  | Elevated background (headers, selections)             |
| `fg`           | Primary text color                                    |
| `fgDim`        | Secondary/dimmed text                                 |
| `comment`      | Tertiary/muted text (timestamps, placeholders)        |
| `blue`         | Accent — links, headings, functions                   |
| `cyan`         | Accent — types, inline code, teal elements            |
| `green`        | Accent — strings, success, diff additions             |
| `orange`       | Accent — numbers, list bullets, warnings              |
| `purple`       | Accent — keywords, hunk headers                       |
| `red`          | Accent — errors, diff removals, strings (Xcode style) |
| `yellow`       | Accent — decorators, horizontal rules                 |
| `thinkingText` | Text color inside thinking blocks                     |

### User message (2)

| Key               | Purpose                               |
| ----------------- | ------------------------------------- |
| `userMessageBg`   | Background of the user's chat bubbles |
| `userMessageText` | Text color in user chat bubbles       |

### Tool state (5)

Colors for tool-call rows (read, edit, bash, and others) in different states.

| Key             | Purpose                          |
| --------------- | -------------------------------- |
| `toolPendingBg` | Background while tool is running |
| `toolSuccessBg` | Background after tool succeeds   |
| `toolErrorBg`   | Background after tool fails      |
| `toolTitle`     | Tool name / title text           |
| `toolOutput`    | Tool output body text            |

### Markdown (10)

Colors for rendered Markdown in assistant messages.

| Key                 | Purpose                        |
| ------------------- | ------------------------------ |
| `mdHeading`         | Heading text (`#`, `##`, etc.) |
| `mdLink`            | Link label text                |
| `mdLinkUrl`         | Link URL text (dimmed)         |
| `mdCode`            | Inline code spans              |
| `mdCodeBlock`       | Fenced code block text         |
| `mdCodeBlockBorder` | Border around code blocks      |
| `mdQuote`           | Blockquote text                |
| `mdQuoteBorder`     | Blockquote left border         |
| `mdHr`              | Horizontal rule color          |
| `mdListBullet`      | Bullet / list marker color     |

### Diffs (3)

Colors for unified diffs in tool output.

| Key               | Purpose                               |
| ----------------- | ------------------------------------- |
| `toolDiffAdded`   | Added line accent (text + left bar)   |
| `toolDiffRemoved` | Removed line accent (text + left bar) |
| `toolDiffContext` | Context line text                     |

### Syntax highlighting (9)

Code blocks map tree-sitter tokens to these colors.

| Key                 | Purpose                                    |
| ------------------- | ------------------------------------------ |
| `syntaxComment`     | Comments                                   |
| `syntaxKeyword`     | Keywords (`if`, `let`, `return`, etc.)     |
| `syntaxFunction`    | Function / method names                    |
| `syntaxVariable`    | Variable names                             |
| `syntaxString`      | String literals                            |
| `syntaxNumber`      | Numeric literals                           |
| `syntaxType`        | Type names / annotations                   |
| `syntaxOperator`    | Operators (`+`, `=`, `->`, etc.)           |
| `syntaxPunctuation` | Punctuation (brackets, commas, semicolons) |

### Thinking level indicators (7 levels, 6 color tokens)

The thinking-budget indicator changes color with how much thinking the model is doing. `max` shares the highest-level `thinkingXhigh` color token so existing themes remain compatible.

| Key               | Purpose                              |
| ----------------- | ------------------------------------ |
| `thinkingOff`     | Thinking disabled                    |
| `thinkingMinimal` | Minimal thinking                     |
| `thinkingLow`     | Low thinking                         |
| `thinkingMedium`  | Medium thinking                      |
| `thinkingHigh`    | High thinking                        |
| `thinkingXhigh`   | Extra-high (`xhigh`) and `max` thinking |

## Creating a theme

Start with a bundled example in `server/themes/`:

- `night.json` — dark, high-contrast Night theme
- `latte-things.json` — light, Latte Things theme
- `nord.json` — dark, Nord color scheme
- `tokyo-night.json` — dark, Tokyo Night color scheme
- `tokyo-night-storm.json` — dark, Tokyo Night Storm variant
- `tokyo-night-day.json` — light, Tokyo Night Day variant

### Tips

- For dark themes, `bg` should be dark (#1a1b26 range) and `fg` should be light (#c0caf5 range).
- For light themes, use a light `bg` and a dark `fg`.
- Tool-state backgrounds should be subtle. Use low-opacity tints of accent colors—for example, blue at 12% for pending, green at 8% for success, and red at 10% for error.
- Diff backgrounds render as an accent plus a left bar; the app adds its own background opacity.
- Ensure enough contrast between `bg` and `fg`; aim for WCAG AA's 4.5:1 minimum ratio.
- Syntax colors should be distinguishable from one another against `bgDark`.

## Installing a theme

Write the theme JSON file to the server's theme directory:

```bash
mkdir -p ~/.config/oppi/themes
# Write your theme file here — filename becomes the theme ID
cp my-theme.json ~/.config/oppi/themes/my-theme.json
```

If the server uses `OPPI_DATA_DIR`, use `$OPPI_DATA_DIR/themes/` instead.

The server picks it up automatically. Then, in the iOS app, choose **Settings > Import Theme > select server > select your theme**.

All 49 color keys must be present. Each value must be `#RRGGBB` or `""` (empty uses the default). The filename should use only `[a-zA-Z0-9_-]`.

## Agent-friendly theme creation

Create themes by writing the JSON file directly to `~/.config/oppi/themes/`, or to `$OPPI_DATA_DIR/themes/` when the server uses a custom data dir. No server restart is required.

Theme routes are available for clients:

| Method | Path            | Purpose                           |
| ------ | --------------- | --------------------------------- |
| `GET`  | `/themes`       | List bundled, pi, and user themes |
| `GET`  | `/themes/:name` | Fetch a theme                     |

Bundled themes live in `server/themes/`. User themes live in `~/.config/oppi/themes/`. When possible, Oppi detects and converts Pi TUI themes in `~/.pi/agent/themes/` automatically. The current server API does not write or delete themes; create, update, or remove user themes by changing files in the theme directory.

## Relationship to pi TUI themes

Oppi's theme tokens are a subset of the [Pi TUI theme system](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/themes.md). Pi's TUI uses 51 color tokens; Oppi uses 49. The shared tokens—Markdown, syntax, diffs, tool state, and thinking—are identical. Oppi drops TUI-only tokens (`border`, `borderAccent`, `borderMuted`, `selectedBg`, `customMessage*`, `bashMode`) and adds mobile equivalents (`bg`, `bgDark`, `bgHighlight`, `fg`, `fgDim`, `comment`).

You can ask Pi to create a theme; point it to this document and describe what you want. If you already have a Pi TUI theme, reuse its color palette: map the overlapping tokens and fill in the Oppi-specific ones.

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
