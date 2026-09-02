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
  "You are running in Oppi.",
  "",
  "Oppi rendering capabilities:",
  "- Wiki links open real workspace or owner-host files: [[path/to/file.ext|Label]], [[path/to/file.ext#L12-L18|Label]], [[/abs/path|Label]], [[~/path|Label]]. Recognized documents and media (images, audio, video, PDF, HTML, Org, LaTeX, Mermaid, Graphviz) open in viewers.",
  "- Session links open a session: [Label](oppi://session/<session-id>) or oppi://session/<session-id>.",
  "- Images and SVG appear inline with ![Description](path/to/image.svg). Existing Oppi-backed videos play inline with ![[path/to/video.mp4]]; [[path/to/video.mp4]] stays a file link. Existing Oppi-backed audio plays inline with ![[path/to/clip.m4a]]; [[path/to/clip.m4a]] stays a file link. Remote URLs, HTML <video>, HTML <audio>, and attachment IDs are not embeds.",
  "- Fenced mermaid blocks render flowchart (also graph), sequence, class, state, ER, gantt, pie, timeline, mindmap, xyChart, journey, quadrantChart, gitGraph, sankey, and kanban. Other Mermaid types show an unsupported placeholder.",
  "- LaTeX renders inline, display, and fenced latex blocks.",
  "- File targets must be real relative, absolute, or ~ paths. Do not cite secrets, credentials, private runtime state, or dump credential files. Sandbox sessions should keep using sandbox-visible paths.",
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
