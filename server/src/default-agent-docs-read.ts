import { readFile, realpath, stat } from "node:fs/promises";
import { isAbsolute, relative, resolve, sep } from "node:path";

import { getOppiDocsPath } from "./oppi-docs.js";

const DEFAULT_MAX_BYTES = 50 * 1024;
const DEFAULT_MAX_LINES = 2000;
const TRUNCATION_MARKER = "\n\n[Truncated packaged doc read]";

export type DocsReadResult = {
  path: string;
  text: string;
  truncated: boolean;
};

/** Resolve a requested path to a real file under the packaged Oppi docs root. */
export async function resolveDocsReadPath(
  requestedPath: string,
  docsRoot = getOppiDocsPath(),
): Promise<string> {
  if (!docsRoot) {
    throw new Error("Packaged Oppi docs are unavailable");
  }
  const trimmed = requestedPath.trim();
  if (!trimmed) {
    throw new Error("path is required");
  }
  if (trimmed.includes("\0")) {
    throw new Error("path must not contain NUL characters");
  }

  const rootReal = await realpath(resolve(docsRoot));
  const candidate = isAbsolute(trimmed) ? resolve(trimmed) : resolve(rootReal, trimmed);
  let fileReal: string;
  try {
    fileReal = await realpath(candidate);
  } catch {
    throw new Error("File not found in packaged Oppi docs");
  }

  const relativePath = relative(rootReal, fileReal);
  if (
    relativePath === "" ||
    relativePath.startsWith(`..${sep}`) ||
    relativePath === ".." ||
    isAbsolute(relativePath)
  ) {
    throw new Error("read is limited to packaged Oppi docs");
  }

  const info = await stat(fileReal);
  if (!info.isFile()) {
    throw new Error("path must be a file under packaged Oppi docs");
  }
  return fileReal;
}

export async function readPackagedOppiDoc(
  requestedPath: string,
  options: Readonly<{ offset?: number; limit?: number; docsRoot?: string }> = {},
): Promise<DocsReadResult> {
  if (options.offset !== undefined) {
    assertPositiveInteger(options.offset, "offset");
  }
  if (options.limit !== undefined) {
    assertPositiveInteger(options.limit, "limit");
  }

  const filePath = await resolveDocsReadPath(requestedPath, options.docsRoot);
  const raw = await readFile(filePath, "utf8");
  const lines = raw.split("\n");
  const start = options.offset !== undefined ? options.offset - 1 : 0;
  if (start >= lines.length) {
    throw new Error(`Offset ${options.offset} is beyond end of file (${lines.length} lines total)`);
  }
  const selected =
    options.limit !== undefined ? lines.slice(start, start + options.limit) : lines.slice(start);

  let text = selected.join("\n");
  let truncated = false;
  const lineCount = text === "" ? 0 : text.split("\n").length;
  if (lineCount > DEFAULT_MAX_LINES) {
    text = text.split("\n").slice(0, DEFAULT_MAX_LINES).join("\n");
    truncated = true;
  }
  // Reserve room for the truncation marker so the final result stays within cap.
  const maxBytes =
    DEFAULT_MAX_BYTES - (truncated ? Buffer.byteLength(TRUNCATION_MARKER, "utf8") : 0);
  if (Buffer.byteLength(text, "utf8") > maxBytes) {
    let end = text.length;
    while (end > 0 && Buffer.byteLength(text.slice(0, end), "utf8") > maxBytes) {
      end = Math.floor(end * 0.9);
    }
    text = text.slice(0, end);
    truncated = true;
  }
  if (truncated) {
    text += TRUNCATION_MARKER;
  }
  return { path: filePath, text, truncated };
}

function assertPositiveInteger(value: number, name: string): void {
  if (!Number.isSafeInteger(value) || value < 1) {
    throw new Error(`${name} must be a positive integer`);
  }
}
