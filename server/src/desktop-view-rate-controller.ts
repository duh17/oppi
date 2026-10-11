/**
 * Transport-neutral live-view rate controller.
 *
 * Window: max(minInFlightFrames × lastFrameBytes, gain × deliveredRate × baseRtt).
 * Ladder drops fps before resolution. Clock is injected.
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

export const DESKTOP_VIEW_WINDOW_GAIN = 2.5;
export const DESKTOP_VIEW_MIN_IN_FLIGHT_FRAMES = 2;
export const DESKTOP_VIEW_HARD_BYTE_CAP = 2 * 1024 * 1024;
export const DESKTOP_VIEW_RTT_SAMPLE_LIMIT = 32;
export const DESKTOP_VIEW_STEP_UP_HOLD_MS = 100;
export const DESKTOP_VIEW_RATE_WINDOW_MS = 1000;

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
  deliveredBps: number;
  inFlightBytes: number;
  windowBytes: number;
};

type InFlightFrame = {
  bytes: number;
  sentAt: number;
};

type AckSample = {
  at: number;
  bytes: number;
};

export class DesktopViewRateController {
  private nextFrameId = 1;
  private level = 0;
  private readonly rttSamples: number[] = [];
  private baseRttMs: number | undefined;
  private readonly inFlight = new Map<number, InFlightFrame>();
  private readonly acks: AckSample[] = [];
  private lastFrameBytes = 0;
  private healthySince: number | undefined;
  private congested = false;
  private sentAny = false;
  private lastScale: number;
  private lastEncodeAt = 0;

  constructor(
    private readonly clock: DesktopViewRateClock,
    private readonly ladder: readonly DesktopViewQualityRung[] = DESKTOP_VIEW_LADDER,
  ) {
    this.lastScale = this.rung().scale;
  }

  onRttSample(rttMs: number): void {
    if (!Number.isFinite(rttMs) || rttMs <= 0) return;
    this.rttSamples.push(rttMs);
    if (this.rttSamples.length > DESKTOP_VIEW_RTT_SAMPLE_LIMIT) {
      this.rttSamples.shift();
    }
    this.baseRttMs = Math.min(...this.rttSamples);
  }

  onFrameSent(frameId: number, bytes: number, sentAt = this.clock.now()): void {
    this.inFlight.set(frameId, { bytes, sentAt });
    this.lastFrameBytes = bytes;
    this.sentAny = true;
  }

  onAck(frameId: number, now = this.clock.now()): void {
    const pending = this.inFlight.get(frameId);
    if (!pending) return;
    this.inFlight.delete(frameId);
    this.acks.push({ at: now, bytes: pending.bytes });
    this.onRttSample(now - pending.sentAt);
  }

  inFlightBytes(): number {
    let total = 0;
    for (const frame of this.inFlight.values()) total += frame.bytes;
    return total;
  }

  windowBytes(now = this.clock.now()): number {
    const estimated = this.estimatedFrameBytes();
    const minWindow = DESKTOP_VIEW_MIN_IN_FLIGHT_FRAMES * estimated;
    const rttSec = (this.baseRttMs ?? 0) / 1000;
    const bdp = DESKTOP_VIEW_WINDOW_GAIN * this.deliveredBps(now) * rttSec;
    return Math.max(minWindow, Math.ceil(bdp));
  }

  shouldEncode(now = this.clock.now()): DesktopViewRateDecision {
    if (this.baseRttMs === undefined) return { kind: "wait" };

    const estimated = this.estimatedFrameBytes();
    const inFlight = this.inFlightBytes();
    if (inFlight + estimated > DESKTOP_VIEW_HARD_BYTE_CAP) {
      return { kind: "close", reason: "hard_cap" };
    }

    const window = this.windowBytes(now);
    const minWindow = DESKTOP_VIEW_MIN_IN_FLIGHT_FRAMES * estimated;
    if (inFlight >= window) {
      // Hitting the 2-frame floor is pipelining, not congestion.
      if (window > minWindow && !this.congested) {
        this.congested = true;
        if (this.level > 0) this.level -= 1;
      }
      this.healthySince = undefined;
      return { kind: "wait" };
    }

    this.congested = false;
    if (this.healthySince === undefined) this.healthySince = now;
    if (now - this.healthySince >= DESKTOP_VIEW_STEP_UP_HOLD_MS) {
      if (this.level < this.ladder.length - 1) {
        this.level += 1;
        this.healthySince = now;
      }
    }

    const rung = this.rung();
    const minInterval = 1000 / rung.fps;
    if (this.lastEncodeAt > 0 && now - this.lastEncodeAt < minInterval) {
      return { kind: "wait", afterMs: minInterval - (now - this.lastEncodeAt) };
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

  snapshot(now = this.clock.now()): DesktopViewRateSnapshot {
    const rung = this.rung();
    return {
      level: rung.level,
      fps: rung.fps,
      scale: rung.scale,
      bitrate: rung.bitrate,
      baseRttMs: this.baseRttMs,
      deliveredBps: this.deliveredBps(now),
      inFlightBytes: this.inFlightBytes(),
      windowBytes: this.windowBytes(now),
    };
  }

  private rung(): DesktopViewQualityRung {
    return (
      this.ladder[this.level] ??
      this.ladder[0] ?? { level: 0, fps: 5, scale: 0.25, bitrate: 250_000 }
    );
  }

  private estimatedFrameBytes(): number {
    if (this.lastFrameBytes > 0) return this.lastFrameBytes;
    const rung = this.rung();
    return Math.max(1, Math.ceil(rung.bitrate / 8 / rung.fps));
  }

  private deliveredBps(now: number): number {
    const start = now - DESKTOP_VIEW_RATE_WINDOW_MS;
    let bytes = 0;
    let i = 0;
    while (i < this.acks.length) {
      const sample = this.acks[i];
      if (!sample || sample.at >= start) break;
      i += 1;
    }
    if (i > 0) this.acks.splice(0, i);
    for (const sample of this.acks) bytes += sample.bytes;
    if (bytes === 0) return 0;
    const spanMs = Math.max(1, now - (this.acks[0]?.at ?? now));
    const windowMs = Math.min(DESKTOP_VIEW_RATE_WINDOW_MS, spanMs);
    return (bytes * 1000) / windowMs;
  }
}
