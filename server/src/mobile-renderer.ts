/**
 * Mobile tool renderer registry.
 *
 * Pre-renders styled summary segments for iOS tool call display.
 * Parallels pi's TUI `renderCall`/`renderResult` pattern but produces
 * serializable StyledSegment[] instead of TUI Component objects.
 *
 * Sources (load order, later overrides earlier):
 * 1. Built-in renderers (bash, read, edit, write, grep, find, ls)
 * 2. Extension sidecars (~/.pi/agent/extensions/*.mobile.ts)
 */

import { existsSync, readdirSync, statSync } from "node:fs";
import { join, extname, basename } from "node:path";
import { HOST_EXTENSIONS_DIR } from "./extension-loader.js";

// ─── Types ───

export interface StyledSegment {
  text: string;
  style?: "bold" | "muted" | "dim" | "accent" | "success" | "warning" | "error";
}

export interface MobileToolRenderer {
  renderCall(args: Record<string, unknown>): StyledSegment[];
  renderResult(details: unknown, isError: boolean): StyledSegment[];
}

// ─── Helpers ───

function str(v: unknown): string {
  return typeof v === "string" ? v : "";
}

function num(v: unknown): number | undefined {
  return typeof v === "number" ? v : undefined;
}

/** Shorten long paths for display: /Users/chenda/workspace/foo → ~/workspace/foo */
function shortenPath(p: string): string {
  const home = process.env.HOME || process.env.USERPROFILE || "";
  if (home && p.startsWith(home)) {
    return "~" + p.slice(home.length);
  }
  return p;
}

/** First line, truncated. */
function firstLine(s: string, max = 80): string {
  const line = s.split("\n")[0] || "";
  return line.length > max ? line.slice(0, max - 1) + "…" : line;
}

// ─── Built-in Renderers ───

const bash: MobileToolRenderer = {
  renderCall(args) {
    const cmd = firstLine(str(args.command));
    return [{ text: "$ ", style: "bold" }, { text: cmd, style: "accent" }];
  },
  renderResult(details: any, isError) {
    const code = details?.exitCode;
    if (isError || (typeof code === "number" && code !== 0)) {
      return [{ text: `exit ${code ?? "?"}`, style: "error" }];
    }
    return [];
  },
};

const read: MobileToolRenderer = {
  renderCall(args) {
    const path = shortenPath(str(args.path || args.file_path));
    const segs: StyledSegment[] = [
      { text: "read ", style: "bold" },
      { text: path || "…", style: "accent" },
    ];
    const offset = num(args.offset);
    const limit = num(args.limit);
    if (offset !== undefined || limit !== undefined) {
      const start = offset ?? 1;
      const end = limit !== undefined ? start + limit - 1 : "";
      segs.push({ text: `:${start}${end ? `-${end}` : ""}`, style: "warning" });
    }
    return segs;
  },
  renderResult(details: any, isError) {
    if (isError) return []; // error icon is sufficient
    const trunc = details?.truncation;
    if (trunc?.truncated) {
      return [{ text: `${trunc.outputLines}/${trunc.totalLines} lines`, style: "warning" }];
    }
    return [];
  },
};

const edit: MobileToolRenderer = {
  renderCall(args) {
    const path = shortenPath(str(args.path || args.file_path));
    const segs: StyledSegment[] = [
      { text: "edit ", style: "bold" },
      { text: path || "…", style: "accent" },
    ];
    return segs;
  },
  renderResult(details: any, isError) {
    if (isError) return []; // error icon is sufficient
    const line = details?.firstChangedLine;
    if (typeof line === "number") {
      return [{ text: `applied :${line}`, style: "success" }];
    }
    return [{ text: "applied", style: "success" }];
  },
};

const write: MobileToolRenderer = {
  renderCall(args) {
    const path = shortenPath(str(args.path || args.file_path));
    return [
      { text: "write ", style: "bold" },
      { text: path || "…", style: "accent" },
    ];
  },
  renderResult(_details: any, isError) {
    if (isError) return []; // error icon is sufficient
    return [{ text: "✓", style: "success" }];
  },
};

const grep: MobileToolRenderer = {
  renderCall(args) {
    const pattern = str(args.pattern);
    const path = shortenPath(str(args.path) || ".");
    const segs: StyledSegment[] = [
      { text: "grep ", style: "bold" },
      { text: `/${pattern}/`, style: "accent" },
      { text: ` in ${path}`, style: "muted" },
    ];
    const glob = str(args.glob);
    if (glob) segs.push({ text: ` (${glob})`, style: "dim" });
    return segs;
  },
  renderResult(details: any, isError) {
    if (isError) return []; // error icon is sufficient
    const limit = details?.matchLimitReached;
    const trunc = details?.truncation;
    if (limit || trunc?.truncated) {
      const parts: string[] = [];
      if (limit) parts.push(`${limit} match limit`);
      if (trunc?.truncated) parts.push("truncated");
      return [{ text: parts.join(", "), style: "warning" }];
    }
    return [];
  },
};

const find: MobileToolRenderer = {
  renderCall(args) {
    const pattern = str(args.pattern);
    const path = shortenPath(str(args.path) || ".");
    return [
      { text: "find ", style: "bold" },
      { text: pattern || "*", style: "accent" },
      { text: ` in ${path}`, style: "muted" },
    ];
  },
  renderResult(details: any, isError) {
    if (isError) return []; // error icon is sufficient
    const limit = details?.resultLimitReached;
    const trunc = details?.truncation;
    if (limit || trunc?.truncated) {
      const parts: string[] = [];
      if (limit) parts.push(`${limit} result limit`);
      if (trunc?.truncated) parts.push("truncated");
      return [{ text: parts.join(", "), style: "warning" }];
    }
    return [];
  },
};

const ls: MobileToolRenderer = {
  renderCall(args) {
    const path = shortenPath(str(args.path) || ".");
    return [
      { text: "ls ", style: "bold" },
      { text: path, style: "accent" },
    ];
  },
  renderResult(details: any, isError) {
    if (isError) return []; // error icon is sufficient
    const limit = details?.entryLimitReached;
    const trunc = details?.truncation;
    if (limit || trunc?.truncated) {
      const parts: string[] = [];
      if (limit) parts.push(`${limit} entry limit`);
      if (trunc?.truncated) parts.push("truncated");
      return [{ text: parts.join(", "), style: "warning" }];
    }
    return [];
  },
};

const todo: MobileToolRenderer = {
  renderCall(args) {
    const action = str(args.action);
    const segs: StyledSegment[] = [{ text: "todo ", style: "bold" }, { text: action, style: "accent" }];
    const title = str(args.title);
    if (title) segs.push({ text: ` "${firstLine(title, 50)}"`, style: "muted" });
    const id = str(args.id);
    if (id) segs.push({ text: ` ${id}`, style: "dim" });
    return segs;
  },
  renderResult(details: any, isError) {
    if (isError || details?.error) return []; // error icon is sufficient
    const action = str(details?.action);
    if (action === "list" || action === "list-all") {
      const count = Array.isArray(details?.todos) ? details.todos.length : 0;
      return [{ text: `${count} todo(s)`, style: "success" }];
    }
    return [{ text: "✓", style: "success" }];
  },
};

// ─── Registry ───

const BUILTIN_RENDERERS: Record<string, MobileToolRenderer> = {
  bash,
  read,
  edit,
  write,
  grep,
  find,
  ls,
  todo,
};

export class MobileRendererRegistry {
  private renderers = new Map<string, MobileToolRenderer>();

  constructor() {
    // Load built-in renderers
    for (const [name, renderer] of Object.entries(BUILTIN_RENDERERS)) {
      this.renderers.set(name, renderer);
    }
  }

  /** Register a renderer (extension sidecar or config override). */
  register(toolName: string, renderer: MobileToolRenderer): void {
    this.renderers.set(toolName, renderer);
  }

  /** Register multiple renderers from a sidecar module. */
  registerAll(renderers: Record<string, MobileToolRenderer>): void {
    for (const [name, renderer] of Object.entries(renderers)) {
      if (renderer && typeof renderer.renderCall === "function" && typeof renderer.renderResult === "function") {
        this.renderers.set(name, renderer);
      }
    }
  }

  /** Get a renderer by tool name. */
  get(toolName: string): MobileToolRenderer | undefined {
    return this.renderers.get(toolName);
  }

  /** Render call segments, returning undefined if no renderer or on error. */
  renderCall(toolName: string, args: Record<string, unknown>): StyledSegment[] | undefined {
    const renderer = this.renderers.get(toolName);
    if (!renderer) return undefined;
    try {
      const segments = renderer.renderCall(args);
      return Array.isArray(segments) && segments.length > 0 ? segments : undefined;
    } catch {
      return undefined;
    }
  }

  /** Render result segments, returning undefined if no renderer or on error. */
  renderResult(toolName: string, details: unknown, isError: boolean): StyledSegment[] | undefined {
    const renderer = this.renderers.get(toolName);
    if (!renderer) return undefined;
    try {
      const segments = renderer.renderResult(details, isError);
      return Array.isArray(segments) && segments.length > 0 ? segments : undefined;
    } catch {
      return undefined;
    }
  }

  /** Number of registered renderers. */
  get size(): number {
    return this.renderers.size;
  }

  /** Check if a tool has a renderer. */
  has(toolName: string): boolean {
    return this.renderers.has(toolName);
  }

  /**
   * Discover sidecar files in the extensions directory.
   *
   * Convention:
   * - File extensions: `memory.mobile.ts` alongside `memory.ts`
   * - Directory extensions: `my-ext/mobile.ts` alongside `my-ext/index.ts`
   *
   * Returns absolute paths to discovered sidecars.
   */
  static discoverSidecars(extensionsDir: string = HOST_EXTENSIONS_DIR): string[] {
    if (!existsSync(extensionsDir)) return [];

    const sidecars: string[] = [];

    for (const entry of readdirSync(extensionsDir)) {
      if (entry.startsWith(".")) continue;

      const absPath = join(extensionsDir, entry);

      // File sidecar: *.mobile.ts or *.mobile.js
      if (entry.endsWith(".mobile.ts") || entry.endsWith(".mobile.js")) {
        sidecars.push(absPath);
        continue;
      }

      // Directory sidecar: dir/mobile.ts or dir/mobile.js
      try {
        if (statSync(absPath).isDirectory()) {
          for (const suffix of ["mobile.ts", "mobile.js"]) {
            const candidate = join(absPath, suffix);
            if (existsSync(candidate)) {
              sidecars.push(candidate);
              break;
            }
          }
        }
      } catch {
        // stat failed — skip
      }
    }

    return sidecars;
  }

  /**
   * Load a single sidecar module and register its renderers.
   *
   * Sidecar modules export a default object keyed by tool name:
   * ```
   * export default {
   *   remember: { renderCall(args) {...}, renderResult(details, isError) {...} },
   *   recall:   { renderCall(args) {...}, renderResult(details, isError) {...} },
   * }
   * ```
   *
   * Node 25+ natively imports .ts files (type stripping).
   */
  async loadSidecar(sidecarPath: string): Promise<{ loaded: string[]; errors: string[] }> {
    const loaded: string[] = [];
    const errors: string[] = [];

    try {
      // Dynamic import works for both .ts and .js on Node 25+
      const mod = await import(sidecarPath);
      const renderers = mod.default ?? mod;

      if (typeof renderers !== "object" || renderers === null) {
        errors.push(`${sidecarPath}: default export is not an object`);
        return { loaded, errors };
      }

      for (const [toolName, renderer] of Object.entries(renderers)) {
        const r = renderer as any;
        if (r && typeof r.renderCall === "function" && typeof r.renderResult === "function") {
          this.renderers.set(toolName, r);
          loaded.push(toolName);
        } else {
          errors.push(`${sidecarPath}: "${toolName}" missing renderCall or renderResult`);
        }
      }
    } catch (err: any) {
      errors.push(`${sidecarPath}: ${err?.message || String(err)}`);
    }

    return { loaded, errors };
  }

  /**
   * Discover and load all sidecar files.
   * Returns summary of what was loaded and any errors.
   */
  async loadAllSidecars(extensionsDir?: string): Promise<{ loaded: string[]; errors: string[] }> {
    const sidecars = MobileRendererRegistry.discoverSidecars(extensionsDir);
    const allLoaded: string[] = [];
    const allErrors: string[] = [];

    for (const sidecarPath of sidecars) {
      const { loaded, errors } = await this.loadSidecar(sidecarPath);
      allLoaded.push(...loaded);
      allErrors.push(...errors);
    }

    return { loaded: allLoaded, errors: allErrors };
  }
}
