import { describe, expect, it } from "vitest";

import {
  isPiTuiTaskRecordBridgeState,
  isPiTuiTaskRecordSession,
} from "../src/pi-tui-session-classification.js";

describe("pi-tui session classification", () => {
  it("classifies no-trace Pi Agent task rows as task records", () => {
    expect(
      isPiTuiTaskRecordSession({
        runtime: "pi-tui",
        name: "general-purpose#738f21e6",
      }),
    ).toBe(true);
  });

  it("keeps trace-backed pi-tui sessions openable", () => {
    expect(
      isPiTuiTaskRecordSession({
        runtime: "pi-tui",
        name: "general-purpose#738f21e6",
        piSessionFile: "/tmp/session.jsonl",
      }),
    ).toBe(false);
  });

  it("classifies matching bridge state only when no trace file is present", () => {
    expect(
      isPiTuiTaskRecordBridgeState({
        sessionName: "general-purpose#14849855",
      }),
    ).toBe(true);
    expect(
      isPiTuiTaskRecordBridgeState({
        sessionName: "general-purpose#14849855",
        sessionFile: "/tmp/session.jsonl",
      }),
    ).toBe(false);
  });
});
