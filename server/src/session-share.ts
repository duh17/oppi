import { randomUUID } from "node:crypto";
import { existsSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn, spawnSync } from "node:child_process";

import type { AgentSession } from "@mariozechner/pi-coding-agent";

const DEFAULT_SHARE_VIEWER_URL = "https://pi.dev/session/";

interface GhCommandResult {
  stdout: string;
  stderr: string;
  code: number;
}

export interface ShareSessionResult {
  shareUrl: string;
  gistUrl: string;
  gistId: string;
}

interface ShareSessionDeps {
  ensureGhAuthenticated?: () => void;
  exportSessionToHtml?: (session: AgentSession, outputPath: string) => Promise<void>;
  createSecretGist?: (htmlPath: string) => Promise<GhCommandResult>;
  makeShareViewerUrl?: (gistId: string) => string;
  makeTempPath?: () => string;
}

function defaultEnsureGhAuthenticated(): void {
  try {
    const auth = spawnSync("gh", ["auth", "status"], { encoding: "utf-8" });
    if (auth.error) {
      const code = (auth.error as NodeJS.ErrnoException).code;
      if (code === "ENOENT") {
        throw new Error(
          "GitHub CLI (gh) is not installed. Install it from https://cli.github.com/",
        );
      }
      throw auth.error;
    }

    if (auth.status !== 0) {
      throw new Error("GitHub CLI is not logged in. Run 'gh auth login' first.");
    }
  } catch (error) {
    if (error instanceof Error) {
      throw error;
    }
    throw new Error(String(error));
  }
}

async function runGhCommand(args: string[], timeoutMs: number): Promise<GhCommandResult> {
  return new Promise<GhCommandResult>((resolve, reject) => {
    const proc = spawn("gh", args, {
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    let settled = false;

    const settle = (callback: () => void): void => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      callback();
    };

    const timer = setTimeout(() => {
      proc.kill();
      settle(() => reject(new Error(`gh ${args.join(" ")} timed out after ${timeoutMs}ms`)));
    }, timeoutMs);

    proc.stdout?.setEncoding("utf-8");
    proc.stdout?.on("data", (chunk: string) => {
      stdout += chunk;
    });

    proc.stderr?.setEncoding("utf-8");
    proc.stderr?.on("data", (chunk: string) => {
      stderr += chunk;
    });

    proc.on("error", (error) => {
      settle(() => reject(error));
    });

    proc.on("close", (code) => {
      settle(() => {
        resolve({
          stdout,
          stderr,
          code: code ?? -1,
        });
      });
    });
  });
}

async function defaultCreateSecretGist(htmlPath: string): Promise<GhCommandResult> {
  const result = await runGhCommand(["gist", "create", "--public=false", htmlPath], 120_000);

  if (result.code !== 0) {
    const reason = result.stderr.trim() || result.stdout.trim() || "Unknown error";
    throw new Error(`Failed to create gist: ${reason}`);
  }

  return result;
}

async function defaultExportSessionToHtml(
  session: AgentSession,
  outputPath: string,
): Promise<void> {
  await session.exportToHtml(outputPath);
}

function defaultMakeShareViewerUrl(gistId: string): string {
  const baseUrl = process.env.PI_SHARE_VIEWER_URL || DEFAULT_SHARE_VIEWER_URL;
  return `${baseUrl}#${gistId}`;
}

function parseGistUrl(output: string): string | undefined {
  const lines = output
    .split(/\r?\n/g)
    .map((line) => line.trim())
    .filter((line) => line.length > 0);

  for (const line of lines) {
    if ((line.startsWith("https://") || line.startsWith("http://")) && line.includes("gist")) {
      return line;
    }
  }

  return undefined;
}

function parseGistId(gistUrl: string): string | undefined {
  try {
    const url = new URL(gistUrl);
    const segment = url.pathname
      .split("/")
      .filter((part) => part.length > 0)
      .at(-1);
    if (!segment) {
      return undefined;
    }

    const normalized = segment.replace(/\.git$/i, "");
    return normalized.length > 0 ? normalized : undefined;
  } catch {
    const fallback = gistUrl
      .split("/")
      .filter((part) => part.length > 0)
      .at(-1)
      ?.replace(/\.git$/i, "");
    return fallback && fallback.length > 0 ? fallback : undefined;
  }
}

export async function shareSession(
  session: AgentSession,
  deps: ShareSessionDeps = {},
): Promise<ShareSessionResult> {
  const ensureGhAuthenticated = deps.ensureGhAuthenticated ?? defaultEnsureGhAuthenticated;
  const exportSessionToHtml = deps.exportSessionToHtml ?? defaultExportSessionToHtml;
  const createSecretGist = deps.createSecretGist ?? defaultCreateSecretGist;
  const makeShareViewerUrl = deps.makeShareViewerUrl ?? defaultMakeShareViewerUrl;
  const makeTempPath =
    deps.makeTempPath ?? (() => join(tmpdir(), `oppi-share-${randomUUID()}.html`));

  ensureGhAuthenticated();

  const sessionFile = session.getSessionStats().sessionFile;
  if (!sessionFile) {
    throw new Error("Cannot share this session because it has no persisted session file.");
  }

  const tempHtmlPath = makeTempPath();

  try {
    await exportSessionToHtml(session, tempHtmlPath);
    const gist = await createSecretGist(tempHtmlPath);

    const gistUrl = parseGistUrl(gist.stdout) ?? parseGistUrl(gist.stderr);
    if (!gistUrl) {
      throw new Error("Failed to parse gist URL from gh output");
    }

    const gistId = parseGistId(gistUrl);
    if (!gistId) {
      throw new Error("Failed to parse gist ID from gist URL");
    }

    const shareUrl = makeShareViewerUrl(gistId);
    return {
      shareUrl,
      gistUrl,
      gistId,
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (/(ENOENT|spawn\s+gh|not found)/i.test(message)) {
      throw new Error("GitHub CLI (gh) is not installed. Install it from https://cli.github.com/");
    }
    throw error;
  } finally {
    if (existsSync(tempHtmlPath)) {
      try {
        unlinkSync(tempHtmlPath);
      } catch {
        // Best-effort cleanup.
      }
    }
  }
}

export const __shareSessionTestUtils = {
  parseGistUrl,
  parseGistId,
  defaultMakeShareViewerUrl,
};
