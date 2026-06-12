import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REQUIRED_OPPI_DOCS = ["extensions.md", "extension-native-ui.md"] as const;
const OPPI_DOCS_HINT_PREFIX = "Oppi documentation for mobile-compatible Pi extensions:";

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

  return `${OPPI_DOCS_HINT_PREFIX} ${docsPath} (start with extensions.md and extension-native-ui.md).`;
}

export function appendOppiSystemPromptHint(prompt: string): string {
  if (prompt.includes(OPPI_DOCS_HINT_PREFIX)) {
    return prompt;
  }

  const hint = buildOppiSystemPromptAppend();
  return hint ? `${prompt}\n\n${hint}` : prompt;
}
