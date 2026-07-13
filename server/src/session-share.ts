import {
  chmodSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn, spawnSync } from "node:child_process";

import type { AgentSession } from "@earendil-works/pi-coding-agent";
import {
  autoRedactionEnabled,
  blockOnSecretFindings,
  defaultRedactHtmlForShare,
  defaultSanitizeHtmlForShare,
  defaultScanHtmlForSecrets,
  formatShareErrorMessage,
  normalizeRedactionPolicy,
  secretScanEnabled,
  shareError,
  ShareSessionError,
  summarizeFindings,
  type ShareHtmlRedactionResult,
  type ShareRedactionFinding,
  type ShareSecretFinding,
  type ShareSessionRedactionPolicy,
  type ShareSessionRedactionPolicyInput,
  type ShareSessionRedactionSummary,
} from "./session-share-redaction.js";

export { ShareSessionError } from "./session-share-redaction.js";
export type {
  ShareRedactionFinding,
  ShareSecretFinding,
  ShareSessionErrorCode,
  ShareSessionRedactionPolicy,
  ShareSessionRedactionPolicyInput,
  ShareSessionRedactionSummary,
} from "./session-share-redaction.js";

const DEFAULT_SHARE_VIEWER_URL = "https://pi.dev/session/";

interface GhCommandResult {
  stdout: string;
  stderr: string;
  code: number;
}

export type ShareSessionAction = "prepare" | "publish";

export interface ShareSessionArtifactSummary {
  format: "html";
  bytes: number;
}

export interface ShareSessionScanSummary {
  enabled: boolean;
  blocked: boolean;
  findings: ShareSecretFinding[];
  residualFindings: ShareSecretFinding[];
}

export interface ShareSessionResult {
  shareUrl: string;
  gistUrl: string;
  gistId: string;
  phase: "published";
  share: {
    id: string;
    url: string;
    provider: "github_gist";
    providerRef: {
      gistId: string;
      gistUrl: string;
    };
  };
  artifact: ShareSessionArtifactSummary;
  scan: ShareSessionScanSummary;
  redaction: ShareSessionRedactionSummary;
  warnings: string[];
}

export interface ShareSessionPrepareResult {
  phase: "prepared";
  canPublish: boolean;
  artifact: ShareSessionArtifactSummary;
  scan: ShareSessionScanSummary;
  redaction: ShareSessionRedactionSummary;
}

export type ShareSessionCommandResult = ShareSessionResult | ShareSessionPrepareResult;

export interface ShareSessionOptions {
  action?: ShareSessionAction;
  redactionPolicy?: ShareSessionRedactionPolicyInput;
}

interface ShareSessionDeps {
  ensureGhAuthenticated?: () => void;
  exportSessionToHtml?: (session: AgentSession, outputPath: string) => Promise<void>;
  createSecretGist?: (htmlPath: string) => Promise<GhCommandResult>;
  makeShareViewerUrl?: (gistId: string) => string;
  makeTempPath?: () => string;
  scanHtmlForSecrets?: (html: string) => ShareSecretFinding[];
  redactHtml?: (html: string, policy: ShareSessionRedactionPolicy) => ShareHtmlRedactionResult;
  isSecretScanEnabled?: () => boolean;
  isAutoRedactionEnabled?: () => boolean;
  shouldBlockOnSecrets?: () => boolean;
}

function normalizeShareError(error: unknown): ShareSessionError {
  if (error instanceof ShareSessionError) {
    return error;
  }

  const message = error instanceof Error ? error.message : String(error);

  if (/(ENOENT|spawn\s+gh|not found)/i.test(message)) {
    return shareError(
      "gh_not_installed",
      "GitHub CLI (gh) is not installed. Install it from https://cli.github.com/",
    );
  }

  if (/timed out/i.test(message)) {
    return shareError("share_timeout", "Share request timed out. Please try again.");
  }

  return shareError("share_unknown", message || "Share failed.");
}

function defaultEnsureGhAuthenticated(): void {
  try {
    const auth = spawnSync("gh", ["auth", "status"], { encoding: "utf-8" });
    if (auth.error) {
      const code = (auth.error as NodeJS.ErrnoException).code;
      if (code === "ENOENT") {
        throw shareError(
          "gh_not_installed",
          "GitHub CLI (gh) is not installed. Install it from https://cli.github.com/",
        );
      }
      throw auth.error;
    }

    if (auth.status !== 0) {
      throw shareError(
        "gh_not_authenticated",
        "GitHub CLI is not logged in. Run 'gh auth login' first.",
      );
    }
  } catch (error) {
    if (error instanceof ShareSessionError) {
      throw error;
    }
    if (error instanceof Error) {
      throw normalizeShareError(error);
    }
    throw shareError("share_unknown", String(error));
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
      settle(() =>
        reject(shareError("share_timeout", `gh ${args.join(" ")} timed out after ${timeoutMs}ms`)),
      );
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
    throw shareError("gist_create_failed", `Failed to create gist: ${reason}`);
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
  options: ShareSessionOptions = {},
): Promise<ShareSessionCommandResult> {
  const action: ShareSessionAction = options.action === "prepare" ? "prepare" : "publish";
  const ensureGhAuthenticated = deps.ensureGhAuthenticated ?? defaultEnsureGhAuthenticated;
  const exportSessionToHtml = deps.exportSessionToHtml ?? defaultExportSessionToHtml;
  const createSecretGist = deps.createSecretGist ?? defaultCreateSecretGist;
  const makeShareViewerUrl = deps.makeShareViewerUrl ?? defaultMakeShareViewerUrl;
  const scanHtmlForSecrets = deps.scanHtmlForSecrets ?? defaultScanHtmlForSecrets;
  const redactHtml = deps.redactHtml ?? defaultRedactHtmlForShare;
  const isSecretScanEnabled = deps.isSecretScanEnabled ?? secretScanEnabled;
  const isAutoRedactionEnabled = deps.isAutoRedactionEnabled ?? autoRedactionEnabled;
  const shouldBlockOnSecrets = deps.shouldBlockOnSecrets ?? blockOnSecretFindings;
  const redactionPolicy = normalizeRedactionPolicy(options.redactionPolicy);

  const sessionFile = session.getSessionStats().sessionFile;
  if (!sessionFile) {
    throw shareError(
      "session_not_persisted",
      "Cannot share this session because it has no persisted session file.",
    );
  }

  const tempDir =
    typeof deps.makeTempPath === "function" ? null : mkdtempSync(join(tmpdir(), "oppi-share-"));
  // The public share viewer expects the gist to contain a stable `session.html` file.
  // Keep the parent temp directory unique, but the uploaded filename deterministic.
  const tempHtmlPath =
    typeof deps.makeTempPath === "function"
      ? deps.makeTempPath()
      : join(tempDir ?? tmpdir(), "session.html");

  try {
    await exportSessionToHtml(session, tempHtmlPath);

    if (existsSync(tempHtmlPath)) {
      try {
        chmodSync(tempHtmlPath, 0o600);
      } catch {
        // Best-effort hardening on POSIX systems.
      }
    }

    let html = "";
    try {
      html = readFileSync(tempHtmlPath, "utf-8");
    } catch (error) {
      throw shareError(
        "share_export_failed",
        `Failed to read temporary share export: ${error instanceof Error ? error.message : String(error)}`,
      );
    }

    const redactionEnabled = isAutoRedactionEnabled();
    if (!redactionEnabled) {
      const sanitizedHtml = defaultSanitizeHtmlForShare(html, redactionPolicy);
      if (sanitizedHtml !== html) {
        html = sanitizedHtml;
        try {
          writeFileSync(tempHtmlPath, html, "utf-8");
        } catch (error) {
          throw shareError(
            "share_export_failed",
            `Failed to write sanitized share export: ${error instanceof Error ? error.message : String(error)}`,
          );
        }
      }
    }

    const scanEnabled = isSecretScanEnabled();
    const preRedactionFindings = scanEnabled ? scanHtmlForSecrets(html) : [];

    const redactionResult = redactionEnabled
      ? redactHtml(html, redactionPolicy)
      : {
          html,
          findings: [] as ShareRedactionFinding[],
          totalReplacements: 0,
        };

    if (redactionEnabled && redactionResult.html !== html) {
      html = redactionResult.html;
      try {
        writeFileSync(tempHtmlPath, html, "utf-8");
      } catch (error) {
        throw shareError(
          "share_export_failed",
          `Failed to write redacted share export: ${error instanceof Error ? error.message : String(error)}`,
        );
      }
    }

    const residualFindings = scanEnabled ? scanHtmlForSecrets(html) : [];
    const blocked = residualFindings.length > 0 && shouldBlockOnSecrets();

    const artifact: ShareSessionArtifactSummary = {
      format: "html",
      bytes: Buffer.byteLength(html, "utf-8"),
    };

    const scan: ShareSessionScanSummary = {
      enabled: scanEnabled,
      blocked,
      findings: preRedactionFindings,
      residualFindings,
    };

    const redaction: ShareSessionRedactionSummary = {
      enabled: redactionEnabled,
      policy: redactionPolicy,
      totalReplacements: redactionResult.totalReplacements,
      findings: redactionResult.findings,
    };

    if (action === "prepare") {
      return {
        phase: "prepared",
        canPublish: !blocked,
        artifact,
        scan,
        redaction,
      };
    }

    if (blocked) {
      throw new ShareSessionError(
        "share_secret_detected",
        `Potential secrets remained after redaction (${summarizeFindings(residualFindings)}). Sharing blocked.`,
        residualFindings,
      );
    }

    ensureGhAuthenticated();

    const gist = await createSecretGist(tempHtmlPath);

    const gistUrl = parseGistUrl(gist.stdout) ?? parseGistUrl(gist.stderr);
    if (!gistUrl) {
      throw shareError("gist_parse_failed", "Failed to parse gist URL from gh output");
    }

    const gistId = parseGistId(gistUrl);
    if (!gistId) {
      throw shareError("gist_parse_failed", "Failed to parse gist ID from gist URL");
    }

    const warnings: string[] = [];
    if (redaction.totalReplacements > 0) {
      warnings.push(`auto_redaction_applied:${redaction.totalReplacements}`);
    }
    if (scan.residualFindings.length > 0) {
      warnings.push(`residual_secret_findings:${summarizeFindings(scan.residualFindings)}`);
    }

    const shareUrl = makeShareViewerUrl(gistId);
    return {
      shareUrl,
      gistUrl,
      gistId,
      phase: "published",
      share: {
        id: `share:${gistId}`,
        url: shareUrl,
        provider: "github_gist",
        providerRef: {
          gistId,
          gistUrl,
        },
      },
      artifact,
      scan,
      redaction,
      warnings,
    };
  } catch (error) {
    throw normalizeShareError(error);
  } finally {
    if (tempDir) {
      try {
        rmSync(tempDir, { recursive: true, force: true });
      } catch {
        // Best-effort cleanup.
      }
    } else if (existsSync(tempHtmlPath)) {
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
  formatShareErrorMessage,
  defaultScanHtmlForSecrets,
  defaultRedactHtmlForShare,
  normalizeRedactionPolicy,
};
