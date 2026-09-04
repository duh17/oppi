import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import {
  FREEZE_THRESHOLD,
  HONESTY_NOTE,
  LARGE_DELTA_THRESHOLD,
  averageAbsoluteDelta,
  compareFrameNames,
  computeVisualMetrics,
  parseArgs,
} from "./analyze-visual-recording";

const script = join(import.meta.dir, "analyze-visual-recording.ts");

describe("analyze-visual-recording metrics", () => {
  test("average absolute delta is the mean of per-pixel luma differences", () => {
    const previous = Uint8Array.of(10, 10, 10);
    const next = Uint8Array.of(20, 0, 10);
    expect(averageAbsoluteDelta(previous, next)).toBeCloseTo(20 / 3);
  });

  test("identical luma planes have zero average delta", () => {
    const frame = Uint8Array.of(40, 80, 120, 160);
    expect(averageAbsoluteDelta(frame, frame)).toBe(0);
  });

  test("treats 18 as not large and values above 18 as large", () => {
    const report = computeVisualMetrics({
      deltas: [17.9, 18, 18.1, 19],
      recordingFps: 10,
    });
    expect(LARGE_DELTA_THRESHOLD).toBe(18);
    expect(report.large_delta_threshold).toBe(18);
    expect(report.large_delta_frames).toEqual([3, 4]);
    expect(report.max_average_delta).toBe(19);
    expect(report.frame_count).toBe(5);
  });

  test("settle_s is 0 when no large deltas occur", () => {
    const report = computeVisualMetrics({
      deltas: [0, 1, 18, 4],
      recordingFps: 30,
    });
    expect(report.settle_s).toBe(0);
    expect(report.large_delta_frames).toEqual([]);
  });

  test("settle_s is the timestamp of the last large delta", () => {
    const report = computeVisualMetrics({
      deltas: [0, 25, 0, 40, 0],
      recordingFps: 10,
    });
    // deltas[i] compares frame i → i+1; last large is frame 4 at 4/10s.
    expect(report.large_delta_frames).toEqual([2, 4]);
    expect(report.settle_s).toBe(0.4);
    expect(report.duration_s).toBe(0.6);
    expect(report.recording_fps).toBe(10);
  });

  test("freeze_runs are consecutive stretches at or below the freeze threshold", () => {
    const report = computeVisualMetrics({
      deltas: [0, 0.5, 25, 0, 0.2, 19, 0],
      recordingFps: 10,
    });
    expect(FREEZE_THRESHOLD).toBe(1);
    expect(report.freeze_threshold).toBe(1);
    expect(report.freeze_runs).toEqual([
      { start_frame: 0, end_frame: 2, frame_count: 3, duration_s: 0.2 },
      { start_frame: 3, end_frame: 5, frame_count: 3, duration_s: 0.2 },
      { start_frame: 6, end_frame: 7, frame_count: 2, duration_s: 0.1 },
    ]);
  });

  test("a fully still clip is one freeze run and never settles from a jump", () => {
    const report = computeVisualMetrics({
      deltas: [0, 0, 0],
      recordingFps: 30,
      frameCount: 4,
    });
    expect(report.freeze_runs).toEqual([
      { start_frame: 0, end_frame: 3, frame_count: 4, duration_s: 0.1 },
    ]);
    expect(report.settle_s).toBe(0);
    expect(report.max_average_delta).toBe(0);
  });

  test("includes the honesty note that 30fps H.264 cannot prove 8.33ms hitches", () => {
    const report = computeVisualMetrics({ deltas: [], recordingFps: 30, frameCount: 1 });
    expect(report.honesty_note).toContain("8.33ms");
    expect(report.honesty_note.toLowerCase()).toContain("30fps");
    expect(HONESTY_NOTE).toContain("8.33ms");
  });

  test("PNG names sort numerically so frame-10 follows frame-2", () => {
    const names = ["frame-10.png", "frame-2.png", "frame-1.png"];
    expect([...names].sort(compareFrameNames)).toEqual([
      "frame-1.png",
      "frame-2.png",
      "frame-10.png",
    ]);
  });

  test("empty input reports zeros rather than NaN", () => {
    const report = computeVisualMetrics({ deltas: [], recordingFps: 30, frameCount: 0 });
    expect(report.frame_count).toBe(0);
    expect(report.duration_s).toBe(0);
    expect(report.max_average_delta).toBe(0);
    expect(report.large_delta_frames).toEqual([]);
    expect(report.freeze_runs).toEqual([]);
    expect(report.settle_s).toBe(0);
  });
});

describe("analyze-visual-recording CLI", () => {
  test("parseArgs reads path, --fps, and --out", () => {
    expect(parseArgs(["clip.mp4", "--fps", "12.5", "--out", "report.json"])).toEqual({
      help: false,
      inputPath: "clip.mp4",
      fps: 12.5,
      outPath: "report.json",
    });
  });

  test("parseArgs treats -h and --help as help", () => {
    expect(parseArgs(["--help"]).help).toBe(true);
    expect(parseArgs(["-h"]).help).toBe(true);
  });

  test("prints usage and exits non-zero when path is missing", () => {
    const result = spawnSync("bun", [script], { encoding: "utf8" });
    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toMatch(/Usage:/i);
  });

  test("prints usage on --help", () => {
    const result = spawnSync("bun", [script, "--help"], { encoding: "utf8" });
    expect(result.status).toBe(0);
    expect(`${result.stdout}${result.stderr}`).toMatch(/Usage:/i);
    expect(`${result.stdout}${result.stderr}`).toMatch(/--fps/);
  });
});
