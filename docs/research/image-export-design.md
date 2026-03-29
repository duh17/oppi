# Image Export Design: Platform-Friendly Agent Content

The goal: export agent-generated content (markdown, tables, code) as images
optimized for sharing on social media. The output should look like a clean
document page, sized to the target platform.

## Core Insight

PDF has a fixed page size and no scroll. Social media images have a fixed
**width** but flexible height (up to a max), and platforms support carousels for
long content. This means:

- We control the canvas width (set it to the platform's optimal).
- We split tall content into multiple images (carousel).
- We never clip horizontally — we *make it fit* the width.

This is fundamentally different from PDF export, where the page is fixed and
content overflows. Here, the content defines the layout and the canvas adapts.

---

## Platform Specs

Dimensions are in pixels at 2x retina (render at 2x, export at listed sizes).

| Platform | Canvas Width | Max Height | Aspect Ratios | Max Images | Notes |
|---|---|---|---|---|---|
| X / Twitter | 1200 | 1350 (for 1:1-ish) or 1680 (4:5) | 1.91:1, 1:1, 4:5 | 4 | 1:1 and 4:5 get most feed real estate |
| Xiaohongshu | 1080 | 1440 | 3:4 preferred, 1:1 ok | 9 | 3:4 portrait dominates the platform |
| Instagram | 1080 | 1350 | 4:5 preferred, 1:1 ok | 20 | 4:5 gets most feed space |
| LinkedIn | 1200 | 1500 | 1:1, 4:5 | 20 | Professional context, 1:1 common |
| Substack | 1100 | Unlimited | Inline (no crop) | N/A | Images display at content width (~600px), but should be crisp at 1100px |
| WeChat | 1080 | 1440 | 3:4, 1:1 | 9 | Similar to Xiaohongshu |
| iMessage | 1200 | Unlimited | No crop | 1+ | Preview is small; full-size on tap |
| Generic | 1200 | 1600 | Free | Unlimited | Default / save-to-files |

**Safe defaults:** 1080px wide, 3:4 aspect max (1080x1440), carousel split.
This works acceptably across all platforms.

---

## Content Types & Fitting Strategy

Agent output falls into a few categories, each needing different handling:

### 1. Tables

Tables are the hard case. Strategy (in priority order):

1. **Wrap text in cells.** Set `table-layout: fixed; width: 100%` on the
   table. Cells wrap text to fit. This handles most tables with long-text
   columns (comparison tables, feature matrices).

2. **Scale down if still too wide.** After wrapping, if the table's minimum
   content width (driven by column count and minimum word widths) exceeds the
   canvas, uniformly scale the font down. Floor at ~10px effective (at 2x).
   Nobody does this automatically — it's our differentiator.

3. **Rotate to landscape.** If the table has 8+ narrow numeric columns and
   scaling makes text unreadable, render in landscape (swap width/height of
   the canvas). This only works for platforms that accept wider-than-tall
   images (X at 1.91:1, LinkedIn, Substack).

4. **Split horizontally.** Last resort. Render the full table, split into
   left and right panels across carousel images. Header column (first col)
   repeats on each panel. This is ugly but preserves all data.

**Decision logic:**
```
measure natural table width after text wrapping
if fits canvas width:
  done
else if fits at 75% font scale:
  scale to 75%
else if fits at 60% font scale:
  scale to 60%
else if platform allows landscape:
  render landscape, retry wrapping + scaling
else:
  split horizontally across carousel
```

### 2. Code Blocks

- Syntax-highlighted, monospace font.
- Wrap long lines at canvas width (not truncate).
- If wrapping makes the block too tall, split vertically across carousel
  images with a continuation indicator.
- Line numbers help readers track position across splits.

### 3. Prose / Markdown

- Render with good typography: system font stack, 16-18px base, 1.5 line
  height at 2x.
- Natural text reflow — just set the width and let text wrap.
- Split vertically at natural paragraph boundaries when possible (avoid
  splitting mid-paragraph).

### 4. Mixed Content

- Render as a single HTML document with all blocks.
- Split vertically into carousel images at the max height boundary.
- Prefer splitting between blocks (between a paragraph and a code block)
  over splitting within a block.

---

## Rendering Pipeline

```
┌──────────────────────────────────────────────────────┐
│  1. CONTENT → HTML                                   │
│     Markdown → HTML with our stylesheet              │
│     Tables get table-layout:fixed + wrapping CSS     │
│     Code gets syntax highlighting (Shiki / Prism)    │
└──────────────┬───────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────┐
│  2. MEASURE                                          │
│     Headless browser renders HTML at target width    │
│     Measure total content height                     │
│     Detect table overflow (scrollWidth > clientWidth) │
│     If overflow: re-render with scaled font / layout │
└──────────────┬───────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────┐
│  3. SPLIT                                            │
│     If height ≤ max: single image                    │
│     If height > max: find split points               │
│       - Prefer between block-level elements          │
│       - Avoid splitting tables/code mid-block        │
│       - Add overlap (repeated header row for tables) │
│       - Cap at platform's max image count            │
└──────────────┬───────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────┐
│  4. CAPTURE                                          │
│     Screenshot each region at 2x device pixel ratio  │
│     Export as PNG (sharp text) or JPEG (photos)      │
│     Add optional chrome: page indicator (1/4), brand │
└──────────────────────────────────────────────────────┘
```

### Technology

- **Renderer:** Offscreen `WKWebView` on iOS/macOS. Native WebKit rendering
  matches what users already see in the app.
- **Approach:** `WKWebView.takeSnapshot(with:)` per region. Retina scale is
  automatic from the device's screen scale.
- **Template:** Self-contained HTML string with inlined CSS. No external
  resources, no network. Dark and light theme variants.

---

## Visual Design

The image should look like a polished document excerpt, not a raw screenshot.

### Chrome

```
┌─────────────────────────────────────┐
│  ○ Oppi                       1/3   │  ← Minimal header: brand + page count
├─────────────────────────────────────┤
│                                     │
│  ## Analysis Results                │
│                                     │
│  | Metric | Before | After |        │
│  |--------|--------|-------|        │
│  | Speed  | 2.3s   | 0.8s  |       │
│  | Memory | 512MB  | 128MB |       │
│                                     │
│  The optimization reduced memory    │
│  usage by 75% while improving...    │
│                                     │
└─────────────────────────────────────┘
```

- **Background:** White (#FFFFFF) for light, dark gray (#1C1C1E) for dark.
- **Padding:** 48px horizontal, 40px vertical (at 2x). Enough breathing room
  to not feel cramped, not so much that content area is tiny.
- **Header:** Optional. Subtle brand mark + page indicator for carousels.
  8px font, 60% opacity. Absolutely not a logo bar.
- **Corner radius:** 0px. Platforms apply their own rounding on display.
- **Border:** None. The background color provides enough contrast.

### Typography

- **Body:** -apple-system, SF Pro, system-ui. 32px at 2x (renders as 16px).
- **Headings:** Same family, bold. H1=48px, H2=40px, H3=36px at 2x.
- **Code:** SF Mono, Menlo, monospace. 28px at 2x (renders as 14px).
- **Line height:** 1.6 for body, 1.4 for code, 1.3 for table cells.
- **Colors:** High contrast. Body text at 90% opacity on background.

### Tables

- Alternating row stripes (very subtle, 3-4% opacity difference).
- 1px border, 8% opacity on background.
- Header row: bold, slightly darker background.
- Cell padding: 16px horizontal, 12px vertical at 2x.
- Text alignment: left for text columns, right for numeric columns.

### Code

- GitHub-style syntax theme (light) or One Dark (dark).
- Subtle background tint to differentiate from prose.
- Corner radius on the code block: 12px at 2x.
- Line numbers for blocks > 5 lines.

---

## Platform Presets

Each preset is a named configuration:

```typescript
interface ImageExportPreset {
  name: string              // "x", "xiaohongshu", "instagram", etc.
  canvasWidth: number       // px at 2x
  maxHeight: number         // px at 2x — split if taller
  maxImages: number         // carousel limit
  padding: { h: number, v: number }
  allowLandscape: boolean   // can we flip to wider aspect?
  landscapeWidth?: number   // wider canvas if flipped
  landscapeMaxHeight?: number
}

const presets: Record<string, ImageExportPreset> = {
  x: {
    name: "X / Twitter",
    canvasWidth: 2400,       // 1200 @ 2x
    maxHeight: 2700,         // ~4:5 at 2x
    maxImages: 4,
    padding: { h: 96, v: 80 },
    allowLandscape: true,
    landscapeWidth: 2400,
    landscapeMaxHeight: 1256, // 1.91:1
  },
  xiaohongshu: {
    name: "Xiaohongshu",
    canvasWidth: 2160,       // 1080 @ 2x
    maxHeight: 2880,         // 3:4 at 2x
    maxImages: 9,
    padding: { h: 96, v: 80 },
    allowLandscape: false,   // portrait-dominant platform
  },
  instagram: {
    name: "Instagram",
    canvasWidth: 2160,       // 1080 @ 2x
    maxHeight: 2700,         // 4:5 at 2x
    maxImages: 20,
    padding: { h: 96, v: 80 },
    allowLandscape: false,   // 4:5 best for feed
  },
  linkedin: {
    name: "LinkedIn",
    canvasWidth: 2400,       // 1200 @ 2x
    maxHeight: 3000,         // flexible
    maxImages: 20,
    padding: { h: 96, v: 80 },
    allowLandscape: true,
    landscapeWidth: 2400,
    landscapeMaxHeight: 1256,
  },
  substack: {
    name: "Substack",
    canvasWidth: 2200,       // 1100 @ 2x
    maxHeight: 6000,         // tall is fine, inline display
    maxImages: 1,            // typically single inline
    padding: { h: 80, v: 64 },
    allowLandscape: true,
  },
  generic: {
    name: "Generic",
    canvasWidth: 2400,       // 1200 @ 2x
    maxHeight: 3200,         // ~4:5-ish
    maxImages: 20,
    padding: { h: 96, v: 80 },
    allowLandscape: true,
    landscapeWidth: 3200,
    landscapeMaxHeight: 2400,
  },
}
```

---

## Implementation Phases

### Phase 1: Single-image, generic preset

- HTML template with markdown rendering + table CSS.
- Headless Chromium screenshot at fixed width.
- Table wrapping + font scaling for overflow.
- Light and dark themes.
- Export as PNG.

### Phase 2: Carousel splitting

- Content height measurement.
- Smart split-point detection (between blocks, not mid-block).
- Page indicators on multi-image output.
- Repeated table headers across splits.

### Phase 3: Platform presets

- Named presets with per-platform dimensions.
- iOS share sheet integration: pick preset → render → share.
- "Auto" mode: detect paste target from share destination if possible.

### Phase 4: Refinement

- Landscape detection for wide tables.
- Horizontal table splitting for extreme cases.
- User-adjustable font size / padding.
- Template variants (minimal, branded, academic).

---

## Rendering Approach

Client-side via offscreen WKWebView. No server round-trip needed.

- Render the HTML template in an offscreen `WKWebView`.
- Use `takeSnapshot(with:completionHandler:)` to capture as `UIImage`.
- Set WKWebView width to `canvasWidth / 2` points (renders at 2x on retina
  devices automatically via screen scale).
- Measure content height via JS (`document.body.scrollHeight`) to determine
  split points before capture.
- For carousel: reposition the WKWebView's scroll offset or use
  `clip` regions for each page, capture sequentially.
- All rendering is local, instant, no network dependency.

---

## Key Decisions

1. **Wrap first, scale second.** Text wrapping is always better than font
   scaling because it preserves readability. Only scale when wrapping alone
   can't fit the content (many-column numeric tables).

2. **Carousel over truncation.** Never clip content. If it doesn't fit one
   image, split into multiple. Users scroll carousels; they can't recover
   clipped data.

3. **2x rendering for all platforms.** Every modern phone is retina. Rendering
   at 1x looks blurry on every device that matters.

4. **PNG for text, JPEG for mixed.** Text rendered as JPEG gets compression
   artifacts around letterforms. PNG keeps text sharp. For images that contain
   both text and photos, JPEG at q95 is a reasonable tradeoff.

5. **Dark/light follows system or user choice.** Default to light (better for
   most social contexts), but dark mode should be available — it's popular for
   code-heavy content sharing.
