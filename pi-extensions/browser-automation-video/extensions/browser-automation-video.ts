import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, rm, stat } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { basename, join, relative, resolve } from "node:path";
import { promisify } from "node:util";
import { Type } from "typebox";

const execFileAsync = promisify(execFile);

const DEFAULT_URL = "https://example.com";
const DEFAULT_TAIL_WAIT_MS = 700;
const DEFAULT_TIMEOUT_MS = 120_000;
const TEMP_OUTPUT_PREFIX = "oppi-browser-automation-video-";
const SYSTEM_CHROME_PATH =
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const MAX_LOG_CHARS = 32_000;

type JsonObject = Record<string, unknown>;

export type BrowserStep = {
  action: string;
  selector?: string;
  text?: string;
  key?: string;
  direction?: string;
  pixels?: number;
  ms?: number;
  script?: string;
};

export type BrowserVideoParams = {
  url?: string;
  steps?: BrowserStep[];
  commands?: string[];
  outputName?: string;
  outputDir?: string;
  tailWaitMs?: number;
  timeoutMs?: number;
  viewportWidth?: number;
  viewportHeight?: number;
  headed?: boolean;
  useSystemChrome?: boolean;
  keepWebM?: boolean;
  renderInOppi?: boolean;
};

type ExecResult = {
  stdout: string;
  stderr: string;
};

type AttachmentHelper = {
  addFile(input: {
    path: string;
    kind: "video";
    mimeType: string;
    fileName?: string;
    durationSeconds?: number;
    width?: number;
    height?: number;
    deleteSource?: boolean;
  }): JsonObject | Promise<JsonObject>;
};

type VideoMetadata = {
  durationSeconds?: number;
  width?: number;
  height?: number;
};

type ExtensionContextWithOptionalAttachments = ExtensionContext & {
  attachments?: {
    addFile?: unknown;
  };
};

const BrowserStepSchema = Type.Object({
  action: Type.String({
    description:
      "One browser step: click, fill, type, keyboardType, press, wait, scroll, hover, focus, eval, snapshot, or screenshot.",
  }),
  selector: Type.Optional(
    Type.String({
      description: "CSS selector or agent-browser @ref for element actions.",
    }),
  ),
  text: Type.Optional(
    Type.String({
      description: "Text for fill/type/keyboardType or wait text.",
    }),
  ),
  key: Type.Optional(
    Type.String({ description: "Key for press, e.g. Enter, Tab, Control+a." }),
  ),
  direction: Type.Optional(
    Type.String({ description: "Scroll direction: up, down, left, or right." }),
  ),
  pixels: Type.Optional(
    Type.Integer({
      description: "Scroll distance in pixels.",
      minimum: 1,
      maximum: 5000,
    }),
  ),
  ms: Type.Optional(
    Type.Integer({
      description: "Wait duration in milliseconds.",
      minimum: 0,
      maximum: 30000,
    }),
  ),
  script: Type.Optional(Type.String({ description: "JavaScript for eval." })),
});

const BrowserVideoParamsSchema = Type.Object({
  url: Type.Optional(
    Type.String({ description: `Initial URL. Default: ${DEFAULT_URL}.` }),
  ),
  steps: Type.Optional(
    Type.Array(BrowserStepSchema, {
      description:
        "Structured browser automation steps to run while recording. Use commands for raw agent-browser syntax when needed.",
      maxItems: 40,
    }),
  ),
  commands: Type.Optional(
    Type.Array(Type.String(), {
      description:
        "Raw agent-browser commands, one per string, without the agent-browser prefix. Example: ['wait 1000', 'click @e2']. Runs after structured steps.",
      maxItems: 40,
    }),
  ),
  outputName: Type.Optional(
    Type.String({
      description:
        "Base file name for the recording. Default is derived from the URL and time.",
    }),
  ),
  outputDir: Type.Optional(
    Type.String({
      description:
        "Workspace-relative or absolute output directory. When omitted in Oppi, recording uses a temporary directory and only the session attachment is kept. Outside Oppi, set outputDir to preserve the MP4.",
    }),
  ),
  tailWaitMs: Type.Optional(
    Type.Integer({
      description: `Extra wait before stopping recording. Default: ${DEFAULT_TAIL_WAIT_MS}.`,
      minimum: 0,
      maximum: 30000,
    }),
  ),
  timeoutMs: Type.Optional(
    Type.Integer({
      description: `Overall command timeout in milliseconds. Default: ${DEFAULT_TIMEOUT_MS}.`,
      minimum: 5000,
      maximum: 600000,
    }),
  ),
  viewportWidth: Type.Optional(
    Type.Integer({
      description: "Browser viewport width. Default: agent-browser default.",
      minimum: 320,
      maximum: 3840,
    }),
  ),
  viewportHeight: Type.Optional(
    Type.Integer({
      description: "Browser viewport height. Default: agent-browser default.",
      minimum: 240,
      maximum: 2160,
    }),
  ),
  headed: Type.Optional(
    Type.Boolean({
      description: "Show the Chrome window while running. Default: false.",
    }),
  ),
  useSystemChrome: Type.Optional(
    Type.Boolean({
      description:
        "Prefer /Applications/Google Chrome.app when present. Default: true.",
    }),
  ),
  keepWebM: Type.Optional(
    Type.Boolean({
      description:
        "Keep the intermediate agent-browser WebM file. Default: false.",
    }),
  ),
  renderInOppi: Type.Optional(
    Type.Boolean({
      description:
        "Attach the MP4 to this tool result so Oppi renders a video row when the Oppi attachment helper is available. Default: true.",
    }),
  ),
});

export default function browserAutomationVideoExtension(
  pi: ExtensionAPI,
): void {
  pi.registerTool({
    name: "browser_automation_video",
    label: "Browser Automation Video",
    description:
      "Automate Chrome with agent-browser, record the run, convert it to MP4, and return an Oppi-renderable video attachment in the tool row.",
    promptSnippet:
      "Automate Chrome and record a playable MP4 of the browser run",
    promptGuidelines: [
      "Use browser_automation_video when the user wants a browser automation run recorded as video.",
      "browser_automation_video stores the MP4 as a session attachment for Oppi playback; pass outputDir when the user wants a local copy or when the session is not running under Oppi.",
      "Prefer structured steps for simple actions; use commands for advanced agent-browser syntax such as find, wait --text, or snapshot.",
    ],
    parameters: BrowserVideoParamsSchema,
    async execute(
      toolCallId,
      params: BrowserVideoParams,
      signal,
      onUpdate,
      ctx,
    ) {
      const cwd =
        typeof ctx.cwd === "string" && ctx.cwd ? ctx.cwd : process.cwd();
      const url = normalizeURL(params.url);
      const timeoutMs = params.timeoutMs ?? DEFAULT_TIMEOUT_MS;
      const attachmentHelper = getAttachmentHelper(ctx);
      const wantsOppiAttachment = params.renderInOppi !== false;
      if (!params.outputDir && (!wantsOppiAttachment || !attachmentHelper)) {
        throw new Error(
          "outputDir is required when Oppi attachment storage is unavailable or renderInOppi is false. Pass outputDir to keep the MP4 locally.",
        );
      }
      const temporaryOutputDir = params.outputDir
        ? undefined
        : await mkdtemp(join(tmpdir(), TEMP_OUTPUT_PREFIX));
      let keepTemporaryOutputDir = false;
      const outputDir =
        temporaryOutputDir ?? resolveOutputDir(cwd, params.outputDir);
      const outputBase = safeBaseName(
        params.outputName || defaultOutputName(url),
      );
      const webmPath = join(outputDir, `${outputBase}.webm`);
      const mp4Path = join(outputDir, `${outputBase}.mp4`);
      const sessionName = `oppi-browser-video-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
      const commandLog: string[] = [];
      const env = agentBrowserEnv(sessionName, params);
      let recordingStarted = false;

      await mkdir(outputDir, { recursive: true });
      await requireCommand(
        "agent-browser",
        ["--help"],
        cwd,
        timeoutMs,
        signal,
        "agent-browser is required. Install it with: brew install agent-browser",
      );
      await requireCommand(
        "ffmpeg",
        ["-version"],
        cwd,
        timeoutMs,
        signal,
        "ffmpeg is required to convert the recording to iOS-playable MP4. Install it with: brew install ffmpeg",
      );

      onUpdate?.({
        content: [
          { type: "text", text: `Starting Chrome recording…\nurl: ${url}` },
        ],
        details: { status: "recording", url, output: mp4Path },
      });

      try {
        if (params.viewportWidth || params.viewportHeight) {
          const width = String(params.viewportWidth ?? 1280);
          const height = String(params.viewportHeight ?? 720);
          await runAgentBrowser(["set", "viewport", width, height], {
            cwd,
            env,
            timeoutMs,
            signal,
            commandLog,
          });
        }

        await runAgentBrowser(["record", "start", webmPath, url], {
          cwd,
          env,
          timeoutMs,
          signal,
          commandLog,
        });
        recordingStarted = true;

        const structuredCommands = (params.steps ?? []).map(stepToCommand);
        const rawCommands = (params.commands ?? [])
          .map((command) => command.trim())
          .filter(Boolean);
        const commands = [...structuredCommands, ...rawCommands];
        if (commands.length > 0) {
          onUpdate?.({
            content: [
              {
                type: "text",
                text: `Running ${commands.length} browser automation step(s)…`,
              },
            ],
            details: {
              status: "automating",
              url,
              commandCount: commands.length,
              output: mp4Path,
            },
          });
          await runAgentBrowser(["batch", "--bail", ...commands], {
            cwd,
            env,
            timeoutMs,
            signal,
            commandLog,
          });
        }

        const tailWaitMs = params.tailWaitMs ?? DEFAULT_TAIL_WAIT_MS;
        if (tailWaitMs > 0) {
          await runAgentBrowser(["wait", String(tailWaitMs)], {
            cwd,
            env,
            timeoutMs,
            signal,
            commandLog,
          });
        }

        onUpdate?.({
          content: [
            { type: "text", text: "Stopping recording and converting to MP4…" },
          ],
          details: { status: "converting", url, output: mp4Path },
        });
        await runAgentBrowser(["record", "stop"], {
          cwd,
          env,
          timeoutMs,
          signal,
          commandLog,
        });
        recordingStarted = false;

        await convertWebMToMP4(
          webmPath,
          mp4Path,
          cwd,
          timeoutMs,
          signal,
          commandLog,
        );
        if (params.keepWebM !== true) {
          await removeIfExists(webmPath);
        }

        const metadata: VideoMetadata = await videoMetadata(
          mp4Path,
          cwd,
          timeoutMs,
          signal,
        ).catch(() => ({}));
        const finalURL = await optionalAgentBrowser(["get", "url"], {
          cwd,
          env,
          timeoutMs,
          signal,
          commandLog,
        });
        const title = await optionalAgentBrowser(["get", "title"], {
          cwd,
          env,
          timeoutMs,
          signal,
          commandLog,
        });
        const fileInfo = await stat(mp4Path);
        const attachment =
          wantsOppiAttachment && attachmentHelper
            ? await Promise.resolve(
                attachmentHelper.addFile({
                  path: mp4Path,
                  kind: "video",
                  mimeType: "video/mp4",
                  fileName: basename(mp4Path),
                  ...(metadata.durationSeconds !== undefined
                    ? { durationSeconds: metadata.durationSeconds }
                    : {}),
                  ...(metadata.width !== undefined
                    ? { width: metadata.width }
                    : {}),
                  ...(metadata.height !== undefined
                    ? { height: metadata.height }
                    : {}),
                  deleteSource: temporaryOutputDir !== undefined,
                }),
              ).catch((error: unknown) => {
                keepTemporaryOutputDir = temporaryOutputDir !== undefined;
                return { error: safeError(error) };
              })
            : undefined;
        const attachmentWarning =
          wantsOppiAttachment && !attachmentHelper
            ? "Oppi attachment storage is unavailable; local MP4 kept."
            : undefined;
        const attachmentError =
          attachment && "error" in attachment
            ? String(attachment.error)
            : undefined;

        const keptTemporaryMP4Path =
          temporaryOutputDir && attachmentError ? mp4Path : undefined;
        const relativeMP4 = temporaryOutputDir
          ? keptTemporaryMP4Path
            ? keptTemporaryMP4Path
            : "stored session attachment"
          : relativePath(cwd, mp4Path);
        const summaryLines = [
          "Browser automation video recorded.",
          `URL: ${url}`,
          finalURL ? `Final URL: ${finalURL.trim()}` : undefined,
          title ? `Title: ${title.trim()}` : undefined,
          `MP4: ${relativeMP4}`,
          `Size: ${formatBytes(fileInfo.size)}`,
          metadata.durationSeconds !== undefined
            ? `Duration: ${metadata.durationSeconds.toFixed(2)}s`
            : undefined,
          metadata.width && metadata.height
            ? `Frame: ${metadata.width}×${metadata.height}`
            : undefined,
          attachmentWarning ? `Attachment: ${attachmentWarning}` : undefined,
          attachmentError ? `Attachment: ${attachmentError}` : undefined,
        ].filter(Boolean) as string[];

        const media =
          attachment && !("error" in attachment) ? [attachment] : [];

        const details = {
          expandedText: summaryLines.join("\n"),
          presentationFormat: "markdown",
          filePath:
            keptTemporaryMP4Path ?? (temporaryOutputDir ? undefined : mp4Path),
          url,
          finalURL: finalURL?.trim(),
          title: title?.trim(),
          output: {
            mp4Path:
              keptTemporaryMP4Path ??
              (temporaryOutputDir ? undefined : mp4Path),
            webmPath:
              params.keepWebM === true &&
              (!temporaryOutputDir || keepTemporaryOutputDir)
                ? webmPath
                : undefined,
            sizeBytes: fileInfo.size,
            ...metadata,
          },
          browser: {
            engine: "chrome",
            session: sessionName,
            executablePath: env.AGENT_BROWSER_EXECUTABLE_PATH,
            headed: params.headed === true,
          },
          media,
          attachment: attachment ?? undefined,
          commands: commandLog.slice(-80),
        };

        return {
          content: [{ type: "text", text: summaryLines.join("\n") }],
          details,
        };
      } finally {
        if (recordingStarted) {
          await optionalAgentBrowser(["record", "stop"], {
            cwd,
            env,
            timeoutMs,
            signal: undefined,
            commandLog,
          });
        }
        await optionalAgentBrowser(["close"], {
          cwd,
          env,
          timeoutMs: 10_000,
          signal: undefined,
          commandLog,
        });
        if (temporaryOutputDir && !keepTemporaryOutputDir) {
          await rm(temporaryOutputDir, { recursive: true, force: true });
        }
      }
    },
  });
}

function getAttachmentHelper(
  ctx: ExtensionContext,
): AttachmentHelper | undefined {
  const attachments = (ctx as ExtensionContextWithOptionalAttachments)
    .attachments;
  if (!attachments || typeof attachments !== "object") return undefined;
  const addFile = (attachments as { addFile?: unknown }).addFile;
  return typeof addFile === "function"
    ? ({ addFile } as AttachmentHelper)
    : undefined;
}

export function normalizeURL(raw: string | undefined): string {
  const trimmed = raw?.trim() || DEFAULT_URL;
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(trimmed)) return trimmed;
  return `https://${trimmed}`;
}

export function resolveOutputDir(cwd: string, raw: string | undefined): string {
  const value = raw?.trim();
  if (!value)
    throw new Error(
      "outputDir is required when not using a temporary output directory",
    );
  return resolve(cwd, expandHome(value));
}

function expandHome(path: string): string {
  if (path === "~") return homedir();
  if (path.startsWith("~/")) return join(homedir(), path.slice(2));
  return path;
}

export function safeBaseName(raw: string): string {
  const cleaned = raw
    .trim()
    .replace(/\.[a-z0-9]{2,5}$/i, "")
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80);
  return cleaned || `browser-video-${Date.now().toString(36)}`;
}

export function defaultOutputName(url: string): string {
  let host = "browser";
  try {
    host = new URL(url).hostname || host;
  } catch {
    // Keep default.
  }
  return `${host}-${new Date().toISOString().replace(/[:.]/g, "-")}`;
}

function agentBrowserEnv(
  sessionName: string,
  params: BrowserVideoParams,
): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    AGENT_BROWSER_SESSION: sessionName,
    AGENT_BROWSER_ENGINE: "chrome",
    AGENT_BROWSER_HEADLESS: params.headed === true ? "0" : "1",
  };

  if (params.headed === true) {
    env.AGENT_BROWSER_HEADED = "1";
  }

  if (params.useSystemChrome !== false && existsSync(SYSTEM_CHROME_PATH)) {
    env.AGENT_BROWSER_EXECUTABLE_PATH = SYSTEM_CHROME_PATH;
  }
  return env;
}

export function stepToCommand(step: BrowserStep): string {
  const action = step.action.trim();
  switch (action) {
    case "click":
    case "dblclick":
    case "hover":
    case "focus":
    case "check":
    case "uncheck":
      return `${action} ${quoteAgentBrowserArg(required(step.selector, `${action}.selector`))}`;
    case "fill":
    case "type":
      return `${action} ${quoteAgentBrowserArg(required(step.selector, `${action}.selector`))} ${quoteAgentBrowserArg(required(step.text, `${action}.text`))}`;
    case "keyboardType":
      return `keyboard type ${quoteAgentBrowserArg(required(step.text, "keyboardType.text"))}`;
    case "press":
      return `press ${required(step.key, "press.key")}`;
    case "wait":
      if (step.text) return `wait --text ${quoteAgentBrowserArg(step.text)}`;
      if (step.selector) return `wait ${quoteAgentBrowserArg(step.selector)}`;
      return `wait ${String(step.ms ?? DEFAULT_TAIL_WAIT_MS)}`;
    case "scroll":
      return `scroll ${step.direction ?? "down"} ${String(step.pixels ?? 600)}`;
    case "eval":
      return `eval ${quoteAgentBrowserArg(required(step.script, "eval.script"))}`;
    case "snapshot":
      return "snapshot";
    case "screenshot":
      return "screenshot";
    default:
      throw new Error(`Unsupported browser automation step action: ${action}`);
  }
}

function required(value: string | undefined, label: string): string {
  const trimmed = value?.trim();
  if (!trimmed) throw new Error(`Missing ${label}`);
  return trimmed;
}

function quoteAgentBrowserArg(value: string): string {
  if (/^[A-Za-z0-9_@./:=?&%#,+-]+$/.test(value)) return value;
  return JSON.stringify(value);
}

async function requireCommand(
  command: string,
  args: string[],
  cwd: string,
  timeoutMs: number,
  signal: AbortSignal | undefined,
  message: string,
): Promise<void> {
  try {
    await execFileAsync(command, args, {
      cwd,
      timeout: Math.min(timeoutMs, 10_000),
      signal,
    });
  } catch {
    throw new Error(message);
  }
}

async function runAgentBrowser(
  args: string[],
  options: {
    cwd: string;
    env: NodeJS.ProcessEnv;
    timeoutMs: number;
    signal: AbortSignal | undefined;
    commandLog: string[];
  },
): Promise<ExecResult> {
  options.commandLog.push(`agent-browser ${args.join(" ")}`);
  const result = await execFileAsync("agent-browser", args, {
    cwd: options.cwd,
    env: options.env,
    timeout: options.timeoutMs,
    signal: options.signal,
    maxBuffer: 10 * 1024 * 1024,
  });
  const stdout = result.stdout?.toString() ?? "";
  const stderr = result.stderr?.toString() ?? "";
  if (stdout.trim()) options.commandLog.push(truncateLog(stdout.trim()));
  if (stderr.trim())
    options.commandLog.push(truncateLog(`[stderr]\n${stderr.trim()}`));
  return { stdout, stderr };
}

async function optionalAgentBrowser(
  args: string[],
  options: {
    cwd: string;
    env: NodeJS.ProcessEnv;
    timeoutMs: number;
    signal: AbortSignal | undefined;
    commandLog: string[];
  },
): Promise<string | undefined> {
  try {
    const result = await runAgentBrowser(args, options);
    return result.stdout.trim() || undefined;
  } catch (error) {
    options.commandLog.push(
      `optional command failed: agent-browser ${args.join(" ")}\n${safeError(error)}`,
    );
    return undefined;
  }
}

async function convertWebMToMP4(
  webmPath: string,
  mp4Path: string,
  cwd: string,
  timeoutMs: number,
  signal: AbortSignal | undefined,
  commandLog: string[],
): Promise<void> {
  const args = [
    "-hide_banner",
    "-loglevel",
    "error",
    "-y",
    "-i",
    webmPath,
    "-c:v",
    "libx264",
    "-pix_fmt",
    "yuv420p",
    "-movflags",
    "+faststart",
    mp4Path,
  ];
  commandLog.push(`ffmpeg ${args.join(" ")}`);
  await execFileAsync("ffmpeg", args, {
    cwd,
    timeout: timeoutMs,
    signal,
    maxBuffer: 10 * 1024 * 1024,
  });
}

async function videoMetadata(
  mp4Path: string,
  cwd: string,
  timeoutMs: number,
  signal: AbortSignal | undefined,
): Promise<VideoMetadata> {
  const { stdout } = await execFileAsync(
    "ffprobe",
    [
      "-v",
      "error",
      "-select_streams",
      "v:0",
      "-show_entries",
      "stream=width,height",
      "-show_entries",
      "format=duration",
      "-of",
      "json",
      mp4Path,
    ],
    { cwd, timeout: Math.min(timeoutMs, 10_000), signal },
  );
  const parsed = JSON.parse(stdout.toString()) as {
    streams?: Array<{ width?: number; height?: number }>;
    format?: { duration?: string };
  };
  const stream = parsed.streams?.[0];
  const duration = parsed.format?.duration
    ? Number(parsed.format.duration)
    : undefined;
  return {
    ...(duration !== undefined && Number.isFinite(duration)
      ? { durationSeconds: duration }
      : {}),
    ...(stream?.width !== undefined ? { width: stream.width } : {}),
    ...(stream?.height !== undefined ? { height: stream.height } : {}),
  };
}

async function removeIfExists(path: string): Promise<void> {
  try {
    await import("node:fs/promises").then((fs) => fs.rm(path, { force: true }));
  } catch {
    // Best effort cleanup.
  }
}

function relativePath(cwd: string, path: string): string {
  const rel = relative(resolve(cwd), resolve(path));
  return rel && !rel.startsWith("..") ? rel : path;
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function truncateLog(value: string): string {
  return value.length <= MAX_LOG_CHARS
    ? value
    : `${value.slice(0, MAX_LOG_CHARS)}\n[truncated ${value.length - MAX_LOG_CHARS} chars]`;
}

function safeError(error: unknown): string {
  if (error instanceof Error) return error.message;
  return String(error);
}
