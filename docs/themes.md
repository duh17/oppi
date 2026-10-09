# Custom themes

An Oppi theme is one JSON file of color tokens. The iOS chat, settings, and code surfaces read those tokens. Built-in themes (Dark, OLED, Light, Night) ship in the app. Custom themes live on your server; you import and apply them in **Settings → Appearance**.

## Where files live

| Location | What Oppi does |
| --- | --- |
| `$OPPI_DATA_DIR/themes/` if set, otherwise `~/.config/oppi/themes/` | Lists and serves Oppi JSON as-is |
| `~/.pi/agent/themes/` | Converts Pi TUI themes automatically |
| `server/themes/` in the Oppi repo | Bundled examples shipped with the server |

Filename: letters, numbers, underscore, hyphen, ending in `.json`. No server restart after you add or edit a file. The HTTP API is read-only (`GET /themes`, `GET /themes/:name`); create, update, or delete themes by changing files.

Apply a theme: **Settings → Appearance**, then pick it in the theme picker after you import it from **Custom Themes…**.

## Minimal example

```json
{
  "name": "Example Dark",
  "colorScheme": "dark",
  "colors": {
    "bg": "#1A1D29",
    "bgDark": "#151823",
    "bgHighlight": "#252B3D",
    "fg": "#C8D1EB",
    "fgDim": "#A2ACC9",
    "comment": "#98A4C4",
    "blue": "#7AA2F7",
    "cyan": "#78C8F2",
    "green": "#8FBE78",
    "orange": "#D8A86C",
    "purple": "#A08FD4",
    "red": "#E07A8C",
    "yellow": "#D4B06A",
    "thinkingText": "#8E98B7",
    "userMessageBg": "#3A4568",
    "userMessageText": "#C8D1EB",
    "toolPendingBg": "#252B3D",
    "toolSuccessBg": "#1E2A22",
    "toolErrorBg": "#2A1E22",
    "toolTitle": "#C8D1EB",
    "toolOutput": "#A2ACC9",
    "mdHeading": "#7AA2F7",
    "mdLink": "#78C8F2",
    "mdLinkUrl": "#98A4C4",
    "mdCode": "#78C8F2",
    "mdCodeBlock": "#8FBE78",
    "mdCodeBlockBorder": "#31384D",
    "mdQuote": "#A2ACC9",
    "mdQuoteBorder": "#31384D",
    "mdHr": "#31384D",
    "mdListBullet": "#D8A86C",
    "toolDiffAdded": "#73B07C",
    "toolDiffRemoved": "#CC7488",
    "toolDiffContext": "#98A4C4",
    "syntaxComment": "#98A4C4",
    "syntaxKeyword": "#A08FD4",
    "syntaxFunction": "#7AA2F7",
    "syntaxVariable": "#C8D1EB",
    "syntaxString": "#8FBE78",
    "syntaxNumber": "#D8A86C",
    "syntaxType": "#78C8F2",
    "syntaxOperator": "#C8D1EB",
    "syntaxPunctuation": "#A2ACC9",
    "thinkingOff": "#31384D",
    "thinkingMinimal": "#505A78",
    "thinkingLow": "#5E82C6",
    "thinkingMedium": "#67B4DD",
    "thinkingHigh": "#A08FD4",
    "thinkingXhigh": "#B596DE"
  }
}
```

`colorScheme` is `"dark"` or `"light"` and drives status bar and system chrome. Each color is `#RRGGBB`. Use `""` on a required token to take the app default for that key.

Optional speaker tokens (omit both to keep the built-in layout: user card elevated, assistant with no fill):

```json
{
  "assistantMessageBg": "",
  "userMessageAccent": "#7AA2F7"
}
```

## Contrast

- Text on a fill (user text on `userMessageBg`, assistant text on `assistantMessageBg` or on `bg` when that fill is empty) must be at least **4.5:1**.
- `userMessageAccent` versus `bg` must be at least **3:1**. That bar is the graphic that marks the user row; do not rely on fill hue alone.
- Assistant rows recede. Leave `assistantMessageBg` unset or empty unless you want a wash, and keep that wash close to `bg`.

iOS **Increase Contrast** uses a stronger built-in user fill plus a 1.5 pt accent border. **Differentiate Without Color** keeps the accent bar and adds a "You" caption on user rows. Custom themes still get the bar and caption; they do not get the built-in stronger fills.

## Token list

### Base (13) plus thinking text (1)

| Key | Paints |
| --- | --- |
| `bg` | Chat and main surfaces |
| `bgDark` | Code blocks, inset wells |
| `bgHighlight` | Elevated chrome, selections |
| `fg` | Primary text, including assistant body |
| `fgDim` | Secondary text |
| `comment` | Muted labels, timestamps |
| `blue` | Accent; default `userMessageAccent` |
| `cyan` | Types, inline code, teal chrome |
| `green` | Strings, success |
| `orange` | Numbers, warnings; Night's user accent |
| `purple` | Keywords |
| `red` | Errors, removals |
| `yellow` | Decorators |
| `thinkingText` | Thinking-block body |

### User and assistant (2 required, 2 optional)

| Key | Paints |
| --- | --- |
| `userMessageBg` | User card fill (the only elevated chat card) |
| `userMessageText` | User card text |
| `assistantMessageBg` | Optional assistant fill. Omit or empty: no fill |
| `userMessageAccent` | Optional 3 pt leading bar on the user card. Omit: `blue` |

### Tool state (5)

| Key | Paints |
| --- | --- |
| `toolPendingBg` | Tool row while running |
| `toolSuccessBg` | Tool row after success |
| `toolErrorBg` | Tool row after failure |
| `toolTitle` | Tool name |
| `toolOutput` | Tool body |

### Markdown (10)

| Key | Paints |
| --- | --- |
| `mdHeading` | Headings |
| `mdLink` | Link label |
| `mdLinkUrl` | Link URL |
| `mdCode` | Inline code |
| `mdCodeBlock` | Fenced code text |
| `mdCodeBlockBorder` | Code block border |
| `mdQuote` | Blockquote text |
| `mdQuoteBorder` | Blockquote bar |
| `mdHr` | Horizontal rule |
| `mdListBullet` | List markers |

### Diffs (3)

| Key | Paints |
| --- | --- |
| `toolDiffAdded` | Added line |
| `toolDiffRemoved` | Removed line |
| `toolDiffContext` | Context line |

### Syntax (9)

| Key | Paints |
| --- | --- |
| `syntaxComment` | Comments |
| `syntaxKeyword` | Keywords |
| `syntaxFunction` | Functions |
| `syntaxVariable` | Variables |
| `syntaxString` | Strings |
| `syntaxNumber` | Numbers |
| `syntaxType` | Types |
| `syntaxOperator` | Operators |
| `syntaxPunctuation` | Punctuation |

### Thinking levels (6)

| Key | Paints |
| --- | --- |
| `thinkingOff` | Thinking off |
| `thinkingMinimal` | Minimal |
| `thinkingLow` | Low |
| `thinkingMedium` | Medium |
| `thinkingHigh` | High |
| `thinkingXhigh` | Extra-high and max |

## Pi TUI conversion

Pi TUI themes in `~/.pi/agent/themes/` use 51 tokens plus variables. Oppi maps the shared Markdown, syntax, diff, tool, and thinking tokens, derives `bg` / `fg` / accent colors from Pi vars, and copies `assistantMessageBg` and `userMessageAccent` when the TUI file already has them. TUI-only tokens (`border`, `selectedBg`, `customMessage*`, `bashMode`, and similar) are dropped.

## Ask your agent

Settings → Appearance → **Create a Theme with Your Agent** copies a prompt that names these paths and this doc. Paste it into a chat.
