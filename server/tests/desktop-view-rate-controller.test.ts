import { describe, expect, it } from "vitest";

import {
  DESKTOP_VIEW_HARD_BYTE_CAP,
  DESKTOP_VIEW_LADDER,
  DESKTOP_VIEW_MIN_IN_FLIGHT_FRAMES,
  DESKTOP_VIEW_STEP_UP_HOLD_MS,
  DESKTOP_VIEW_WINDOW_GAIN,
  DesktopViewRateController,
} from "../src/desktop-view-rate-controller.js";

class FakeClock {
  nowMs = 1_000;
  now = (): number => this.nowMs;
}

function seeded(clock: FakeClock): DesktopViewRateController {
  const controller = new DesktopViewRateController({ now: clock.now });
  controller.onRttSample(20);
  return controller;
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
    const frameBytes = 8_000;
    controller.onFrameSent(first.command.frameId, frameBytes);
    expect(controller.shouldEncode().kind).toBe("wait");

    clock.nowMs += 1000 / DESKTOP_VIEW_LADDER[0]!.fps;
    const second = controller.shouldEncode();
    expect(second.kind).toBe("encode");
    if (second.kind !== "encode") return;
    controller.onFrameSent(second.command.frameId, frameBytes);

    expect(controller.inFlightBytes()).toBe(2 * frameBytes);
    expect(controller.windowBytes()).toBe(DESKTOP_VIEW_MIN_IN_FLIGHT_FRAMES * frameBytes);
    expect(controller.shouldEncode().kind).toBe("wait");
  });

  it("steps up only after the step-up hold while the window has room", () => {
    const clock = new FakeClock();
    const controller = seeded(clock);
    const first = controller.shouldEncode();
    expect(first.kind).toBe("encode");
    if (first.kind !== "encode") return;
    controller.onFrameSent(first.command.frameId, 1_000);
    clock.nowMs += 10;
    controller.onAck(first.command.frameId);
    expect(controller.snapshot().level).toBe(0);

    clock.nowMs = 1_000 + 1000 / DESKTOP_VIEW_LADDER[0]!.fps;
    const early = controller.shouldEncode();
    expect(early.kind).toBe("encode");
    if (early.kind !== "encode") return;
    expect(early.command.level).toBe(0);
    controller.onFrameSent(early.command.frameId, 1_000);
    clock.nowMs += 10;
    controller.onAck(early.command.frameId);

    clock.nowMs = 1_000 + DESKTOP_VIEW_STEP_UP_HOLD_MS;
    const late = controller.shouldEncode();
    expect(late.kind).toBe("encode");
    if (late.kind !== "encode") return;
    expect(late.command.level).toBe(1);
    expect(late.command.keyframe).toBe(false);
  });

  it("steps down when frame RTT exceeds the ping floor, at most once per RTT", () => {
    const clock = new FakeClock();
    const controller = seeded(clock);
    const first = controller.shouldEncode();
    if (first.kind !== "encode") throw new Error("expected encode");
    controller.onFrameSent(first.command.frameId, 1_000);
    clock.nowMs += 10;
    controller.onAck(first.command.frameId);

    clock.nowMs = 1_000 + DESKTOP_VIEW_STEP_UP_HOLD_MS;
    const up = controller.shouldEncode();
    if (up.kind !== "encode") throw new Error("expected encode");
    expect(up.command.level).toBe(1);
    controller.onFrameSent(up.command.frameId, 1_000);
    clock.nowMs += 10;
    controller.onAck(up.command.frameId);

    clock.nowMs += DESKTOP_VIEW_STEP_UP_HOLD_MS;
    const higher = controller.shouldEncode();
    if (higher.kind !== "encode") throw new Error("expected encode");
    expect(higher.command.level).toBe(2);
    controller.onFrameSent(higher.command.frameId, 1_000);

    clock.nowMs += 250;
    const extra = controller.shouldEncode();
    if (extra.kind !== "encode") throw new Error("expected encode");
    controller.onFrameSent(extra.command.frameId, 1_000);

    clock.nowMs += 100;
    controller.onAck(higher.command.frameId);
    expect(controller.snapshot().level).toBe(1);
    clock.nowMs += 1;
    controller.onAck(extra.command.frameId);
    expect(controller.snapshot().level).toBe(1);
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

  it("uses gain × delivered rate × ping RTT for the window", () => {
    const clock = new FakeClock();
    const controller = seeded(clock);
    const first = controller.shouldEncode();
    if (first.kind !== "encode") throw new Error("expected encode");
    controller.onFrameSent(first.command.frameId, 10_000, clock.nowMs);
    clock.nowMs += 20;
    controller.onAck(first.command.frameId);
    const snap = controller.snapshot();
    expect(snap.baseRttMs).toBe(20);
    expect(snap.windowBytes).toBeGreaterThanOrEqual(
      Math.ceil(DESKTOP_VIEW_WINDOW_GAIN * snap.deliveredBps * (snap.baseRttMs! / 1000)),
    );
  });
});
