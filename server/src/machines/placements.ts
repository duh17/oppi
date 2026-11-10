import { existsSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { isRecord } from "../json-shape.js";
import { writeFileAtomic } from "../storage/atomic-file.js";

/**
 * A worktree that lives on a machine: where `subagent spawn host` put a child, keyed by its
 * worktree id (which the child's Session row carries, so one lookup tells every session-cwd
 * reader that the files are not on this host). Written by the server; `oppi machines` reads it.
 */
export interface Placement {
  worktreeId: string;
  machine: string;
  workspaceId: string;
  /** The workspace's git repository on this host: where the branch is fetched to. */
  repo: string;
  /** The branch in the target's mirror, and in the workspace repository once fetched. */
  branch: string;
  /** The studio commit the branch started from; commits ahead count from it. */
  base: string;
  /** Worktree path on the machine. */
  root: string;
  /** The child's run is not over: the machine still has a worker. */
  active: boolean;
  /** The studio repository holds the branch as it is on the machine. */
  fetched: boolean;
}

export const PLACEMENTS_FILE = "machine-placements.json";

function parsePlacements(text: string): Placement[] {
  const raw: unknown = JSON.parse(text);
  if (!isRecord(raw) || !Array.isArray(raw.placements))
    throw new Error("placements file is malformed");
  return raw.placements.map((entry): Placement => {
    if (
      !isRecord(entry) ||
      typeof entry.worktreeId !== "string" ||
      typeof entry.machine !== "string" ||
      typeof entry.workspaceId !== "string" ||
      typeof entry.repo !== "string" ||
      typeof entry.branch !== "string" ||
      typeof entry.base !== "string" ||
      typeof entry.root !== "string" ||
      typeof entry.active !== "boolean" ||
      typeof entry.fetched !== "boolean"
    )
      throw new Error("a placement is malformed");
    const { worktreeId, machine, workspaceId, repo, branch, base, root, active, fetched } = entry;
    return { worktreeId, machine, workspaceId, repo, branch, base, root, active, fetched };
  });
}

/** What a studio route answers (409) for a session whose files are on a machine. */
export function remoteFilesMessage(machine: string): string {
  return `This session's files are on ${machine}.`;
}

/** The 409 text when `worktreeId` is a worktree on a machine, else undefined. */
export function remoteWorktreeRefusal(
  dataDir: string,
  worktreeId: string | undefined,
): string | undefined {
  const placement = worktreeId ? placementsFor(dataDir).get(worktreeId.trim()) : undefined;
  return placement ? remoteFilesMessage(placement.machine) : undefined;
}

const shared = new Map<string, Placements>();

/** One reader per data directory, so every session-cwd reader shares the mtime cache. */
export function placementsFor(dataDir: string): Placements {
  let placements = shared.get(dataDir);
  if (!placements) shared.set(dataDir, (placements = new Placements(dataDir)));
  return placements;
}

/** The server's and the CLI's shared view of remote worktrees. Reads are cached by mtime. */
export class Placements {
  private readonly file: string;
  private cache: { mtimeMs: number; size: number; placements: Placement[] } | undefined;

  constructor(dataDir: string) {
    this.file = join(dataDir, PLACEMENTS_FILE);
  }

  list(): Placement[] {
    if (!existsSync(this.file)) return [];
    const stat = statSync(this.file);
    if (this.cache?.mtimeMs === stat.mtimeMs && this.cache.size === stat.size)
      return this.cache.placements;
    const placements = parsePlacements(readFileSync(this.file, "utf8"));
    this.cache = { mtimeMs: stat.mtimeMs, size: stat.size, placements };
    return placements;
  }

  get(worktreeId: string): Placement | undefined {
    return this.list().find((placement) => placement.worktreeId === worktreeId);
  }

  /** Add or change a placement. The server is the one writer, in one process. */
  put(placement: Placement): void {
    const others = this.list().filter((other) => other.worktreeId !== placement.worktreeId);
    writeFileAtomic(
      this.file,
      `${JSON.stringify({ placements: [...others, placement] }, null, 2)}\n`,
      {
        durable: true,
      },
    );
  }

  update(worktreeId: string, change: Partial<Pick<Placement, "active" | "fetched">>): void {
    const found = this.get(worktreeId);
    if (found) this.put({ ...found, ...change });
  }

  /** A restart ended every remote command, so no machine has an active worker any more. */
  clearActive(): void {
    for (const placement of this.list())
      if (placement.active) this.put({ ...placement, active: false });
  }
}
