import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REQUIRED_OPPI_DOCS = [
  "extensions.md",
  "extension-native-ui.md",
  "attachment-rendering.md",
  "server-configuration.md",
] as const;
const OPPI_DOCS_HINT_PREFIX =
  "Oppi documentation (read only when asked about Oppi mobile/runtime behavior):";
const OLD_OPPI_DOCS_HINT_PREFIX = "Oppi documentation for mobile-compatible Pi extensions:";

export const MOBILE_OUTPUT_GUIDE = [
  "You are running in Oppi: your Markdown renders in a native iPhone/iPad app.",
  "",
  "- Link files the user may want to open, such as files you created, changed, or cite: [[path|label]] or [[path#L12-L18|label]]. Backticked paths, `file.ts:12`, and [[file#Heading]] stay plain text. Extensionless wiki targets gain .md, so link those with [label](path).",
  "- Embed images, audio, video, or USDZ you made or found: ![[path]] or ![alt](path). [[path]] only links. Only local files embed; remote https images load on tap.",
  "- Relative paths resolve from this session's workspace checkout root (its worktree, if any), not the shell's cwd. Use ~/ or absolute paths for other files on this machine, including other repos; in a sandbox, use sandbox-visible paths. Link only files that exist.",
  "- Session link: [label](oppi://session/<full-session-id>).",
  "- ```mermaid renders only flowchart/graph, sequence, class, state, ER, gantt, pie, timeline, mindmap, xychart, journey, quadrantChart, gitGraph, sankey, and kanban.",
  "- ```geojson or ```topojson renders an interactive map.",
  "- Inline and display math render. Use aligned, cases, or matrices; align, \\color, \\textcolor, and \\dfrac show as source.",
  "- No footnotes, callouts, or raw HTML; they show as text.",
  "- Linked CSV, HTML, Org, .mmd, GeoJSON, and PDF files open in rendered viewers.",
  "- Never link, embed, or quote secrets, credentials, or private runtime state.",
].join("\n");

export function buildMobileOutputGuide(): string {
  return MOBILE_OUTPUT_GUIDE;
}

function moduleDir(): string {
  return dirname(fileURLToPath(import.meta.url));
}

function isOppiDocsDir(path: string): boolean {
  return REQUIRED_OPPI_DOCS.every((doc) => existsSync(join(path, doc)));
}

export function getOppiDocsPath(): string | undefined {
  const dir = moduleDir();
  const candidates = [
    // Packaged/bundled server build: server/dist/src/oppi-docs.js -> server/dist/docs/oppi
    resolve(dir, "../docs/oppi"),
    // Source development: server/src/oppi-docs.ts -> docs
    resolve(dir, "../../docs"),
    // Built source checkout without copied docs: server/dist/src/oppi-docs.js -> docs
    resolve(dir, "../../../docs"),
  ];

  return candidates.find(isOppiDocsDir);
}

export function buildOppiSystemPromptAppend(docsPath = getOppiDocsPath()): string | undefined {
  if (!docsPath) {
    return undefined;
  }

  return [
    OPPI_DOCS_HINT_PREFIX,
    `- Docs directory: ${docsPath}`,
    `- Server configuration (ASR, TTS, config CLI): ${join(docsPath, "server-configuration.md")}`,
    `- Extensions: ${join(docsPath, "extensions.md")}`,
    `- Native extension UI: ${join(docsPath, "extension-native-ui.md")}`,
    `- Attachment rendering: ${join(docsPath, "attachment-rendering.md")}`,
    "- When working on Oppi topics, read the relevant docs completely and follow .md cross-references before implementing.",
  ].join("\n");
}

export function appendOppiSystemPromptHint(prompt: string): string {
  if (prompt.includes(OPPI_DOCS_HINT_PREFIX) || prompt.includes(OLD_OPPI_DOCS_HINT_PREFIX)) {
    return prompt;
  }

  const hint = buildOppiSystemPromptAppend();
  return hint ? `${prompt}\n\n${hint}` : prompt;
}
