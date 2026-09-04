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
  freeze_run_count_all: number;
  freeze_threshold: number;
  large_delta_threshold: number;
  settle_s: number;
  window_start_s: number;
  window_end_s: number;
  honesty_note: string;
};

export type AnalyzeVisualDeltasInput = {
  deltas: number[];
  recordingFps: number;
  frameCount?: number;
  startS?: number;
  endS?: number;
  autoSkip?: boolean;
  idleS?: number;
  minFreezeS?: number;
};

export type CliOptions = {
  help: boolean;
  inputPath?: string;
  fps?: number;
  outPath?: string;
  startS?: number;
  endS?: number;
  idleS?: number;
  minFreezeS?: number;
  autoSkip: boolean;
};

const DEFAULT_PNG_FPS = 30;
export const DEFAULT_IDLE_S = 2;
export const DEFAULT_MIN_FREEZE_S = 1;
/** Jumps in this prefix are a recording flash, not UI motion. */
const STARTUP_FLASH_S = 0.5;
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
    freeze_run_count_all: freeze_runs.length,
    freeze_threshold: FREEZE_THRESHOLD,
    large_delta_threshold: LARGE_DELTA_THRESHOLD,
    settle_s:
      lastLargeFrame === undefined || !(recordingFps > 0) ? 0 : lastLargeFrame / recordingFps,
    window_start_s: 0,
    window_end_s: duration_s,
    honesty_note: HONESTY_NOTE,
  };
}

export function analyzeVisualDeltas(input: AnalyzeVisualDeltasInput): VisualPerfReport {
  const fps = input.recordingFps;
  const sourceFrameCount =
    input.frameCount ?? (input.deltas.length === 0 ? 0 : input.deltas.length + 1);
  const autoSkip = input.autoSkip ?? true;
  const idleS = input.idleS ?? DEFAULT_IDLE_S;
  const minFreezeS = input.minFreezeS ?? DEFAULT_MIN_FREEZE_S;

  let startFrame = 0;
  let endFrame = sourceFrameCount;
  if (input.startS !== undefined) {
    startFrame = clampFrameIndex(frameIndexAtOrAfter(input.startS, fps), 0, sourceFrameCount);
  }
  if (input.endS !== undefined) {
    endFrame = clampFrameIndex(frameIndexAtOrAfter(input.endS, fps), 0, sourceFrameCount);
  }
  if (startFrame > endFrame) {
    startFrame = endFrame;
  }

  const sliced = { startFrame, endFrame };
  if (autoSkip && idleS > 0) {
    const skipped = skipIdleEnds(input.deltas, fps, sliced.startFrame, sliced.endFrame, idleS);
    // A leftover still frame means idle covered the clip; keep the pre-skip window.
    if (skipped.endFrame - skipped.startFrame > 1) {
      startFrame = skipped.startFrame;
      endFrame = skipped.endFrame;
    }
  }

  const windowFrames = Math.max(0, endFrame - startFrame);
  const windowDeltas =
    windowFrames <= 1 ? [] : input.deltas.slice(startFrame, endFrame - 1);
  const scored = computeVisualMetrics({
    deltas: windowDeltas,
    recordingFps: fps,
    frameCount: windowFrames,
  });
  const freeze_run_count_all = scored.freeze_runs.length;
  const freeze_runs = scored.freeze_runs.filter((run) => run.duration_s >= minFreezeS);

  return {
    ...scored,
    freeze_runs,
    freeze_run_count_all,
    window_start_s: fps > 0 ? startFrame / fps : 0,
    window_end_s: fps > 0 ? endFrame / fps : 0,
  };
}

function frameIndexAtOrAfter(timeS: number, fps: number): number {
  if (!(fps > 0)) return 0;
  return Math.ceil(timeS * fps - 1e-9);
}

function clampFrameIndex(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

function skipIdleEnds(
  deltas: number[],
  fps: number,
  startFrame: number,
  endFrame: number,
  idleS: number,
): { startFrame: number; endFrame: number } {
  let start = startFrame;
  let end = endFrame;

  while (end > start) {
    const frameCount = end - start;
    const windowDeltas = frameCount <= 1 ? [] : deltas.slice(start, end - 1);
    const scored = computeVisualMetrics({
      deltas: windowDeltas,
      recordingFps: fps,
      frameCount,
    });
    if (scored.freeze_runs.length === 0) break;

    const longRuns = scored.freeze_runs.filter((run) => run.duration_s >= idleS);
    if (longRuns.length === 0) break;

    let changed = false;
    const first = longRuns[0];
    const prefixS = first && fps > 0 ? first.start_frame / fps : Infinity;
    const motionBeforeIdle =
      first !== undefined &&
      scored.large_delta_frames.some(
        (frame) => frame < first.start_frame && fps > 0 && frame / fps > STARTUP_FLASH_S,
      );
    const firstIsTail = first !== undefined && first.end_frame >= frameCount - 1;
    // Leading idle: freeze at t=0, or a long freeze after only a startup flash.
    // A long freeze that already reaches the clip end is trailing, not leading.
    if (
      first &&
      !firstIsTail &&
      (first.start_frame === 0 || (prefixS <= idleS && !motionBeforeIdle))
    ) {
      const nextStart = start + first.end_frame;
      if (nextStart > start && nextStart < end) {
        start = nextStart;
        changed = true;
      }
    }
    if (changed) continue;

    const last = longRuns[longRuns.length - 1];
    const lastFrame = frameCount - 1;
    const gapAfterS = fps > 0 && last ? (lastFrame - last.end_frame) / fps : 0;
    if (last && gapAfterS <= idleS) {
      const nextEnd = start + last.start_frame + 1;
      if (nextEnd < end && nextEnd > start) {
        end = nextEnd;
        changed = true;
      }
    }
    if (!changed) break;
  }

  return { startFrame: start, endFrame: end };
}

/** Numeric-aware order so `frame-2.png` precedes `frame-10.png`. */
export function compareFrameNames(a: string, b: string): number {
  return a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" });
}

export function parseArgs(argv: string[]): CliOptions {
  const options: CliOptions = { help: false, autoSkip: true };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg || arg === "--") continue;
    if (arg === "-h" || arg === "--help") {
      options.help = true;
      continue;
    }
    if (arg === "--no-auto-skip") {
      options.autoSkip = false;
      continue;
    }
    if (arg === "--fps") {
      options.fps = requirePositiveNumber(arg, argv[i + 1]);
      i += 1;
      continue;
    }
    if (arg === "--start-s") {
      options.startS = requireNonNegativeNumber(arg, argv[i + 1]);
      i += 1;
      continue;
    }
    if (arg === "--end-s") {
      options.endS = requirePositiveNumber(arg, argv[i + 1]);
      i += 1;
      continue;
    }
    if (arg === "--idle-s") {
      options.idleS = requireNonNegativeNumber(arg, argv[i + 1]);
      i += 1;
      continue;
    }
    if (arg === "--min-freeze-s") {
      options.minFreezeS = requireNonNegativeNumber(arg, argv[i + 1]);
      i += 1;
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
  if (options.startS !== undefined && options.endS !== undefined && options.endS <= options.startS) {
    throw new Error("--end-s must be greater than --start-s (end is exclusive)");
  }
  return options;
}

function requirePositiveNumber(flag: string, value: string | undefined): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new Error(`${flag} requires a positive number (got ${value ?? "nothing"})`);
  }
  return parsed;
}

function requireNonNegativeNumber(flag: string, value: string | undefined): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0) {
    throw new Error(`${flag} requires a non-negative number (got ${value ?? "nothing"})`);
  }
  return parsed;
}

export function analyzeRecording(
  inputPath: string,
  options: {
    fps?: number;
    startS?: number;
    endS?: number;
    autoSkip?: boolean;
    idleS?: number;
    minFreezeS?: number;
  } = {},
): VisualPerfReport {
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

  return analyzeVisualDeltas({
    deltas,
    recordingFps,
    frameCount: rgbFrames.length,
    startS: options.startS,
    endS: options.endS,
    autoSkip: options.autoSkip,
    idleS: options.idleS,
    minFreezeS: options.minFreezeS,
  });
}

function usageMessage(): string {
  return `analyze-visual-recording.ts — JSON visual-perf report from an MP4 or PNG directory

Usage:
  bun clients/apple/scripts/analyze-visual-recording.ts <path> [--fps N] [--out report.json]
    [--start-s N] [--end-s N] [--idle-s N] [--min-freeze-s N] [--no-auto-skip]

Arguments:
  <path>           MP4 file, or directory of PNG frames (non-PNG files are ignored)

Options:
  --fps N          Override recording fps (PNG directories default to ${DEFAULT_PNG_FPS})
  --start-s N      Keep source frames at t >= N seconds
  --end-s N        Exclusive source end: keep frames with t < N seconds
  --idle-s N       Auto-skip leading/trailing freezes lasting >= N seconds (default ${DEFAULT_IDLE_S})
  --min-freeze-s N Omit freeze_runs shorter than N seconds (default ${DEFAULT_MIN_FREEZE_S})
  --no-auto-skip   Do not trim leading/trailing idle
  --out <path>     Write JSON report to this path (also prints to stdout)
  -h, --help       Show this help

Sampling:
  Downscale to ${SAMPLE_WIDTH}x${SAMPLE_HEIGHT}, Rec.601 luma, mean absolute per-pixel delta.
  Large-delta threshold: ${LARGE_DELTA_THRESHOLD} (same as StreamingFlickerCaptureUITests).
  Freeze threshold: ${FREEZE_THRESHOLD} (reported as freeze_threshold).
  settle_s is the last large-delta timestamp relative to window_start_s, or 0 if none.
  window_start_s / window_end_s are the kept range on the source timeline.

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
    const report = analyzeRecording(options.inputPath, {
      fps: options.fps,
      startS: options.startS,
      endS: options.endS,
      autoSkip: options.autoSkip,
      idleS: options.idleS,
      minFreezeS: options.minFreezeS,
    });
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
