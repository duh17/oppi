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

import { createLogger } from "./logger.js";
import type {
  StyledSegment,
  ToolInputPresentation,
  ToolOutputPresentation,
  ToolOutputAvailability,
} from "./types.js";

import { BUILTIN_RENDERERS, validatedSegments } from "./mobile-renderer-segments.js";
import {
  BUILTIN_INPUT_PRESENTATIONS,
  BUILTIN_OUTPUT_PRESENTATIONS,
  validatedInputPresentation,
  resolveOutputPresentation,
} from "./mobile-renderer-facts.js";
import { outputAvailability } from "./mobile-renderer-availability.js";
export { resolveToolDisplay } from "./mobile-renderer-display.js";
export type { StyledSegment } from "./types.js";
export interface MobileToolRenderer {
  inputPresentation?: ToolInputPresentation;
  outputPresentation?: ToolOutputPresentation;
  renderCall(args: Record<string, unknown>): StyledSegment[];
  renderResult(details: unknown, isError: boolean): StyledSegment[];
}

function asRecord(v: unknown): Record<string, unknown> | undefined {
  return typeof v === "object" && v !== null ? (v as Record<string, unknown>) : undefined;
}
export class MobileRendererRegistry {
  private readonly log = createLogger();
  private readonly invalidWarnings = new Set<string>();
  private renderers = new Map<string, MobileToolRenderer>();

  constructor() {
    // Load built-in renderers
    for (const [name, renderer] of Object.entries(BUILTIN_RENDERERS)) {
      this.renderers.set(name, {
        ...renderer,
        inputPresentation: BUILTIN_INPUT_PRESENTATIONS[name],
        outputPresentation: BUILTIN_OUTPUT_PRESENTATIONS[name],
      });
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

  /** Static producer metadata is shared by live events and trace replay. */
  inputPresentation(toolName: string): ToolInputPresentation | undefined {
    const renderer = this.renderers.get(toolName);
    const value = renderer?.inputPresentation;
    if (value === undefined) {
      return renderer ? undefined : BUILTIN_INPUT_PRESENTATIONS[toolName];
    }
    return validatedInputPresentation(value, () =>
      this.warnInvalidRenderer(toolName, "input", "invalid inputPresentation.fields"),
    );
  }

  /** Explicit result facts win over the current registry's static declaration. */
  outputPresentation(toolName: string, details?: unknown): ToolOutputPresentation | undefined {
    return resolveOutputPresentation(
      this.renderers.has(toolName)
        ? this.renderers.get(toolName)?.outputPresentation
        : BUILTIN_OUTPUT_PRESENTATIONS[toolName],
      details,
    );
  }

  /** Shared live/history projection of Pi result availability. Never expose a path. */
  outputAvailability(details: unknown): ToolOutputAvailability {
    return outputAvailability(details);
  }

  /** Render call segments, returning undefined if no renderer or on error. */
  renderCall(toolName: string, args: Record<string, unknown>): StyledSegment[] | undefined {
    const renderer = this.renderers.get(toolName);
    if (!renderer) return undefined;
    try {
      return validatedSegments(renderer.renderCall(args), (reason) =>
        this.warnInvalidRenderer(toolName, "call", reason),
      );
    } catch (error) {
      this.warnInvalidRenderer(
        toolName,
        "call",
        error instanceof Error ? error.message : String(error),
      );
      return undefined;
    }
  }

  /** Render result segments, returning undefined if no renderer or on error. */
  renderResult(toolName: string, details: unknown, isError: boolean): StyledSegment[] | undefined {
    const renderer = this.renderers.get(toolName);
    if (!renderer) return undefined;
    try {
      return validatedSegments(renderer.renderResult(details, isError), (reason) =>
        this.warnInvalidRenderer(toolName, "result", reason),
      );
    } catch (error) {
      this.warnInvalidRenderer(
        toolName,
        "result",
        error instanceof Error ? error.message : String(error),
      );
      return undefined;
    }
  }

  private warnInvalidRenderer(
    toolName: string,
    phase: "call" | "result" | "input",
    reason: string,
  ): void {
    const key = `${toolName}\u0000${phase}\u0000${reason}`;
    if (this.invalidWarnings.has(key)) return;
    this.invalidWarnings.add(key);
    this.log.warn("mobile_renderer.invalid_segments", { toolName, phase, reason });
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
            ...(candidate?.inputPresentation !== undefined
              ? { inputPresentation: candidate.inputPresentation as ToolInputPresentation }
              : {}),
            ...(candidate?.outputPresentation !== undefined
              ? { outputPresentation: candidate.outputPresentation as ToolOutputPresentation }
              : {}),
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
