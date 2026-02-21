/**
 * Mobile tool renderer registry.
 *
 * Pre-renders styled summary segments for iOS tool call display.
 * Parallels pi's TUI `renderCall`/`renderResult` pattern but produces
 * serializable StyledSegment[] instead of TUI Component objects.
 *
 * Sources (load order, later overrides earlier):
 * 1. Built-in renderers (bash, read, edit, write, grep, find, ls, todo)
 * 2. User renderers (~/.pi/agent/mobile-renderers/*.ts)
 *
 * User renderers live in a dedicated directory separate from pi extensions
 * so the pi CLI doesn't try to load them as extensions.
 */

import { existsSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

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

function asRecord(v: unknown): Record<string, unknown> | undefined {
  return typeof v === "object" && v !== null ? (v as Record<string, unknown>) : undefined;
}

function recordField(
  v: Record<string, unknown> | undefined,
  key: string,
): Record<string, unknown> | undefined {
  return asRecord(v?.[key]);
}

/** Shorten long paths for display: /Users/alice/workspace/foo → ~/workspace/foo */
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
    return [
      { text: "$ ", style: "bold" },
      { text: cmd, style: "accent" },
    ];
  },
  renderResult(details: unknown, isError) {
    const payload = asRecord(details);
    const code = num(payload?.exitCode);
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
  renderResult(details: unknown, isError) {
    if (isError) return []; // error icon is sufficient
    const payload = asRecord(details);
    const trunc = recordField(payload, "truncation");
    if (trunc?.truncated === true) {
      const outputLines = num(trunc.outputLines) ?? "?";
      const totalLines = num(trunc.totalLines) ?? "?";
      return [{ text: `${outputLines}/${totalLines} lines`, style: "warning" }];
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
  renderResult(details: unknown, isError) {
    if (isError) return []; // error icon is sufficient
    const payload = asRecord(details);
    const line = num(payload?.firstChangedLine);
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
  renderResult(_details: unknown, isError) {
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
  renderResult(details: unknown, isError) {
    if (isError) return []; // error icon is sufficient
    const payload = asRecord(details);
    const limit = num(payload?.matchLimitReached);
    const trunc = recordField(payload, "truncation");
    if ((typeof limit === "number" && limit > 0) || trunc?.truncated === true) {
      const parts: string[] = [];
      if (typeof limit === "number" && limit > 0) parts.push(`${limit} match limit`);
      if (trunc?.truncated === true) parts.push("truncated");
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
  renderResult(details: unknown, isError) {
    if (isError) return []; // error icon is sufficient
    const payload = asRecord(details);
    const limit = num(payload?.resultLimitReached);
    const trunc = recordField(payload, "truncation");
    if ((typeof limit === "number" && limit > 0) || trunc?.truncated === true) {
      const parts: string[] = [];
      if (typeof limit === "number" && limit > 0) parts.push(`${limit} result limit`);
      if (trunc?.truncated === true) parts.push("truncated");
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
  renderResult(details: unknown, isError) {
    if (isError) return []; // error icon is sufficient
    const payload = asRecord(details);
    const limit = num(payload?.entryLimitReached);
    const trunc = recordField(payload, "truncation");
    if ((typeof limit === "number" && limit > 0) || trunc?.truncated === true) {
      const parts: string[] = [];
      if (typeof limit === "number" && limit > 0) parts.push(`${limit} entry limit`);
      if (trunc?.truncated === true) parts.push("truncated");
      return [{ text: parts.join(", "), style: "warning" }];
    }
    return [];
  },
};

const todo: MobileToolRenderer = {
  renderCall(args) {
    const action = str(args.action);
    const segs: StyledSegment[] = [
      { text: "todo ", style: "bold" },
      { text: action, style: "accent" },
    ];
    const title = str(args.title);
    if (title) segs.push({ text: ` "${firstLine(title, 50)}"`, style: "muted" });
    const id = str(args.id);
    if (id) segs.push({ text: ` ${id}`, style: "dim" });
    return segs;
  },
  renderResult(details: unknown, isError) {
    const payload = asRecord(details);
    if (isError || payload?.error) return []; // error icon is sufficient
    const action = str(payload?.action);
    if (action === "list" || action === "list-all") {
      const todos = payload?.todos;
      const count = Array.isArray(todos) ? todos.length : 0;
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
      if (
        renderer &&
        typeof renderer.renderCall === "function" &&
        typeof renderer.renderResult === "function"
      ) {
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

  /** Default directory for user-provided mobile renderers. */
  static readonly RENDERERS_DIR = join(homedir(), ".pi", "agent", "mobile-renderers");

  /**
   * Discover renderer files in the mobile-renderers directory.
   *
   * Every .ts/.js file in the directory is treated as a renderer module.
   * Returns absolute paths to discovered files.
   */
  static discoverRenderers(renderersDir: string = MobileRendererRegistry.RENDERERS_DIR): string[] {
    if (!existsSync(renderersDir)) return [];

    const files: string[] = [];
    for (const entry of readdirSync(renderersDir)) {
      if (entry.startsWith(".")) continue;
      if (entry.endsWith(".ts") || entry.endsWith(".js")) {
        files.push(join(renderersDir, entry));
      }
    }
    return files;
  }

  /**
   * Load a single renderer module and register its tools.
   *
   * Renderer modules export a default object keyed by tool name:
   * ```ts
   * export default {
   *   remember: { renderCall(args) {...}, renderResult(details, isError) {...} },
   *   recall:   { renderCall(args) {...}, renderResult(details, isError) {...} },
   * }
   * ```
   *
   * Node 25+ natively imports .ts files (type stripping).
   */
  async loadRenderer(filePath: string): Promise<{ loaded: string[]; errors: string[] }> {
    const loaded: string[] = [];
    const errors: string[] = [];

    try {
      const mod = await import(filePath);
      const renderers = mod.default ?? mod;

      if (typeof renderers !== "object" || renderers === null) {
        errors.push(`${filePath}: default export is not an object`);
        return { loaded, errors };
      }

      for (const [toolName, renderer] of Object.entries(renderers)) {
        const candidate = asRecord(renderer);
        const renderCall = candidate?.renderCall;
        const renderResult = candidate?.renderResult;

        if (typeof renderCall === "function" && typeof renderResult === "function") {
          this.renderers.set(toolName, {
            renderCall: (args) => renderCall(args) as StyledSegment[],
            renderResult: (details, isError) => renderResult(details, isError) as StyledSegment[],
          });
          loaded.push(toolName);
        } else {
          errors.push(`${filePath}: "${toolName}" missing renderCall or renderResult`);
        }
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      errors.push(`${filePath}: ${message}`);
    }

    return { loaded, errors };
  }

  /**
   * Discover and load all renderer files from the mobile-renderers directory.
   * Returns summary of what was loaded and any errors.
   */
  async loadAllRenderers(renderersDir?: string): Promise<{ loaded: string[]; errors: string[] }> {
    const files = MobileRendererRegistry.discoverRenderers(renderersDir);
    const allLoaded: string[] = [];
    const allErrors: string[] = [];

    for (const filePath of files) {
      const { loaded, errors } = await this.loadRenderer(filePath);
      allLoaded.push(...loaded);
      allErrors.push(...errors);
    }

    return { loaded: allLoaded, errors: allErrors };
  }
}
