# Wide Table Export Behavior Across Document/Markdown Apps

Research into how major apps handle tables that exceed the printable page width
when exporting to PDF or image.

Date: 2026-03-29

## Summary

No major app automatically scales fonts, switches to landscape, or intelligently
reflows wide tables during export. The universal pattern: tables either wrap text
within cells (shrinking row height to fit column widths) or clip/overflow beyond
the page boundary. Horizontal scroll is the web-native solution; PDF has no
equivalent, so wide tables are simply cut off.

---

## 1. Google Docs

**Export mechanism:** Built-in "Download as PDF" via Google's server-side renderer.

| Behavior | Details |
|---|---|
| Text wrapping | Yes. Cell text wraps within the column width set in the editor. This is the primary mechanism for fitting tables. |
| Font scaling | No. Font size is preserved exactly as set in the document. |
| Overflow/clipping | If a table is manually dragged wider than page margins, the right side is clipped in PDF output. No warning is shown. |
| Auto landscape | No. Orientation is a document-level (or section-level) setting that must be changed manually via File > Page Setup. Google Docs added per-section orientation support, but it requires manual setup. |
| Page splitting | Tables split across page breaks vertically (rows continue to next page). Individual rows can also split mid-cell across pages, which is a long-standing bug -- the "Allow row to overflow across pages" table property does not reliably carry over to PDF export. |
| Mobile vs desktop | Export is server-side, so output is identical regardless of where the export is triggered. |

**Key insight:** Google Docs constrains table width to the page margins in the
editor by default. Problems arise when users manually resize columns wider than
the page, or when content is pasted from external sources. The PDF exporter does
not reflow or scale -- it renders what the editor shows.

**Sources:** [SO #70554478](https://stackoverflow.com/questions/70554478/), [Google Docs support thread #41933766](https://support.google.com/docs/thread/41933766)

---

## 2. Microsoft Word

**Export mechanism:** Built-in "Save as PDF" or "Export to PDF" via Word's
internal renderer.

| Behavior | Details |
|---|---|
| Text wrapping | Yes, when using **AutoFit Window** mode. Word has three AutoFit modes: "AutoFit Contents" (size to content, may overflow), "AutoFit Window" (constrain to page margins, wrap text), and "Fixed Column Width" (manual). |
| Font scaling | No. Word never automatically reduces font size to fit a table. `fit_to_width()` in libraries like flextable does scale fonts, but this is external tooling, not Word itself. |
| Overflow/clipping | With "AutoFit Contents" or "Fixed Column Width", tables can extend beyond the right margin. The overflowing portion is simply cut off in PDF output. Word does not warn the user. |
| Auto landscape | No. Orientation is set per-section. Users must manually insert section breaks and change orientation for sections containing wide tables. |
| Page splitting | Tables split across pages vertically. "Allow row to break across pages" is a per-table property (enabled by default). Header rows can repeat on subsequent pages via "Repeat as header row at the top of each page". |
| Mobile vs desktop | Word mobile apps have limited table editing. PDF export on mobile produces the same layout as desktop for the same document. |

**Key insight:** Word's `AutoFit Window` is the closest any app gets to
automatic wide-table handling. It constrains the table to page margins and wraps
cell text aggressively. But it must be explicitly selected -- the default for
pasted or imported tables is often "Fixed" or "AutoFit Contents", both of which
can overflow. The PDF exporter is a faithful renderer of the document layout, not
a reflower.

**Sources:** [SO #57175351](https://stackoverflow.com/questions/57175351/), [SO #56327396](https://stackoverflow.com/questions/56327396/), [MS Support: AutoFitBehavior](https://learn.microsoft.com/en-us/office/vba/api/word.table.autofitbehavior)

---

## 3. Apple Pages

**Export mechanism:** Built-in "Export to PDF" via macOS/iOS native renderer.

| Behavior | Details |
|---|---|
| Text wrapping | Yes. Pages wraps text within cells by default. Column widths are user-set or auto-distributed. |
| Font scaling | No. Pages does not scale fonts to fit tables. |
| Overflow/clipping | If a table is manually resized wider than the page, content beyond the margins is clipped in PDF. Users must manually reduce column widths. From Apple Community: "In the Size section, incrementally reduce the width of your table until it fits on your page." |
| Auto landscape | No. Page orientation is a document-level setting changed via Document inspector. No per-section landscape support. |
| Page splitting | Tables can continue across pages vertically. Unlike Word, Pages does **not** split individual cells across page boundaries -- if a row doesn't fit, the entire row moves to the next page. This can leave large gaps at the bottom of pages. "Stay on Page" vs "Move in Text" controls whether the table is anchored or flows with text. |
| Mobile vs desktop | Pages on iPad/iPhone uses the same layout engine. Export produces identical output. |

**Key insight:** Pages is more conservative than Word about table splitting.
The refusal to split cells across pages means very tall rows can waste space, but
it also means content is never mid-cell truncated. For wide tables, Pages offers
no automatic solution -- users must manually resize or switch to landscape.

**Sources:** [Apple Community #254007227](https://discussions.apple.com/thread/254007227), [Apple Community #252551203](https://discussions.apple.com/thread/252551203), [Apple SE #456724](https://apple.stackexchange.com/questions/456724/)

---

## 4. Notion

**Export mechanism:** Built-in "Export as PDF" (server-rendered) or browser
print (Ctrl/Cmd+P).

| Behavior | Details |
|---|---|
| Text wrapping | Partial. Simple table blocks wrap text within cells. Database table views with many properties/columns do not reflow -- they render at whatever width the database view requires. |
| Font scaling | No. |
| Overflow/clipping | Wide database tables are **clipped** in PDF export. Columns extending beyond the page width are truncated with no indication. This is the most commonly reported Notion export complaint. |
| Auto landscape | No. Notion's native PDF export has no orientation option. The workaround is to use browser print (Ctrl+P) and manually select landscape. |
| Page splitting | Page breaks are placed arbitrarily. Tables, code blocks, and other blocks may be split mid-content. Users report: "The page breaks are just random and don't create meaningful pages." |
| Mobile vs desktop | Export on mobile is identical to desktop (server-rendered). Both suffer from the same clipping issues. |

**Key insight:** Notion's PDF export is widely considered the weakest of the
major document apps. Reddit threads consistently describe it as unreliable for
tables, with "table columns got misaligned" and "text blocks got misaligned"
being common complaints. The recommended workaround for wide tables is to export
to HTML or Markdown first, then convert externally.

**Sources:** [r/Notion: export complaints](https://www.reddit.com/r/Notion/comments/147liaw/), [r/Notion: cut text on export](https://www.reddit.com/r/Notion/comments/14lj87i/), [r/Notion: PDF format guide](https://www.reddit.com/r/Notion/comments/mo8hm2/)

---

## 5. Markdown Editors

### Bear

**Export mechanism:** WebKit-based print-to-PDF.

| Behavior | Details |
|---|---|
| Text wrapping | Minimal. Tables render at natural width based on content. |
| Font scaling | No. |
| Overflow/clipping | Wide tables are **cut off** in PDF export and print. This is a known, acknowledged bug. Community reports: "Every time I try to print a document that contains a table, I have to export it to .docx format first." Tables also get "cut in half" across page breaks. |
| Auto landscape | No. |
| Page splitting | Tables split mid-row across pages with no intelligence about row boundaries. |
| Workaround | Export to .docx first, then print/PDF from Word or Pages. |

**Sources:** [Bear Community #13395](https://community.bear.app/t/table-cut-off-during-pdf-export-or-print/13395), [Bear Community #11128](https://community.bear.app/t/tables-get-cut-in-half-during-pdf-export/11128), [Bear Community #5226](https://community.bear.app/t/error-exporting-a-multi-column-table-from-panda-to-pdf/5226)

### Obsidian

**Export mechanism:** Chromium print-to-PDF (built-in) or Pandoc plugin
(LaTeX/wkhtmltopdf).

| Behavior | Details |
|---|---|
| Text wrapping | Default CSS wraps text within cells, but column widths follow content/markdown column sizing. |
| Font scaling | No (built-in). The community plugin "Better Export PDF" (229k+ downloads) offers some additional control. |
| Overflow/clipping | Wide tables overflow the page and are clipped. Custom CSS snippets can partially mitigate this (e.g., `table { width: 100%; table-layout: fixed; }`). |
| Auto landscape | No built-in option. Pandoc plugin can pass `--variable geometry:landscape` for LaTeX output. |
| Page splitting | Tables split across pages. The "table-extended" community plugin's merged cells may not render at all in PDF export. |

**Sources:** [Obsidian Forum #13107](https://forum.obsidian.md/t/page-breaks-for-pdfs/13107), [Obsidian Forum #44158](https://forum.obsidian.md/t/pdf-export-with-community-plugin-table-extended-not-working/44158), [Obsidian plugins page](https://obsidian.md/plugins)

### Typora

**Export mechanism:** Chromium print-to-PDF or Pandoc.

| Behavior | Details |
|---|---|
| Text wrapping | Depends on CSS theme. Default themes wrap text in cells. |
| Font scaling | No. |
| Overflow/clipping | Wide tables overflow the page. Code blocks have the same problem. |
| Auto landscape | No. Users can add `@page { size: landscape; }` in custom CSS, but this applies to the entire document. |
| Page splitting | Supported via CSS `page-break-before/after`. Community workaround: `<div class="page-break"></div>` elements in markdown. Tables themselves split across pages with no special handling. |

**Sources:** [typora/typora-issues#118](https://github.com/typora/typora-issues/issues/118), [r/pandoc thread](https://www.reddit.com/r/pandoc/comments/llherl/)

---

## 6. GitHub

**Rendering mechanism:** Server-side markdown to HTML, rendered in browser.
No PDF export feature.

| Behavior | Details |
|---|---|
| Text wrapping | Yes, within cells. GitHub's CSS sets `word-wrap: break-word` on table cells. |
| Font scaling | No. |
| Overflow/scroll | Wide tables get a **horizontal scrollbar**. GitHub wraps tables in a `<div>` with `overflow-x: auto`. The table renders at its natural width and the container scrolls. Content is never clipped or hidden. |
| Auto landscape | N/A (web rendering, no page concept). |
| Page splitting | N/A. |
| Mobile vs desktop | **Same behavior.** Both use horizontal scroll within the content container. On mobile, the scroll container works via touch swipe. Column widths are identical; no mobile-specific reflow or column hiding. |

**Key insight:** GitHub's horizontal scroll approach is the cleanest solution
for wide tables in a web context. It preserves all content without distortion.
However, this has no PDF equivalent -- if a user prints a GitHub page, the
browser's print engine handles it (typically clipping the overflowed content).

**Sources:** [isaacs/github#694](https://github.com/isaacs/github/issues/694), [open-webui#16595](https://github.com/open-webui/open-webui/discussions/16595)

---

## Comparison Matrix

| App | Text Wrap | Font Scale | Overflow Behavior | Auto Landscape | Vertical Split | Best Strategy |
|---|---|---|---|---|---|---|
| Google Docs | Yes (default) | No | Clip | No | Yes (buggy) | Constrain in editor |
| Microsoft Word | Yes (AutoFit Window) | No | Clip (other modes) | No | Yes (configurable) | AutoFit Window mode |
| Apple Pages | Yes (default) | No | Clip | No | Yes (whole rows only) | Manual resize |
| Notion | Partial | No | Clip | No | Random | Export HTML, convert externally |
| Bear | Minimal | No | Clip | No | Cuts mid-row | Export to .docx first |
| Obsidian | Theme-dependent | No | Clip | No (plugin can) | Yes | Custom CSS or Better Export PDF plugin |
| Typora | Theme-dependent | No | Clip | No (CSS hack) | CSS-controlled | Custom CSS |
| GitHub (web) | Yes | No | **Horizontal scroll** | N/A | N/A | No action needed |

---

## Key Takeaways

1. **No app auto-scales font size for wide tables.** This is universally a
   manual operation or requires external tooling (e.g., LaTeX's `scale_down`,
   flextable's `fit_to_width()`).

2. **No app automatically switches to landscape.** Every app requires the user
   to manually change orientation. Word is the only app that supports per-section
   orientation, making it possible to have a single landscape page for a wide
   table within a portrait document.

3. **Text wrapping is the universal first line of defense.** Google Docs, Word,
   and Pages all wrap text within cells to constrain table width. This works for
   moderately wide tables but breaks down when there are many narrow-data columns
   (e.g., numeric data across 15+ columns where wrapping makes no sense).

4. **Horizontal scroll is the web solution; PDF has no equivalent.** GitHub's
   `overflow-x: auto` is the cleanest handling for web rendering. For PDF, the
   only options are: wrap text (make rows taller), scale the whole table down
   (make text smaller), switch to landscape (more horizontal space), or split the
   table across pages horizontally (rarely supported by any tool).

5. **Markdown editors are the worst at this.** Bear, Obsidian, and Typora all
   use browser print-to-PDF, which simply clips overflowing content. Custom CSS
   is the only mitigation, and it's fragile.

6. **The "right" answer for an export feature depends on the content type:**
   - Prose-heavy tables (long text cells): text wrapping works well
   - Data-dense tables (many numeric columns): needs font scaling or landscape
   - Mixed content: no single strategy works; user control is needed

---

## Implications for Our Implementation

When building table-to-image or table-to-PDF export in a chat/document context:

1. **Wrap text by default** -- this handles the majority of cases where tables
   have a reasonable number of columns.

2. **Detect overflow and scale down** -- if the table's natural width exceeds the
   target width after wrapping, uniformly scale the font size down. No existing
   app does this automatically, which makes it a differentiator.

3. **Offer landscape as an option** -- don't auto-switch (no app does), but make
   it easy to toggle.

4. **For image export specifically:** the image can simply be as wide as the
   table needs to be (no fixed page width constraint). This sidesteps the entire
   problem. GitHub's approach of "let it be as wide as it wants" works when the
   output medium is scrollable.

5. **For PDF export:** consider a two-pass approach: render at normal size, check
   if it overflows, then re-render scaled down if needed. This is what LaTeX's
   `adjustbox` package does with `max width=\textwidth`.
