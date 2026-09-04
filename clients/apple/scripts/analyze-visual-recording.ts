#!/usr/bin/env bun

import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

/** Same downscale as StreamingFlickerCaptureUITests, full-frame (no overlay crop). */
export const SAMPLE_WIDTH = 96;
export const SAMPLE_HEIGHT = 160;

/** Flicker harness: `delta > 18` is a large jump. */
export const LARGE_DELTA_THRESHOLD = 18;

/** Near-zero mean luma delta. Documented on every report as `freeze_threshold`. */
export const FREEZE_THRESHOLD = 1;

export const HONESTY_NOTE =
  "30fps H.264 cannot prove 8.33ms hitches; compression can invent motion.";

export type FreezeRun = {
  start_frame: number;
  end_frame: number;
  frame_count: number;
  duration_s: number;
};

export type VisualPerfReport = {
  recording_fps: number;
  frame_count: number;
  duration_s: number;
  max_average_delta: number;
  large_delta_frames: number[];
  freeze_runs: FreezeRun[];
  freeze_threshold: number;
  large_delta_threshold: number;
  settle_s: number;
  honesty_note: string;
};

export type CliOptions = {
  help: boolean;
  inputPath?: string;
  fps?: number;
  outPath?: string;
};

const DEFAULT_PNG_FPS = 30;
const FRAME_BYTE_SIZE = SAMPLE_WIDTH * SAMPLE_HEIGHT * 3;
const FFMPEG_MAX_BUFFER = 512 * 1024 * 1024;

export function averageAbsoluteDelta(a: Uint8Array, b: Uint8Array): number {
  const count = Math.min(a.length, b.length);
  if (count === 0) return 0;
  let sum = 0;
  for (let i = 0; i < count; i += 1) {
    const left = a[i];
    const right = b[i];
    if (left === undefined || right === undefined) continue;
    sum += Math.abs(left - right);
  }
  return sum / count;
}

export function lumaFromRgb24(rgb: Uint8Array): Uint8Array {
  if (rgb.length % 3 !== 0) {
    throw new Error(`RGB24 buffer length ${rgb.length} is not a multiple of 3`);
  }
  const count = rgb.length / 3;
  const luma = new Uint8Array(count);
  for (let i = 0; i < count; i += 1) {
    const r = rgb[i * 3] ?? 0;
    const g = rgb[i * 3 + 1] ?? 0;
    const b = rgb[i * 3 + 2] ?? 0;
    // Rec.601 luma, truncated into 0…255 like the flicker UITest UInt8 cast.
    luma[i] = Math.max(0, Math.min(255, Math.trunc(0.299 * r + 0.587 * g + 0.114 * b)));
  }
  return luma;
}

export function computeVisualMetrics(input: {
  deltas: number[];
  recordingFps: number;
  frameCount?: number;
}): VisualPerfReport {
  const { deltas, recordingFps } = input;
  const frameCount = input.frameCount ?? (deltas.length === 0 ? 0 : deltas.length + 1);
  const duration_s = frameCount === 0 || !(recordingFps > 0) ? 0 : frameCount / recordingFps;

  let max_average_delta = 0;
  const large_delta_frames: number[] = [];
  let lastLargeFrame: number | undefined;
  const freeze_runs: FreezeRun[] = [];
  let freezeStart: number | undefined;
  let freezeDeltaCount = 0;

  const flushFreeze = () => {
    if (freezeStart === undefined || freezeDeltaCount === 0) return;
    freeze_runs.push({
      start_frame: freezeStart,
      end_frame: freezeStart + freezeDeltaCount,
      frame_count: freezeDeltaCount + 1,
      duration_s: recordingFps > 0 ? freezeDeltaCount / recordingFps : 0,
    });
    freezeStart = undefined;
    freezeDeltaCount = 0;
  };

  for (let i = 0; i < deltas.length; i += 1) {
    const delta = deltas[i] ?? 0;
    if (delta > max_average_delta) max_average_delta = delta;
    if (delta > LARGE_DELTA_THRESHOLD) {
      const frame = i + 1;
      large_delta_frames.push(frame);
      lastLargeFrame = frame;
    }
    if (delta <= FREEZE_THRESHOLD) {
      if (freezeStart === undefined) freezeStart = i;
      freezeDeltaCount += 1;
    } else {
      flushFreeze();
    }
  }
  flushFreeze();

  return {
    recording_fps: recordingFps,
    frame_count: frameCount,
    duration_s,
    max_average_delta,
    large_delta_frames,
    freeze_runs,
    freeze_threshold: FREEZE_THRESHOLD,
    large_delta_threshold: LARGE_DELTA_THRESHOLD,
    settle_s:
      lastLargeFrame === undefined || !(recordingFps > 0) ? 0 : lastLargeFrame / recordingFps,
    honesty_note: HONESTY_NOTE,
  };
}

/** Numeric-aware order so `frame-2.png` precedes `frame-10.png`. */
export function compareFrameNames(a: string, b: string): number {
  return a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" });
}

export function parseArgs(argv: string[]): CliOptions {
  const options: CliOptions = { help: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg || arg === "--") continue;
    if (arg === "-h" || arg === "--help") {
      options.help = true;
      continue;
    }
    if (arg === "--fps") {
      const value = argv[i + 1];
      i += 1;
      const fps = Number(value);
      if (!Number.isFinite(fps) || fps <= 0) {
        throw new Error(`--fps requires a positive number (got ${value ?? "nothing"})`);
      }
      options.fps = fps;
      continue;
    }
    if (arg === "--out") {
      const value = argv[i + 1];
      i += 1;
      if (!value || value.startsWith("-")) {
        throw new Error("--out requires a path");
      }
      options.outPath = value;
      continue;
    }
    if (arg.startsWith("-")) {
      throw new Error(`Unknown option: ${arg}`);
    }
    if (options.inputPath) {
      throw new Error(`Unexpected extra argument: ${arg}`);
    }
    options.inputPath = arg;
  }
  return options;
}

export function analyzeRecording(inputPath: string, options: { fps?: number } = {}): VisualPerfReport {
  const resolved = resolve(inputPath);
  if (!existsSync(resolved)) {
    throw new Error(`Input not found: ${inputPath}`);
  }

  const info = statSync(resolved);
  let rgbFrames: Uint8Array[];
  let recordingFps = options.fps;

  if (info.isDirectory()) {
    rgbFrames = decodePngDirectory(resolved);
    if (recordingFps === undefined) recordingFps = DEFAULT_PNG_FPS;
  } else {
    rgbFrames = ffmpegRgbFrames(["-i", resolved]);
    if (recordingFps === undefined) recordingFps = probeVideoFps(resolved);
  }

  if (rgbFrames.length === 0) {
    throw new Error(`No frames decoded from ${inputPath}`);
  }

  const deltas: number[] = [];
  let previous: Uint8Array | undefined;
  for (const rgb of rgbFrames) {
    const luma = lumaFromRgb24(rgb);
    if (previous) deltas.push(averageAbsoluteDelta(previous, luma));
    previous = luma;
  }

  return computeVisualMetrics({
    deltas,
    recordingFps,
    frameCount: rgbFrames.length,
  });
}

function usageMessage(): string {
  return `analyze-visual-recording.ts — JSON visual-perf report from an MP4 or PNG directory

Usage:
  bun clients/apple/scripts/analyze-visual-recording.ts <path> [--fps N] [--out report.json]

Arguments:
  <path>           MP4 file, or directory of PNG frames (non-PNG files are ignored)

Options:
  --fps N          Override recording fps (PNG directories default to ${DEFAULT_PNG_FPS})
  --out <path>     Write JSON report to this path (also prints to stdout)
  -h, --help       Show this help

Sampling:
  Downscale to ${SAMPLE_WIDTH}x${SAMPLE_HEIGHT}, Rec.601 luma, mean absolute per-pixel delta.
  Large-delta threshold: ${LARGE_DELTA_THRESHOLD} (same as StreamingFlickerCaptureUITests).
  Freeze threshold: ${FREEZE_THRESHOLD} (reported as freeze_threshold).
  settle_s is the timestamp of the last large delta, or 0 if none.

Honesty:
  ${HONESTY_NOTE}
`;
}

function main(argv = process.argv.slice(2)): void {
  let options: CliOptions;
  try {
    options = parseArgs(argv);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    process.stderr.write(`${message}\n\n${usageMessage()}`);
    process.exit(1);
  }

  if (options.help) {
    process.stdout.write(usageMessage());
    process.exit(0);
  }

  if (!options.inputPath) {
    process.stderr.write(usageMessage());
    process.exit(1);
  }

  try {
    const report = analyzeRecording(options.inputPath, { fps: options.fps });
    const json = `${JSON.stringify(report, null, 2)}\n`;
    process.stdout.write(json);
    if (options.outPath) writeFileSync(options.outPath, json);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    process.stderr.write(`${message}\n`);
    process.exit(1);
  }
}

function requireBinary(name: string): string {
  const path = Bun.which(name);
  if (!path) {
    throw new Error(`${name} is required to decode recordings`);
  }
  return path;
}

function ffmpegRgbFrames(inputArgs: string[]): Uint8Array[] {
  const ffmpeg = requireBinary("ffmpeg");
  const result = spawnSync(
    ffmpeg,
    [
      "-hide_banner",
      "-loglevel",
      "error",
      ...inputArgs,
      "-vf",
      `scale=${SAMPLE_WIDTH}:${SAMPLE_HEIGHT}`,
      "-pix_fmt",
      "rgb24",
      "-f",
      "rawvideo",
      "pipe:1",
    ],
    { maxBuffer: FFMPEG_MAX_BUFFER },
  );
  if (result.status !== 0) {
    const stderr = bufferToUtf8(result.stderr).trim();
    throw new Error(`ffmpeg failed${stderr ? `: ${stderr}` : ""}`);
  }
  return splitRawRgb(result.stdout);
}

function splitRawRgb(stdout: Buffer | string | null): Uint8Array[] {
  const buffer = toBuffer(stdout);
  const frames: Uint8Array[] = [];
  for (let offset = 0; offset + FRAME_BYTE_SIZE <= buffer.length; offset += FRAME_BYTE_SIZE) {
    frames.push(Uint8Array.from(buffer.subarray(offset, offset + FRAME_BYTE_SIZE)));
  }
  if (frames.length === 0 && buffer.length > 0) {
    throw new Error(
      `Decoded ${buffer.length} bytes, smaller than one ${SAMPLE_WIDTH}x${SAMPLE_HEIGHT} RGB frame`,
    );
  }
  return frames;
}

function decodePngDirectory(dir: string): Uint8Array[] {
  const pngs = readdirSync(dir)
    .filter((name) => name.toLowerCase().endsWith(".png"))
    .sort(compareFrameNames)
    .map((name) => join(dir, name));
  if (pngs.length === 0) {
    throw new Error(`No PNG frames in ${dir}`);
  }
  const frames: Uint8Array[] = [];
  for (const png of pngs) {
    const decoded = ffmpegRgbFrames(["-i", png]);
    const first = decoded[0];
    if (!first) {
      throw new Error(`ffmpeg produced no pixels for ${png}`);
    }
    frames.push(first);
  }
  return frames;
}

function probeVideoFps(path: string): number {
  const ffprobe = requireBinary("ffprobe");
  const result = spawnSync(
    ffprobe,
    [
      "-v",
      "error",
      "-select_streams",
      "v:0",
      "-show_entries",
      "stream=avg_frame_rate,r_frame_rate",
      "-of",
      "json",
      path,
    ],
    { encoding: "utf8" },
  );
  if (result.status !== 0) {
    throw new Error(`ffprobe failed: ${(result.stderr ?? "").trim()}`);
  }
  let parsed: { streams?: Array<{ avg_frame_rate?: string; r_frame_rate?: string }> };
  try {
    parsed = JSON.parse(result.stdout || "{}") as {
      streams?: Array<{ avg_frame_rate?: string; r_frame_rate?: string }>;
    };
  } catch {
    throw new Error(`ffprobe returned invalid JSON for ${path}`);
  }
  const stream = parsed.streams?.[0];
  const fps = parseFrameRate(stream?.avg_frame_rate) || parseFrameRate(stream?.r_frame_rate);
  if (!(fps > 0)) {
    throw new Error(`Could not determine fps for ${path}; pass --fps N`);
  }
  return fps;
}

function parseFrameRate(rate: string | undefined): number {
  if (!rate || rate === "0/0") return NaN;
  const parts = rate.split("/");
  if (parts.length === 2) {
    const numerator = Number(parts[0]);
    const denominator = Number(parts[1]);
    if (!(denominator > 0)) return NaN;
    return numerator / denominator;
  }
  return Number(rate);
}

function toBuffer(value: Buffer | string | null): Buffer {
  if (value == null) return Buffer.alloc(0);
  return Buffer.isBuffer(value) ? value : Buffer.from(value);
}

function bufferToUtf8(value: Buffer | string | null): string {
  if (value == null) return "";
  return Buffer.isBuffer(value) ? value.toString("utf8") : value;
}

if (import.meta.main) {
  main();
}
