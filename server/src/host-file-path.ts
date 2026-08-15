import { homedir } from "node:os";
import { isAbsolute } from "node:path";
import { fileURLToPath } from "node:url";

export interface ExpandExactHostPathOptions {
  homeDir?: string;
}

/**
 * Expand an owner-requested host path without consulting process.cwd().
 *
 * Accepts absolute POSIX paths, bare `~` / `~/...`, and local `file://` URLs.
 * Rejects `~user`, relative leftovers, query strings, and resolution throws.
 */
export function expandExactHostPath(
  rawPath: string,
  options: ExpandExactHostPathOptions = {},
): string | null {
  if (typeof rawPath !== "string") return null;

  const trimmed = rawPath.trim();
  if (!trimmed || trimmed.includes("\0") || trimmed.includes("?")) {
    return null;
  }

  try {
    if (trimmed.toLowerCase().startsWith("file:")) {
      return expandLocalFileURL(trimmed);
    }

    if (trimmed === "~") {
      return homeDirectory(options.homeDir);
    }

    if (trimmed.startsWith("~/")) {
      const home = homeDirectory(options.homeDir);
      const rest = trimmed.slice(2);
      if (!rest || rest.includes("\0")) return null;
      return `${stripTrailingSlashes(home)}/${rest}`;
    }

    if (trimmed.startsWith("~")) {
      return null;
    }

    return isAbsolute(trimmed) ? trimmed : null;
  } catch {
    return null;
  }
}

function expandLocalFileURL(raw: string): string | null {
  // Reject hosts before URL normalization. `file://localhost/tmp` becomes
  // `file:///tmp` on Darwin, which would otherwise look local.
  if (!/^file:\/\//i.test(raw) || /^file:\/\/[^/]/i.test(raw)) {
    return null;
  }

  const url = new URL(raw);
  if (url.protocol !== "file:") return null;
  if (url.search || url.hash) return null;
  if (url.host) return null;
  if (url.pathname === "/" && !/^file:\/\/.+\//i.test(raw)) return null;

  const path = fileURLToPath(url);
  return isAbsolute(path) && path !== "/" ? path : null;
}

function homeDirectory(override: string | undefined): string {
  const home = override ?? homedir();
  if (!home || !isAbsolute(home)) {
    throw new Error("host home is not an absolute path");
  }
  return home;
}

function stripTrailingSlashes(path: string): string {
  return path.replace(/\/+$/, "") || "/";
}

/**
 * Percent-encode a canonical host path for `X-Oppi-Resolved-Path`.
 * Node `writeHead` rejects non-ASCII and CR/LF. Slashes stay literal so
 * ASCII paths are unchanged and HostRawFileHeaders can decode the same form.
 */
export function encodeHostResolvedPathHeader(path: string): string {
  return encodeURIComponent(path).replace(/%2F/gi, "/");
}

/** Inverse of `encodeHostResolvedPathHeader`. */
export function decodeHostResolvedPathHeader(raw: string): string | null {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  if (!trimmed) return null;
  try {
    const decoded = decodeURIComponent(trimmed);
    return decoded.startsWith("/") ? decoded : null;
  } catch {
    return null;
  }
}
