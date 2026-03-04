import { readdirSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join, relative, resolve, sep } from "node:path";

export interface FileSuggestion {
  path: string;
  isDirectory: boolean;
}

export interface FileSuggestionResult {
  items: FileSuggestion[];
  truncated: boolean;
}

const IGNORE_DIRS = new Set([
  ".git",
  "node_modules",
  ".next",
  "dist",
  "build",
  "__pycache__",
  ".cache",
  ".tsbuildinfo",
  ".DS_Store",
  "DerivedData",
  ".build",
  "Pods",
  ".svn",
  ".hg",
]);

const SCAN_BUDGET = 10_000;
const RESULT_CAP = 12;
const QUERY_MAX_LENGTH = 120;
const MAX_RECURSION_DEPTH = 8;

interface Candidate {
  relPath: string;
  isDirectory: boolean;
}

export function getFileSuggestions(
  workspaceRoot: string,
  rawQuery: string,
  additionalRoots: string[] = [],
): FileSuggestionResult {
  const raw = rawQuery.trim();
  if (isAbsoluteQuery(raw)) {
    return getAbsoluteFileSuggestions(workspaceRoot, raw, additionalRoots);
  }

  const query = sanitizeQuery(rawQuery);
  const { dirPrefix, fragment } = splitQuery(query);

  const scanDir = dirPrefix ? resolve(workspaceRoot, dirPrefix) : workspaceRoot;
  if (!isWithinWorkspace(scanDir, workspaceRoot)) {
    return { items: [], truncated: false };
  }

  const { candidates, truncated: budgetExceeded } = collectCandidates(
    workspaceRoot,
    scanDir,
    dirPrefix.length > 0,
  );

  const fragmentLower = fragment.toLowerCase();
  const ranked = candidates
    .filter((candidate) => matchesFragment(candidate, fragmentLower))
    .sort((a, b) => compareCandidates(a, b, fragmentLower));

  return {
    items: ranked.slice(0, RESULT_CAP).map(({ relPath, isDirectory }) => ({
      path: relPath,
      isDirectory,
    })),
    truncated: budgetExceeded || ranked.length > RESULT_CAP,
  };
}

export function isWithinWorkspace(targetPath: string, workspaceRoot: string): boolean {
  try {
    const resolvedTarget = resolve(targetPath);
    const resolvedRoot = resolve(workspaceRoot);

    const realRoot = realpathSync(resolvedRoot);
    let realTarget: string;
    try {
      realTarget = realpathSync(resolvedTarget);
    } catch {
      return resolvedTarget === resolvedRoot || resolvedTarget.startsWith(resolvedRoot + sep);
    }

    return realTarget === realRoot || realTarget.startsWith(realRoot + sep);
  } catch {
    return false;
  }
}

function getAbsoluteFileSuggestions(
  workspaceRoot: string,
  rawAbsoluteQuery: string,
  additionalRoots: string[],
): FileSuggestionResult {
  const roots = resolveAllowedRoots(workspaceRoot, additionalRoots);
  if (roots.length === 0) {
    return { items: [], truncated: false };
  }

  const query = normalizeAbsoluteQuery(rawAbsoluteQuery);
  const { dirPrefix, fragment } = splitAbsoluteQuery(query);
  const scanDir = dirPrefix || "/";

  if (!isWithinAnyRoot(scanDir, roots)) {
    const rootItems = roots
      .filter((root) => root.startsWith(query))
      .slice(0, RESULT_CAP)
      .map((root) => ({ path: withTrailingSlash(root), isDirectory: true }));
    return { items: rootItems, truncated: false };
  }

  const candidates: Candidate[] = [];
  let names: string[];
  try {
    names = readdirSync(scanDir);
  } catch {
    return { items: [], truncated: false };
  }

  for (const name of names) {
    const fullPath = join(scanDir, name);

    let isDirectory = false;
    try {
      isDirectory = statSync(fullPath, { throwIfNoEntry: false })?.isDirectory() ?? false;
    } catch {
      continue;
    }

    if (isDirectory && IGNORE_DIRS.has(name)) {
      continue;
    }
    if (!isWithinAnyRoot(fullPath, roots)) {
      continue;
    }

    candidates.push({
      relPath: isDirectory ? withTrailingSlash(fullPath) : fullPath,
      isDirectory,
    });
  }

  const fragmentLower = fragment.toLowerCase();
  const ranked = candidates
    .filter((candidate) => matchesFragment(candidate, fragmentLower))
    .sort((a, b) => compareCandidates(a, b, fragmentLower));

  return {
    items: ranked.slice(0, RESULT_CAP).map((candidate) => ({
      path: candidate.relPath,
      isDirectory: candidate.isDirectory,
    })),
    truncated: ranked.length > RESULT_CAP,
  };
}

function splitQuery(query: string): { dirPrefix: string; fragment: string } {
  const lastSlash = query.lastIndexOf("/");
  if (lastSlash < 0) {
    return { dirPrefix: "", fragment: query };
  }

  return {
    dirPrefix: query.slice(0, lastSlash),
    fragment: query.slice(lastSlash + 1),
  };
}

function splitAbsoluteQuery(query: string): { dirPrefix: string; fragment: string } {
  const lastSlash = query.lastIndexOf("/");
  if (lastSlash < 0) {
    return { dirPrefix: "", fragment: query };
  }

  return {
    dirPrefix: query.slice(0, lastSlash === 0 ? 1 : lastSlash),
    fragment: query.slice(lastSlash + 1),
  };
}

function collectCandidates(
  workspaceRoot: string,
  scanDir: string,
  flatListing: boolean,
): { candidates: Candidate[]; truncated: boolean } {
  const candidates: Candidate[] = [];
  let scanned = 0;
  let truncated = false;

  const walk = (dir: string, depth: number): void => {
    if (scanned >= SCAN_BUDGET) {
      truncated = true;
      return;
    }

    let names: string[];
    try {
      names = readdirSync(dir);
    } catch {
      return;
    }

    for (const name of names) {
      if (scanned >= SCAN_BUDGET) {
        truncated = true;
        return;
      }

      scanned += 1;
      const fullPath = join(dir, name);

      let isDirectory = false;
      try {
        isDirectory = statSync(fullPath, { throwIfNoEntry: false })?.isDirectory() ?? false;
      } catch {
        continue;
      }

      if (isDirectory && IGNORE_DIRS.has(name)) {
        continue;
      }

      if (!flatListing || dir === scanDir) {
        const relPath = relative(workspaceRoot, fullPath);
        candidates.push({
          relPath: isDirectory ? `${relPath}/` : relPath,
          isDirectory,
        });
      }

      if (flatListing || !isDirectory || depth >= MAX_RECURSION_DEPTH) {
        continue;
      }
      if (!isWithinWorkspace(fullPath, workspaceRoot)) {
        continue;
      }

      walk(fullPath, depth + 1);
    }
  };

  walk(scanDir, 0);
  return { candidates, truncated };
}

function matchesFragment(candidate: Candidate, fragmentLower: string): boolean {
  if (!fragmentLower) {
    return true;
  }

  return basename(candidate.relPath).toLowerCase().includes(fragmentLower);
}

function compareCandidates(a: Candidate, b: Candidate, fragmentLower: string): number {
  const scoreA = matchScore(a.relPath, fragmentLower);
  const scoreB = matchScore(b.relPath, fragmentLower);
  if (scoreA !== scoreB) {
    return scoreB - scoreA;
  }

  if (a.isDirectory !== b.isDirectory) {
    return a.isDirectory ? -1 : 1;
  }

  return a.relPath.localeCompare(b.relPath);
}

function sanitizeQuery(raw: string): string {
  let query = raw.trim();
  if (query.length > QUERY_MAX_LENGTH) {
    query = query.slice(0, QUERY_MAX_LENGTH);
  }

  query = query.replace(/^\/+/, "");
  query = query.replace(/\/+/g, "/");

  return query
    .split("/")
    .filter((segment) => segment !== ".." && segment !== ".")
    .join("/");
}

function normalizeAbsoluteQuery(raw: string): string {
  let query = raw.trim();
  if (query.length > QUERY_MAX_LENGTH) {
    query = query.slice(0, QUERY_MAX_LENGTH);
  }

  query = expandHome(query);
  const hasTrailingSlash = query.endsWith("/");
  const normalized = resolve(query.replace(/\/+/g, "/"));
  return hasTrailingSlash ? withTrailingSlash(normalized) : normalized;
}

function resolveAllowedRoots(workspaceRoot: string, additionalRoots: string[]): string[] {
  const uniqueRoots = new Set<string>();
  const rootCandidates = [workspaceRoot, ...additionalRoots];

  for (const candidate of rootCandidates) {
    const expanded = expandHome(candidate.trim());
    if (!expanded) {
      continue;
    }

    let normalized: string;
    try {
      normalized = realpathSync(resolve(expanded));
    } catch {
      normalized = resolve(expanded);
    }

    uniqueRoots.add(normalized);
  }

  return Array.from(uniqueRoots);
}

function isWithinAnyRoot(path: string, roots: string[]): boolean {
  for (const root of roots) {
    if (isWithinWorkspace(path, root)) {
      return true;
    }
  }

  return false;
}

function isAbsoluteQuery(raw: string): boolean {
  return raw.startsWith("/") || raw.startsWith("~");
}

function expandHome(path: string): string {
  if (path === "~" || path.startsWith("~/")) {
    return path.replace(/^~(?=\/|$)/, homedir());
  }

  return path;
}

function withTrailingSlash(path: string): string {
  return path.endsWith("/") ? path : `${path}/`;
}

function basename(relPath: string): string {
  const cleanPath = relPath.endsWith("/") ? relPath.slice(0, -1) : relPath;
  const lastSlash = cleanPath.lastIndexOf("/");
  return lastSlash >= 0 ? cleanPath.slice(lastSlash + 1) : cleanPath;
}

function matchScore(relPath: string, fragmentLower: string): number {
  if (!fragmentLower) {
    return 1;
  }

  const name = basename(relPath).toLowerCase();
  if (name.startsWith(fragmentLower)) {
    return 3;
  }
  if (name.includes(fragmentLower)) {
    return 2;
  }

  for (const part of relPath.toLowerCase().split("/")) {
    if (part.includes(fragmentLower)) {
      return 1;
    }
  }

  return 0;
}

export const _testing = {
  sanitizeQuery,
  normalizeAbsoluteQuery,
  matchScore,
  basename,
  IGNORE_DIRS,
  SCAN_BUDGET,
  RESULT_CAP,
  QUERY_MAX_LENGTH,
};
