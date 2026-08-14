import { accessSync, constants } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const UNICODE_SPACES = /[\u00A0\u2000-\u200A\u202F\u205F\u3000]/g;
const NARROW_NO_BREAK_SPACE = "\u202F";

/**
 * Pi 0.84.1 read-path contract, extracted from its non-exported
 * dist/core/tools/path-utils.js + dist/utils/paths.js implementation.
 * The parity tests are the version guard: update them with Pi before changing
 * this copy. Keep live capture and historical attribution on this one implementation.
 */
export function matchPiReadPath<T>(
  entries: ReadonlyMap<string, T>,
  candidate: string,
): T | undefined {
  const exact = entries.get(candidate);
  if (exact) return exact;
  const normalizedCandidate = candidate.normalize("NFC");
  for (const [path, value] of entries) {
    if (path.normalize("NFC") === normalizedCandidate) return value;
  }
  return undefined;
}

export function resolvePiReadPath(filePath: string, cwd: string): string {
  const resolved = resolveToCwd(filePath, cwd);
  if (fileExists(resolved)) return resolved;

  const amPmVariant = resolved.replace(/ (AM|PM)\./gi, `${NARROW_NO_BREAK_SPACE}$1.`);
  if (amPmVariant !== resolved && fileExists(amPmVariant)) return amPmVariant;

  const nfdVariant = resolved.normalize("NFD");
  if (nfdVariant !== resolved && fileExists(nfdVariant)) return nfdVariant;

  const curlyVariant = resolved.replace(/'/g, "\u2019");
  if (curlyVariant !== resolved && fileExists(curlyVariant)) return curlyVariant;

  const nfdCurlyVariant = nfdVariant.replace(/'/g, "\u2019");
  if (nfdCurlyVariant !== resolved && fileExists(nfdCurlyVariant)) return nfdCurlyVariant;

  return resolved;
}

function resolveToCwd(filePath: string, cwd: string): string {
  const normalized = normalizePath(filePath, {
    normalizeUnicodeSpaces: true,
    stripAtPrefix: true,
  });
  // Pi deliberately applies only ordinary path normalization to the base cwd.
  const normalizedCwd = normalizePath(cwd);
  return isAbsolute(normalized) ? resolve(normalized) : resolve(normalizedCwd, normalized);
}

function normalizePath(
  input: string,
  options: { normalizeUnicodeSpaces?: boolean; stripAtPrefix?: boolean } = {},
): string {
  let normalized = options.normalizeUnicodeSpaces ? input.replace(UNICODE_SPACES, " ") : input;
  if (options.stripAtPrefix && normalized.startsWith("@")) normalized = normalized.slice(1);
  if (process.platform === "win32") normalized = normalizeWindowsShellPath(normalized);
  if (normalized === "~") return homedir();
  if (
    normalized.startsWith("~/") ||
    (process.platform === "win32" && normalized.startsWith("~\\"))
  ) {
    return join(homedir(), normalized.slice(2));
  }
  if (/^file:\/\//.test(normalized)) return fileURLToPath(normalized);
  return normalized;
}

/** Pi 0.84.1 Git Bash/MSYS/Cygwin/WSL drive-path conversion. */
export function normalizeWindowsShellPath(filePath: string): string {
  if (!filePath.startsWith("/") || filePath.startsWith("//") || filePath.includes("\\")) {
    return filePath;
  }
  const match = filePath.match(/^\/(?:mnt\/|cygdrive\/)?([a-z])(?:\/(.*))?$/i);
  if (!match) return filePath;
  const suffix = match[2]?.replaceAll("/", "\\");
  const drive = match[1];
  return drive ? `${drive.toUpperCase()}:\\${suffix ?? ""}` : filePath;
}

function fileExists(path: string): boolean {
  try {
    accessSync(path, constants.F_OK);
    return true;
  } catch {
    return false;
  }
}
