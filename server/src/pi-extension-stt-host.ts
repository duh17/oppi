/**
 * Duck-typed Pi package ./host contract for in-process dictation.
 *
 * Oppi resolves asr.extension to a package directory and imports only that
 * directory's ./host export. It must not load the package main / TUI factory.
 */

import { existsSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join } from "node:path";
import { pathToFileURL } from "node:url";

export interface TranscriptUpdate {
  text: string;
  committedText?: string;
  activeText?: string;
  snap?: boolean;
}

export interface DictationStream {
  ready: Promise<void>;
  feed(pcm: Float32Array): Promise<TranscriptUpdate | undefined>;
  finalize(): Promise<TranscriptUpdate>;
  cancel(): void;
}

export interface TranscriptionHost {
  readonly name: string;
  readonly model: string;
  prepare(): Promise<void>;
  createDictation(): DictationStream;
  shutdown(): Promise<void>;
}

export interface ResolvePiExtensionHostOptions {
  /** Override the Pi user-scope npm package store (tests). */
  packageStoreDir?: string;
}

export interface ResolvedPiExtensionHost {
  packageDir: string;
  hostPath: string;
}

const DEFAULT_PACKAGE_STORE_DIR = join(homedir(), ".pi", "agent", "npm", "node_modules");

const EXTENSION_FORMAT_ERROR = "expected package name, npm: spec, or absolute package directory";

/** True when asr.extension is a package name, npm: spec, or absolute package dir. */
export function isValidAsrExtensionSpec(value: string): boolean {
  return parseAsrExtensionSpec(value) !== undefined;
}

export function resolvePiExtensionHostExport(
  spec: string | undefined,
  options?: ResolvePiExtensionHostOptions,
): ResolvedPiExtensionHost | undefined {
  const parsed = parseAsrExtensionSpec(spec);
  if (!parsed) return undefined;

  const packageDir =
    parsed.kind === "directory"
      ? parsed.path
      : join(options?.packageStoreDir ?? DEFAULT_PACKAGE_STORE_DIR, parsed.name);
  if (!isExistingDirectory(packageDir)) return undefined;

  const hostPath = readHostExportPath(packageDir);
  if (!hostPath) return undefined;
  return { packageDir, hostPath };
}

export async function importTranscriptionHost(packageDir: string): Promise<TranscriptionHost> {
  const hostPath = readHostExportPath(packageDir);
  if (!hostPath) {
    throw new Error(`Package does not export ./host: ${packageDir}`);
  }

  const mod = (await import(pathToFileURL(hostPath).href)) as {
    createTranscriptionHost?: unknown;
  };
  if (typeof mod.createTranscriptionHost !== "function") {
    throw new Error(`createTranscriptionHost is missing from ${hostPath}`);
  }

  const host = (mod.createTranscriptionHost as () => unknown)();
  if (!isTranscriptionHost(host)) {
    throw new Error(`createTranscriptionHost did not return a TranscriptionHost: ${hostPath}`);
  }
  return host;
}

export function isDictationStreamEnabled(
  asr:
    | {
        backend?: string;
        extension?: string;
        sttEndpoint?: string;
      }
    | undefined,
): boolean {
  if (!asr) return false;
  if (asr.backend === "pi-extension") {
    return resolvePiExtensionHostExport(asr.extension) !== undefined;
  }
  return typeof asr.sttEndpoint === "string" && asr.sttEndpoint.trim().length > 0;
}

function parseAsrExtensionSpec(
  spec: string | undefined,
): { kind: "package"; name: string } | { kind: "directory"; path: string } | undefined {
  if (typeof spec !== "string") return undefined;
  const value = spec.trim();
  if (value.length === 0) return undefined;

  if (isAbsolute(value)) {
    if (looksLikeSourceEntry(value)) return undefined;
    return { kind: "directory", path: value };
  }

  const npmSpec = value.startsWith("npm:") ? value.slice("npm:".length).trim() : value;
  const name = packageNameFromSpec(npmSpec);
  if (!name) return undefined;
  return { kind: "package", name };
}

function packageNameFromSpec(spec: string): string | undefined {
  if (spec.length === 0 || spec.startsWith(".") || spec.includes("\\")) return undefined;
  if (looksLikeSourceEntry(spec)) return undefined;

  if (spec.startsWith("@")) {
    const match = spec.match(/^(@[^/]+\/[^@/]+)(?:@[^/]+)?$/);
    return match?.[1];
  }

  const match = spec.match(/^([^@/]+)(?:@[^/]+)?$/);
  return match?.[1];
}

function looksLikeSourceEntry(value: string): boolean {
  return /\.(ts|js|mjs|cjs|mts|cts)$/i.test(value);
}

function isExistingDirectory(path: string): boolean {
  try {
    return existsSync(path) && statSync(path).isDirectory();
  } catch {
    return false;
  }
}

function readHostExportPath(packageDir: string): string | undefined {
  const packageJsonPath = join(packageDir, "package.json");
  if (!existsSync(packageJsonPath)) return undefined;

  let pkg: unknown;
  try {
    pkg = JSON.parse(readFileSync(packageJsonPath, "utf-8"));
  } catch {
    return undefined;
  }
  if (!pkg || typeof pkg !== "object") return undefined;

  const exportsField = (pkg as { exports?: unknown }).exports;
  if (!exportsField || typeof exportsField !== "object" || Array.isArray(exportsField)) {
    return undefined;
  }

  const hostRel = resolveExportTarget((exportsField as Record<string, unknown>)["./host"]);
  if (!hostRel) return undefined;

  const hostPath = join(packageDir, hostRel);
  return existsSync(hostPath) ? hostPath : undefined;
}

function resolveExportTarget(value: unknown): string | undefined {
  if (typeof value === "string" && value.length > 0) return value;
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const rec = value as Record<string, unknown>;
  return resolveExportTarget(rec.import) ?? resolveExportTarget(rec.default);
}

function isTranscriptionHost(value: unknown): value is TranscriptionHost {
  if (!value || typeof value !== "object") return false;
  const host = value as TranscriptionHost;
  return (
    typeof host.name === "string" &&
    typeof host.model === "string" &&
    typeof host.prepare === "function" &&
    typeof host.createDictation === "function" &&
    typeof host.shutdown === "function"
  );
}

export const ASR_EXTENSION_FORMAT_ERROR = EXTENSION_FORMAT_ERROR;
