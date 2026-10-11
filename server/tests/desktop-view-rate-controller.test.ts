import { describe, expect, it } from "vitest";

import {
  DESKTOP_VIEW_HARD_BYTE_CAP,
  DESKTOP_VIEW_LADDER,
  DESKTOP_VIEW_MIN_IN_FLIGHT_FRAMES,
  DESKTOP_VIEW_PING_RTT_WINDOW_MS,
  DESKTOP_VIEW_RAMP_MIN_MS,
  DESKTOP_VIEW_STEP_UP_HOLD_MS,
  DESKTOP_VIEW_WINDOW_GAIN,
  DesktopViewRateController,
} from "../src/desktop-view-rate-controller.js";

class FakeClock {
  nowMs = 1_000;
  now = (): number => this.nowMs;
}

function seeded(clock: FakeClock, rttMs = 20): DesktopViewRateController {
  const controller = new DesktopViewRateController({ now: clock.now });
  controller.onRttSample(rttMs, clock.nowMs, true);
  return controller;
}

function pFrameBytes(controller: DesktopViewRateController): number {
  const snap = controller.snapshot();
  return Math.max(1, Math.ceil(snap.bitrate / 8 / snap.fps));
}

function rampHealthy(
  controller: DesktopViewRateController,
  clock: FakeClock,
  rttMs = 5,
): void {
  const origin = clock.nowMs;
  for (let step = 0; step <= 20 && controller.snapshot().level < 7; step += 1) {
    clock.nowMs = origin + step * DESKTOP_VIEW_RAMP_MIN_MS;
    const decision = controller.shouldEncode();
    if (decision.kind !== "encode") continue;
    const bytes = pFrameBytes(controller);
    controller.onFrameSent(decision.command.frameId, bytes, clock.nowMs);
    clock.nowMs += rttMs;
    controller.onAck(decision.command.frameId);
  }
}

function encodeOrThrow(controller: DesktopViewRateController) {
  const decision = controller.shouldEncode();
  if (decision.kind !== "encode")
    throw new Error(`expected encode, got ${JSON.stringify(decision)}`);
  return decision;
}

function floodSlow(
  controller: DesktopViewRateController,
  clock: FakeClock,
  rttMs: number,
  durationMs: number,
  idlePingRttMs = 20,
): void {
  const start = clock.nowMs;
  while (clock.nowMs - start < durationMs) {
    clock.nowMs += 40;
    controller.onRttSample(idlePingRttMs, clock.nowMs, true);
    const decision = controller.shouldEncode();
    if (decision.kind !== "encode") continue;
    controller.onFrameSent(decision.command.frameId, 1_000, clock.nowMs);
    clock.nowMs += rttMs;
    controller.onAck(decision.command.frameId);
  }
}

describe("DesktopViewRateController", () => {
  it("waits for a ping RTT before the first encode", () => {
    const clock = new FakeClock();
    const controller = new DesktopViewRateController({ now: clock.now });
    expect(controller.shouldEncode()).toEqual({ kind: "wait" });
    controller.onRttSample(40);
    const first = controller.shouldEncode();
    expect(first.kind).toBe("encode");
    if (first.kind !== "encode") return;
    expect(first.command.frameId).toBe(1);
    expect(first.command.keyframe).toBe(true);
    expect(first.command.level).toBe(0);
    expect(first.command.fps).toBe(DESKTOP_VIEW_LADDER[0]!.fps);
  });

  it("keeps a min-two-frame window and does not grow in-flight without acks", () => {
    const clock = new FakeClock();
    const controller = seeded(clock);
    const first = controller.shouldEncode();
    expect(first.kind).toBe("encode");
    if (first.kind !== "encode") return;
    const pBytes = Math.ceil(DESKTOP_VIEW_LADDER[0]!.bitrate / 8 / DESKTOP_VIEW_LADDER[0]!.fps);
    controller.onFrameSent(first.command.frameId, pBytes);
    expect(controller.shouldEncode().kind).toBe("wait");

    clock.nowMs += 1000 / DESKTOP_VIEW_LADDER[0]!.fps;
    const second = controller.shouldEncode();
    expect(second.kind).toBe("encode");
    if (second.kind !== "encode") return;
    controller.onFrameSent(second.command.frameId, pBytes);

    expect(controller.inFlightBytes()).toBe(2 * pBytes);
    expect(controller.windowBytes()).toBe(DESKTOP_VIEW_MIN_IN_FLIGHT_FRAMES * pBytes);
    expect(controller.shouldEncode().kind).toBe("wait");
  });

  it("raises one rung per ramp interval even during the fps wait", () => {
    const clock = new FakeClock();
    const controller = seeded(clock, 20);
    const first = controller.shouldEncode();
    expect(first.kind).toBe("encode");
    if (first.kind !== "encode") return;
    expect(first.command.level).toBe(0);
    controller.onFrameSent(first.command.frameId, 1_000);
    clock.nowMs += 5;
    controller.onAck(first.command.frameId);

    clock.nowMs = 1_000 + DESKTOP_VIEW_RAMP_MIN_MS;
    const waiting = controller.shouldEncode();
    expect(waiting.kind).toBe("wait");
    if (waiting.kind !== "wait") return;
    expect(waiting.afterMs).toBeLessThanOrEqual(DESKTOP_VIEW_RAMP_MIN_MS);
    expect(controller.snapshot().level).toBe(1);

    for (let level = 2; level <= 7; level += 1) {
      clock.nowMs = 1_000 + level * DESKTOP_VIEW_RAMP_MIN_MS;
      const decision = controller.shouldEncode();
      if (decision.kind === "encode") {
        controller.onFrameSent(decision.command.frameId, 1_000);
        clock.nowMs += 5;
        controller.onAck(decision.command.frameId);
      }
      expect(controller.snapshot().level).toBe(level);
    }
    expect(clock.nowMs - 1_000).toBeLessThanOrEqual(1_000);
  });

  it("does not reset the step-up clock when the window is full", () => {
    const clock = new FakeClock();
    const controller = seeded(clock, 20);
    const first = encodeOrThrow(controller);
    controller.onFrameSent(first.command.frameId, 8_000);
    clock.nowMs += 200;
    const second = encodeOrThrow(controller);
    controller.onFrameSent(second.command.frameId, 8_000);
    expect(controller.shouldEncode().kind).toBe("wait");
    const levelWhileFull = controller.snapshot().level;

    clock.nowMs += 3 * DESKTOP_VIEW_RAMP_MIN_MS;
    expect(controller.shouldEncode().kind).toBe("wait");
    expect(controller.snapshot().level).toBe(levelWhileFull);

    clock.nowMs += 10;
    controller.onAck(first.command.frameId);
    const afterOpen = controller.shouldEncode();
    expect(afterOpen.kind).toBe("encode");
    if (afterOpen.kind !== "encode") return;
    expect(afterOpen.command.level).toBeGreaterThan(levelWhileFull);
  });

  it("does not down-step from one slow frame when the window min RTT is healthy", () => {
    const clock = new FakeClock();
    const controller = seeded(clock, 20);
    const observeMs = Math.max(1_000, 2 * 20);
    let nextId = 0;
    const sendAck = (rtt: number): void => {
      clock.nowMs += 1000 / 30;
      const decision = controller.shouldEncode();
      if (decision.kind !== "encode") return;
      nextId = decision.command.frameId;
      controller.onFrameSent(nextId, 1_000, clock.nowMs);
      clock.nowMs += rtt;
      controller.onAck(nextId);
    };
    sendAck(10);
    for (let i = 0; i < 12; i += 1) sendAck(10);
    clock.nowMs += 200;
    sendAck(250);
    expect(clock.nowMs - 1_000).toBeGreaterThanOrEqual(observeMs);
    expect(controller.snapshot().level).toBeGreaterThan(0);
    const levelAfterStall = controller.snapshot().level;
    clock.nowMs += 20;
    sendAck(10);
    expect(controller.snapshot().level).toBe(levelAfterStall);
  });

  it("down-steps when the min frame RTT over the observe window stays above the threshold", () => {
    const clock = new FakeClock();
    const controller = seeded(clock, 20);
    const first = encodeOrThrow(controller);
    controller.onFrameSent(first.command.frameId, 1_000, clock.nowMs);
    clock.nowMs += 10;
    controller.onAck(first.command.frameId);
    clock.nowMs += 1_050;
    floodSlow(controller, clock, 120, 1_600);
    const afterFirstDown = controller.snapshot().level;
    expect(afterFirstDown).toBeLessThan(7);
    clock.nowMs += 5;
    floodSlow(controller, clock, 120, 40);
    expect(controller.snapshot().level).toBe(afterFirstDown);
  });

  it("doubles the hold only when the level actually decreases", () => {
    const clock = new FakeClock();
    const controller = seeded(clock, 20);
    expect(controller.snapshot().stepUpHoldMs).toBe(DESKTOP_VIEW_STEP_UP_HOLD_MS);
    const first = encodeOrThrow(controller);
    controller.onFrameSent(first.command.frameId, 1_000, clock.nowMs);
    clock.nowMs += 10;
    controller.onAck(first.command.frameId);
    clock.nowMs += 1_050;
    floodSlow(controller, clock, 120, 1_600);
    expect(controller.snapshot().level).toBeLessThan(7);
    expect(controller.snapshot().stepUpHoldMs).toBe(2 * DESKTOP_VIEW_STEP_UP_HOLD_MS);

    let drops = 0;
    while (controller.snapshot().level > 0 && drops < 10) {
      drops += 1;
      clock.nowMs += 1_050;
      floodSlow(controller, clock, 120, 1_600);
    }
    expect(controller.snapshot().level).toBe(0);
    const hold = controller.snapshot().stepUpHoldMs;
    expect(hold).toBeGreaterThan(DESKTOP_VIEW_STEP_UP_HOLD_MS);
    clock.nowMs += 1_050;
    floodSlow(controller, clock, 120, 1_050);
    expect(controller.snapshot().level).toBe(0);
    expect(controller.snapshot().stepUpHoldMs).toBe(hold);
  });

  it("closes instead of exceeding the hard byte cap", () => {
    const clock = new FakeClock();
    const controller = seeded(clock);
    const first = controller.shouldEncode();
    expect(first.kind).toBe("encode");
    if (first.kind !== "encode") return;
    controller.onFrameSent(first.command.frameId, DESKTOP_VIEW_HARD_BYTE_CAP);
    expect(controller.shouldEncode()).toEqual({ kind: "close", reason: "hard_cap" });
  });

  it("sizes the window from commanded bitrate × RTT, not ack rate", () => {
    const clock = new FakeClock();
    const controller = seeded(clock, 20);
    const first = encodeOrThrow(controller);
    const pBytes = Math.ceil(DESKTOP_VIEW_LADDER[0]!.bitrate / 8 / DESKTOP_VIEW_LADDER[0]!.fps);
    controller.onFrameSent(first.command.frameId, pBytes, clock.nowMs);
    clock.nowMs += 20;
    controller.onAck(first.command.frameId);
    const snap = controller.snapshot();
    const commandedBps = DESKTOP_VIEW_LADDER[0]!.bitrate / 8;
    const bdp = Math.ceil(DESKTOP_VIEW_WINDOW_GAIN * commandedBps * (20 / 1000));
    expect(snap.windowBytes).toBe(Math.max(DESKTOP_VIEW_MIN_IN_FLIGHT_FRAMES * pBytes, bdp));
  });

  it("does not raise base RTT from pings sent while frames are queued", () => {
    const clock = new FakeClock();
    const controller = seeded(clock, 20);
    const first = encodeOrThrow(controller);
    const bytes = pFrameBytes(controller);
    controller.onFrameSent(first.command.frameId, bytes, clock.nowMs);
    clock.nowMs += 1000 / DESKTOP_VIEW_LADDER[0]!.fps;
    const second = encodeOrThrow(controller);
    controller.onFrameSent(second.command.frameId, bytes, clock.nowMs);
    expect(controller.inFlightBytes()).toBeGreaterThan(bytes);

    clock.nowMs += DESKTOP_VIEW_PING_RTT_WINDOW_MS + 1;
    controller.onRttSample(400, clock.nowMs, false);
    expect(controller.snapshot().baseRttMs).toBe(20);
    expect(controller.shouldEncode().kind).toBe("wait");
  });

  it("pauses encodes when the idle sample is stale until an idle ping returns", () => {
    const clock = new FakeClock();
    const controller = seeded(clock, 20);
    const first = encodeOrThrow(controller);
    controller.onFrameSent(first.command.frameId, 1_000, clock.nowMs);
    clock.nowMs += 10;
    controller.onAck(first.command.frameId);

    clock.nowMs += DESKTOP_VIEW_PING_RTT_WINDOW_MS + 1;
    expect(controller.shouldEncode()).toEqual({ kind: "wait" });

    controller.onRttSample(400, clock.nowMs, false);
    expect(controller.shouldEncode()).toEqual({ kind: "wait" });
    expect(controller.snapshot().baseRttMs).toBe(20);

    controller.onRttSample(22, clock.nowMs, true);
    expect(controller.shouldEncode().kind).toBe("encode");
  });

  it("down-steps a too-high rung within a bounded time once idle sampling resumes", () => {
    const clock = new FakeClock();
    const controller = seeded(clock, 20);
    rampHealthy(controller, clock, 5);
    expect(controller.snapshot().level).toBe(7);

    const bytes = pFrameBytes(controller);
    clock.nowMs += 40;
    const queuedA = encodeOrThrow(controller);
    controller.onFrameSent(queuedA.command.frameId, bytes, clock.nowMs);
    clock.nowMs += 40;
    const queuedB = encodeOrThrow(controller);
    controller.onFrameSent(queuedB.command.frameId, bytes, clock.nowMs);
    expect(controller.inFlightBytes()).toBeGreaterThan(bytes);

    clock.nowMs += DESKTOP_VIEW_PING_RTT_WINDOW_MS + 1;
    controller.onRttSample(400, clock.nowMs, false);
    expect(controller.snapshot().baseRttMs).toBe(20);
    expect(controller.shouldEncode().kind).toBe("wait");

    controller.onAck(queuedA.command.frameId);
    controller.onAck(queuedB.command.frameId);
    expect(controller.shouldEncode().kind).toBe("wait");

    const resumeAt = clock.nowMs;
    controller.onRttSample(20, clock.nowMs, true);
    floodSlow(controller, clock, 200, 2_500);
    expect(controller.snapshot().level).toBeLessThan(7);
    expect(clock.nowMs - resumeAt).toBeLessThan(3_000);
  });

  it("ramps a healthy LAN-like link to L7 within 1s without an idle drain pause", () => {
    const clock = new FakeClock();
    const controller = seeded(clock, 5);
    const start = clock.nowMs;
    let staleWaits = 0;
    let drainPauseMs = 0;
    for (let step = 0; step <= 20 && controller.snapshot().level < 7; step += 1) {
      clock.nowMs = start + step * DESKTOP_VIEW_RAMP_MIN_MS;
      controller.onRttSample(5, clock.nowMs, true);
      const decision = controller.shouldEncode();
      if (
        decision.kind === "wait" &&
        decision.afterMs === undefined &&
        controller.snapshot().baseRttMs !== undefined
      ) {
        staleWaits += 1;
        drainPauseMs += DESKTOP_VIEW_RAMP_MIN_MS;
      }
      if (decision.kind !== "encode") continue;
      const bytes = pFrameBytes(controller);
      controller.onFrameSent(decision.command.frameId, bytes, clock.nowMs);
      clock.nowMs += 5;
      controller.onAck(decision.command.frameId);
    }
    expect(controller.snapshot().level).toBe(7);
    expect(clock.nowMs - start).toBeLessThanOrEqual(1_000);
    expect(staleWaits).toBe(0);
    expect(drainPauseMs).toBe(0);
  });

  it("does not down-step from one IDR larger than twice the P-frame", () => {
    const clock = new FakeClock();
    const controller = seeded(clock, 20);
    const pBytes = Math.ceil(DESKTOP_VIEW_LADDER[0]!.bitrate / 8 / DESKTOP_VIEW_LADDER[0]!.fps);
    const send = (bytes: number, rtt: number): void => {
      clock.nowMs += 1000 / 30;
      const decision = controller.shouldEncode();
      if (decision.kind !== "encode") return;
      controller.onFrameSent(decision.command.frameId, bytes, clock.nowMs);
      clock.nowMs += rtt;
      controller.onAck(decision.command.frameId);
    };
    for (let i = 0; i < 20; i += 1) send(pBytes, 10);
    const level = controller.snapshot().level;
    expect(level).toBeGreaterThan(0);
    send(pBytes * 6, 250);
    for (let i = 0; i < 8; i += 1) send(pBytes, 10);
    expect(controller.snapshot().level).toBeGreaterThanOrEqual(level);
  });
});
