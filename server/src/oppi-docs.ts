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
  "- Existing workspace files can be opened from workspace-relative wiki links such as [[path/to/file.ext|Label]]. Uppercase, one-based anchors focus exact source lines: [[path/to/file.ext#L12-L18|Label]].",
  "- Workspace images and SVG can appear inline with standard Markdown image syntax: ![Description](path/to/image.svg).",
  "- Fenced Mermaid blocks render as diagrams:",
  "```mermaid",
  "flowchart TD",
  "  A[Start] --> B[Done]",
  "```",
  "- LaTeX math renders inline with $x^2$ or \\(x^2\\), and as display math with $$x^2 + y^2 = z^2$$, \\[x^2 + y^2 = z^2\\], or a fenced latex block.",
  "- Wiki links to recognized workspace documents and media open in their corresponding viewers, including images, audio, video, PDF, HTML, Org, LaTeX, Mermaid, and Graphviz files.",
  "- Assistant messages can include oppi://session/<session-id> deep links; tapping one opens that session in-app.",
  "- File targets must be real workspace-relative paths. Absolute, outside-workspace, secret, credential, and private runtime paths are not supported.",
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
