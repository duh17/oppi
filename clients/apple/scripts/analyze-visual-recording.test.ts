import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import {
  FREEZE_THRESHOLD,
  HONESTY_NOTE,
  LARGE_DELTA_THRESHOLD,
  analyzeVisualDeltas,
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
      autoSkip: true,
    });
  });

  test("parseArgs reads window, idle, freeze, and --no-auto-skip flags", () => {
    expect(
      parseArgs([
        "clip.mp4",
        "--start-s",
        "2",
        "--end-s",
        "10",
        "--idle-s",
        "3",
        "--min-freeze-s",
        "0.5",
        "--no-auto-skip",
      ]),
    ).toEqual({
      help: false,
      inputPath: "clip.mp4",
      startS: 2,
      endS: 10,
      idleS: 3,
      minFreezeS: 0.5,
      autoSkip: false,
    });
  });

  test("parseArgs rejects --end-s that is not greater than --start-s", () => {
    expect(() => parseArgs(["clip.mp4", "--start-s", "5", "--end-s", "5"])).toThrow(/end-s/i);
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
    const text = `${result.stdout}${result.stderr}`;
    expect(text).toMatch(/Usage:/i);
    expect(text).toMatch(/--fps/);
    expect(text).toMatch(/--start-s/);
    expect(text).toMatch(/--end-s/);
    expect(text).toMatch(/exclusive/i);
    expect(text).toMatch(/--idle-s/);
    expect(text).toMatch(/--min-freeze-s/);
    expect(text).toMatch(/--no-auto-skip/);
    expect(text).toMatch(/window_start_s/);
    expect(text).toMatch(/settle_s/);
  });
});

/** Long leading freeze, UI motion, tiny mid freeze, trailing freeze. 10 fps. */
function flickerLikeDeltas(): number[] {
  return [
    ...Array(30).fill(0),
    25,
    5,
    40,
    0.2,
    0.2,
    0.2,
    19,
    3,
    ...Array(25).fill(0),
  ];
}

describe("analyze-visual-recording windowing", () => {
  test("--end-s is exclusive on the source timeline", () => {
    const deltas = Array.from({ length: 20 }, (_, i) => (i === 14 ? 40 : 5));
    const report = analyzeVisualDeltas({
      deltas,
      recordingFps: 10,
      startS: 0.5,
      endS: 1.5,
      autoSkip: false,
      minFreezeS: 0,
    });
    // Frames with t in [0.5, 1.5): 5..14. Delta 14 (frame 14→15 at t=1.5) is excluded.
    expect(report.window_start_s).toBe(0.5);
    expect(report.window_end_s).toBe(1.5);
    expect(report.frame_count).toBe(10);
    expect(report.large_delta_frames).toEqual([]);
    expect(report.settle_s).toBe(0);
  });

  test("explicit slice includes a large delta just inside the exclusive end", () => {
    const deltas = Array.from({ length: 20 }, (_, i) => (i === 13 ? 40 : 5));
    const report = analyzeVisualDeltas({
      deltas,
      recordingFps: 10,
      startS: 0.5,
      endS: 1.5,
      autoSkip: false,
    });
    // Delta 13 is frame 13→14, relative frame 9, timestamp 0.9s from window start.
    expect(report.large_delta_frames).toEqual([9]);
    expect(report.settle_s).toBe(0.9);
  });

  test("auto-skip drops leading and trailing idle freeze and reports settle relative to the window", () => {
    const report = analyzeVisualDeltas({
      deltas: flickerLikeDeltas(),
      recordingFps: 10,
    });
    expect(report.window_start_s).toBe(3);
    expect(report.window_end_s).toBe(3.9);
    expect(report.frame_count).toBe(9);
    expect(report.duration_s).toBe(0.9);
    expect(report.large_delta_frames).toEqual([1, 3, 7]);
    expect(report.settle_s).toBe(0.7);
    expect(report.freeze_run_count_all).toBe(1);
    expect(report.freeze_runs).toEqual([]);
    expect(report.honesty_note).toBe(HONESTY_NOTE);
  });

  test("--no-auto-skip keeps idle ends; settle_s stays on the source start", () => {
    const report = analyzeVisualDeltas({
      deltas: flickerLikeDeltas(),
      recordingFps: 10,
      autoSkip: false,
    });
    expect(report.window_start_s).toBe(0);
    expect(report.window_end_s).toBe(6.4);
    expect(report.settle_s).toBe(3.7);
    expect(report.freeze_runs.map((run) => run.duration_s)).toEqual([3, 2.5]);
    expect(report.freeze_run_count_all).toBe(3);
  });

  test("tiny freeze runs are omitted from freeze_runs when shorter than --min-freeze-s", () => {
    const report = analyzeVisualDeltas({
      deltas: flickerLikeDeltas(),
      recordingFps: 10,
      autoSkip: false,
      minFreezeS: 1,
    });
    expect(report.freeze_run_count_all).toBe(3);
    expect(report.freeze_runs).toEqual([
      { start_frame: 0, end_frame: 30, frame_count: 31, duration_s: 3 },
      { start_frame: 38, end_frame: 63, frame_count: 26, duration_s: 2.5 },
    ]);
  });

  test("a still clip is kept when auto-skip would drop everything", () => {
    const report = analyzeVisualDeltas({
      deltas: [0, 0, 0, 0, 0],
      recordingFps: 1,
    });
    expect(report.window_start_s).toBe(0);
    expect(report.window_end_s).toBe(6);
    expect(report.frame_count).toBe(6);
    expect(report.settle_s).toBe(0);
    expect(report.freeze_runs).toEqual([
      { start_frame: 0, end_frame: 5, frame_count: 6, duration_s: 5 },
    ]);
  });

  test("short edge freeze below --idle-s is not skipped", () => {
    const report = analyzeVisualDeltas({
      deltas: [0, 0, 25, 40, 0, 0],
      recordingFps: 10,
      idleS: 2,
    });
    expect(report.window_start_s).toBe(0);
    expect(report.window_end_s).toBe(0.7);
    expect(report.settle_s).toBe(0.4);
  });

  test("auto-skip ignores a short startup blip before long idle", () => {
    const report = analyzeVisualDeltas({
      deltas: [25, ...Array(30).fill(0), 40, 5, ...Array(25).fill(0)],
      recordingFps: 10,
    });
    expect(report.window_start_s).toBe(3.1);
    expect(report.window_end_s).toBe(3.4);
    expect(report.large_delta_frames).toEqual([1]);
    expect(report.settle_s).toBe(0.1);
  });

  test("auto-skip still runs inside an explicit --start-s/--end-s slice", () => {
    const report = analyzeVisualDeltas({
      deltas: flickerLikeDeltas(),
      recordingFps: 10,
      startS: 1,
      endS: 5.5,
    });
    // Slice [1, 5.5) still starts on the compile freeze, so idle-skip moves the
    // window to 3s. Trailing freeze inside the slice is only 1.6s (< idle 2s).
    expect(report.window_start_s).toBe(3);
    expect(report.window_end_s).toBe(5.5);
    expect(report.settle_s).toBe(0.7);
  });
});
