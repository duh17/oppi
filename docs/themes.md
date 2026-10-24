# Custom themes

An Oppi theme is one JSON file of color tokens. The iOS chat, settings, and code surfaces read those tokens. Built-in themes (Dark, OLED, Light, Night) ship in the app. Custom themes live on your server; you import and apply them in **Settings → Appearance**.

## Create or change a theme

- **With Oppi:** in **Settings → Appearance → Custom Themes**, describe a theme in the composer. Oppi starts a setup session that reads this page and writes the JSON file to the themes folder. To change a theme, swipe it (or touch and hold) and choose **Edit with Oppi**. For a bundled or Pi TUI theme, the session writes an override with the same filename. See [Edit with Oppi](usage.md#edit-with-oppi).
- **By hand:** write the file in the themes folder (below), pull to refresh **Custom Themes**, tap the theme to import it, then pick it in the theme picker.

## Where files live

| Location | What Oppi does |
| --- | --- |
| `$OPPI_DATA_DIR/themes/` if set, otherwise `~/.config/oppi/themes/` | Lists and serves Oppi JSON as-is |
| `~/.pi/agent/themes/` | Converts Pi TUI themes automatically |
| `server/themes/` in the Oppi repo | Bundled examples shipped with the server |

The filename uses letters, numbers, underscore, and hyphen, and ends in `.json`. Adding or editing a file needs no server restart. The server only reads theme files; you create, change, and delete themes by changing files.

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

`colorScheme` is `"dark"` or `"light"` and drives the status bar and system chrome. Each color is `#RRGGBB`. Set `""` on a required token to take the app default for that key.

Two optional tokens change how chat rows look. Omit either, or set `""`, for the built-in look.

```json
{
  "assistantMessageBg": "#1E2233",
  "userMessageAccent": "#7AA2F7"
}
```

## Contrast

Built-in themes set their contrast automatically, like Pi's system theme ([Earendil](https://earendil.com/posts/system-theme/)). Custom themes are used exactly as written, so check these rules yourself:

- Text on a fill must reach **4.5:1**. That covers user text on `userMessageBg`, and assistant text on `assistantMessageBg` (or on `bg` when that fill is empty).
- Keep `userMessageBg` visibly apart from `bg`, and from `assistantMessageBg` when you set it, so your prompts stand out.
- Keep `userMessageAccent` at least **3:1** against `bg`.
- Assistant rows recede. Leave `assistantMessageBg` unset unless you want a wash, and keep it close to `bg`.

iOS **Increase Contrast** uses a stronger built-in user fill plus a 1.5 pt border in `userMessageAccent` (or `userMessageText` without an accent). **Differentiate Without Color** adds a "You" caption on user rows. Custom themes get the border and caption, but not the stronger built-in fill.

## Tokens

Your prompts are a card filled with `userMessageBg`. Assistant replies always span the full width.

| Group | Key | Paints |
| --- | --- | --- |
| Base | `bg` | Chat and main surfaces |
| | `bgDark` | Code blocks, inset wells |
| | `bgHighlight` | Elevated chrome, selections |
| | `fg` | Primary text, including assistant body |
| | `fgDim` | Secondary text |
| | `comment` | Muted labels, timestamps |
| | `blue` | Accent |
| | `cyan` | Types, inline code, teal chrome |
| | `green` | Strings, success |
| | `orange` | Numbers, warnings |
| | `purple` | Keywords |
| | `red` | Errors, removals |
| | `yellow` | Decorators |
| | `thinkingText` | Thinking-block body |
| User and assistant | `userMessageBg` | User card fill (the only elevated chat card) |
| | `userMessageText` | User card text |
| | `assistantMessageBg` | Optional assistant fill. Omit or empty: no fill |
| | `userMessageAccent` | Optional 3 pt strip on the leading edge of the user card. Omit or empty: no strip |
| Tool state | `toolPendingBg` / `toolSuccessBg` / `toolErrorBg` | Tool row while running, after success, after failure |
| | `toolTitle` | Tool name |
| | `toolOutput` | Tool body |
| Markdown | `mdHeading` | Headings |
| | `mdLink` / `mdLinkUrl` | Link label / link URL |
| | `mdCode` | Inline code |
| | `mdCodeBlock` / `mdCodeBlockBorder` | Fenced code text / its border |
| | `mdQuote` / `mdQuoteBorder` | Blockquote text / its bar |
| | `mdHr` | Horizontal rule |
| | `mdListBullet` | List markers |
| Diffs | `toolDiffAdded` / `toolDiffRemoved` / `toolDiffContext` | Added, removed, and context lines |
| Syntax | `syntaxComment` / `syntaxKeyword` / `syntaxFunction` | Comments, keywords, functions |
| | `syntaxVariable` / `syntaxString` / `syntaxNumber` | Variables, strings, numbers |
| | `syntaxType` / `syntaxOperator` / `syntaxPunctuation` | Types, operators, punctuation |
| Thinking levels | `thinkingOff` / `thinkingMinimal` / `thinkingLow` / `thinkingMedium` / `thinkingHigh` | The level's indicator |
| | `thinkingXhigh` | Extra-high and max |

All keys except `assistantMessageBg` and `userMessageAccent` are required.

## Pi TUI conversion

Pi TUI themes in `~/.pi/agent/themes/` use 51 tokens plus variables. Oppi maps the shared Markdown, syntax, diff, tool, and thinking tokens, and derives `bg`, `fg`, and accent colors from the Pi variables. It copies `assistantMessageBg` and `userMessageAccent` when the TUI file has them. TUI-only tokens (`border`, `selectedBg`, `customMessage*`, `bashMode`, and similar) are dropped.
