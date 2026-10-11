/**
 * Transport-neutral live-view rate controller.
 *
 * Window: max(2 × frameBytes, 1.5 × commandedBitrate/8 × baseRtt).
 * Ping RTT is the only baseRtt source (10 s windowed min), and only from pings
 * marked idle-at-send. A ping sent behind queued frames never updates base RTT.
 * If the newest idle sample is older than 10 s, shouldEncode waits until one
 * returns. Down-step uses the minimum frame RTT over max(1 s, 2 × baseRtt).
 * Ladder drops fps before resolution.
 */

export type DesktopViewQualityRung = {
  level: number;
  fps: number;
  scale: number;
  bitrate: number;
};

/** Frame rate first, then spatial scale. 4:2:0 only (chroma is encoder-side). */
export const DESKTOP_VIEW_LADDER: readonly DesktopViewQualityRung[] = [
  { level: 0, fps: 5, scale: 0.25, bitrate: 250_000 },
  { level: 1, fps: 10, scale: 0.25, bitrate: 500_000 },
  { level: 2, fps: 15, scale: 0.25, bitrate: 800_000 },
  { level: 3, fps: 24, scale: 0.25, bitrate: 1_200_000 },
  { level: 4, fps: 30, scale: 0.25, bitrate: 1_800_000 },
  { level: 5, fps: 30, scale: 0.5, bitrate: 3_000_000 },
  { level: 6, fps: 30, scale: 0.75, bitrate: 5_000_000 },
  { level: 7, fps: 30, scale: 1.0, bitrate: 8_000_000 },
];

export const DESKTOP_VIEW_WINDOW_GAIN = 1.5;
export const DESKTOP_VIEW_MIN_IN_FLIGHT_FRAMES = 2;
export const DESKTOP_VIEW_HARD_BYTE_CAP = 2 * 1024 * 1024;
export const DESKTOP_VIEW_PING_RTT_WINDOW_MS = 10_000;
export const DESKTOP_VIEW_STEP_UP_HOLD_MS = 1_000;
export const DESKTOP_VIEW_STEP_UP_HOLD_MAX_MS = 8_000;
export const DESKTOP_VIEW_CLEAN_RESET_MS = 5_000;
export const DESKTOP_VIEW_RAMP_MIN_MS = 50;

export type DesktopViewEncodeCommand = {
  frameId: number;
  bitrate: number;
  fps: number;
  scale: number;
  keyframe: boolean;
  level: number;
};

export type DesktopViewRateDecision =
  | { kind: "wait"; afterMs?: number }
  | { kind: "encode"; command: DesktopViewEncodeCommand }
  | { kind: "close"; reason: "hard_cap" };

export type DesktopViewRateClock = {
  now: () => number;
};

export type DesktopViewRateSnapshot = {
  level: number;
  fps: number;
  scale: number;
  bitrate: number;
  baseRttMs: number | undefined;
  inFlightBytes: number;
  windowBytes: number;
  stepUpHoldMs: number;
};

type InFlightFrame = {
  bytes: number;
  sentAt: number;
  rttSample: boolean;
};

type PingSample = {
  at: number;
  rtt: number;
};

type FrameRttSample = {
  at: number;
  rtt: number;
};

export class DesktopViewRateController {
  private nextFrameId = 1;
  private level = 0;
  private readonly pingRtts: PingSample[] = [];
  private baseRttMs: number | undefined;
  private lastIdleSampleAt: number | undefined;
  private readonly inFlight = new Map<number, InFlightFrame>();
  private readonly frameRtts: FrameRttSample[] = [];
  private healthySince: number | undefined;
  private sentAny = false;
  private lastScale: number;
  private lastEncodeAt = 0;
  private lastStepUpAt: number | undefined;
  private stepUpHoldMs = DESKTOP_VIEW_STEP_UP_HOLD_MS;
  private lastStepDownAt: number | undefined;
  private lastCongestedAt: number | undefined;
  private hasDownStepped = false;

  constructor(
    private readonly clock: DesktopViewRateClock,
    private readonly ladder: readonly DesktopViewQualityRung[] = DESKTOP_VIEW_LADDER,
  ) {
    this.lastScale = this.rung().scale;
  }

  onRttSample(rttMs: number, now = this.clock.now(), idleAtSend = true): void {
    if (!idleAtSend) return;
    if (!Number.isFinite(rttMs) || rttMs <= 0) return;
    this.pingRtts.push({ at: now, rtt: rttMs });
    this.lastIdleSampleAt = now;
    const start = now - DESKTOP_VIEW_PING_RTT_WINDOW_MS;
    while (this.pingRtts.length > 0) {
      const oldest = this.pingRtts[0];
      if (!oldest || oldest.at >= start) break;
      this.pingRtts.shift();
    }
    this.baseRttMs = Math.min(...this.pingRtts.map((sample) => sample.rtt));
  }

  onFrameSent(frameId: number, bytes: number, sentAt = this.clock.now()): void {
    const pBytes = this.pFrameBytes();
    const rttSample = bytes <= 2 * pBytes;
    this.inFlight.set(frameId, { bytes, sentAt, rttSample });
    this.sentAny = true;
  }

  onAck(frameId: number, now = this.clock.now()): void {
    const pending = this.inFlight.get(frameId);
    if (!pending) return;
    this.inFlight.delete(frameId);
    const base = this.baseRttMs;
    if (base === undefined || !pending.rttSample) return;
    const frameRtt = now - pending.sentAt;
    this.frameRtts.push({ at: now, rtt: frameRtt });
    const observeMs = Math.max(1_000, 2 * base);
    while (this.frameRtts.length > 0) {
      const oldest = this.frameRtts[0];
      if (!oldest || now - oldest.at <= observeMs) break;
      this.frameRtts.shift();
    }
    const threshold = base + Math.max(50, 0.5 * base);
    const oldest = this.frameRtts[0];
    const span = oldest ? now - oldest.at : 0;
    const minRtt = this.frameRtts.reduce(
      (min, sample) => Math.min(min, sample.rtt),
      Number.POSITIVE_INFINITY,
    );
    if (this.frameRtts.length >= 2 && span >= observeMs * 0.8 && minRtt > threshold) {
      this.lastCongestedAt = now;
      this.healthySince = undefined;
      if (this.lastStepDownAt === undefined || now - this.lastStepDownAt >= base) {
        if (this.level > 0) {
          this.level -= 1;
          this.stepUpHoldMs = Math.min(DESKTOP_VIEW_STEP_UP_HOLD_MAX_MS, this.stepUpHoldMs * 2);
          this.hasDownStepped = true;
          this.frameRtts.length = 0;
        }
        this.lastStepDownAt = now;
      }
      return;
    }
    if (
      this.lastCongestedAt === undefined ||
      now - this.lastCongestedAt >= DESKTOP_VIEW_CLEAN_RESET_MS
    ) {
      this.stepUpHoldMs = DESKTOP_VIEW_STEP_UP_HOLD_MS;
    }
  }

  inFlightBytes(): number {
    let total = 0;
    for (const frame of this.inFlight.values()) total += frame.bytes;
    return total;
  }

  windowBytes(): number {
    const estimated = this.estimatedFrameBytes();
    const minWindow = DESKTOP_VIEW_MIN_IN_FLIGHT_FRAMES * estimated;
    const rttSec = (this.baseRttMs ?? 0) / 1000;
    const commandedBps = this.rung().bitrate / 8;
    const bdp = DESKTOP_VIEW_WINDOW_GAIN * commandedBps * rttSec;
    return Math.max(minWindow, Math.ceil(bdp));
  }

  shouldEncode(now = this.clock.now(), allowEncode = true): DesktopViewRateDecision {
    if (this.baseRttMs === undefined) return { kind: "wait" };
    if (
      this.lastIdleSampleAt === undefined ||
      now - this.lastIdleSampleAt > DESKTOP_VIEW_PING_RTT_WINDOW_MS
    ) {
      return { kind: "wait" };
    }

    const estimated = this.estimatedFrameBytes();
    const inFlight = this.inFlightBytes();
    if (inFlight + estimated > DESKTOP_VIEW_HARD_BYTE_CAP) {
      return { kind: "close", reason: "hard_cap" };
    }

    const window = this.windowBytes();
    if (inFlight < window) this.maybeStepUp(now);
    if (!allowEncode || inFlight >= window) {
      return { kind: "wait", afterMs: this.wakeMs(now) };
    }

    const rung = this.rung();
    const minInterval = 1000 / rung.fps;
    if (this.lastEncodeAt > 0 && now - this.lastEncodeAt < minInterval) {
      const fpsWait = minInterval - (now - this.lastEncodeAt);
      return { kind: "wait", afterMs: Math.min(fpsWait, this.wakeMs(now)) };
    }
    const keyframe = !this.sentAny || rung.scale !== this.lastScale;
    this.lastScale = rung.scale;
    this.lastEncodeAt = now;
    const frameId = this.nextFrameId;
    this.nextFrameId += 1;
    return {
      kind: "encode",
      command: {
        frameId,
        bitrate: rung.bitrate,
        fps: rung.fps,
        scale: rung.scale,
        keyframe,
        level: rung.level,
      },
    };
  }

  snapshot(): DesktopViewRateSnapshot {
    const rung = this.rung();
    return {
      level: rung.level,
      fps: rung.fps,
      scale: rung.scale,
      bitrate: rung.bitrate,
      baseRttMs: this.baseRttMs,
      inFlightBytes: this.inFlightBytes(),
      windowBytes: this.windowBytes(),
      stepUpHoldMs: this.stepUpHoldMs,
    };
  }

  private maybeStepUp(now: number): void {
    if (this.level >= this.ladder.length - 1) return;
    if (!this.hasDownStepped) {
      const interval = Math.max(
        DESKTOP_VIEW_RAMP_MIN_MS,
        this.baseRttMs ?? DESKTOP_VIEW_RAMP_MIN_MS,
      );
      if (this.lastStepUpAt === undefined) {
        this.lastStepUpAt = now;
        return;
      }
      if (now - this.lastStepUpAt >= interval) {
        this.level += 1;
        this.lastStepUpAt = now;
      }
      return;
    }
    if (this.healthySince === undefined) this.healthySince = now;
    if (now - this.healthySince >= this.stepUpHoldMs) {
      this.level += 1;
      this.healthySince = now;
    }
  }

  private wakeMs(now: number): number {
    if (!this.hasDownStepped) {
      const interval = Math.max(
        DESKTOP_VIEW_RAMP_MIN_MS,
        this.baseRttMs ?? DESKTOP_VIEW_RAMP_MIN_MS,
      );
      if (this.lastStepUpAt === undefined) return interval;
      return Math.max(1, interval - (now - this.lastStepUpAt));
    }
    const holdLeft =
      this.healthySince === undefined
        ? this.stepUpHoldMs
        : this.stepUpHoldMs - (now - this.healthySince);
    return Math.max(1, holdLeft);
  }

  private rung(): DesktopViewQualityRung {
    return (
      this.ladder[this.level] ??
      this.ladder[0] ?? { level: 0, fps: 5, scale: 0.25, bitrate: 250_000 }
    );
  }

  private estimatedFrameBytes(): number {
    return this.pFrameBytes();
  }

  private pFrameBytes(): number {
    const rung = this.rung();
    return Math.max(1, Math.ceil(rung.bitrate / 8 / rung.fps));
  }
}
