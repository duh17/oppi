import { readFileSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import {
  CHAT_METRIC_NAME_VALUES,
  CHAT_METRIC_REGISTRY,
  telemetryUploadsEnabledFromEnv,
} from "../src/types.js";

describe("shared telemetry constants", () => {
  it("keeps chat metric names unique", () => {
    expect(new Set(CHAT_METRIC_NAME_VALUES).size).toBe(CHAT_METRIC_NAME_VALUES.length);
  });

  it("keeps metric registry in parity with metric names", () => {
    expect(Object.keys(CHAT_METRIC_REGISTRY).sort()).toEqual([...CHAT_METRIC_NAME_VALUES].sort());
  });

  it("provisions a model-routing dashboard for provider and tool errors", () => {
    const dashboardPath = join(
      process.cwd(),
      "docker",
      "grafana",
      "dashboards",
      "oppi-model-routing.json",
    );
    const dashboard = JSON.parse(readFileSync(dashboardPath, "utf8")) as {
      title: string;
      uid: string;
      panels: Array<{ title?: string; type?: string }>;
      templating?: { list?: Array<{ name?: string }> };
    };
    const text = JSON.stringify(dashboard);

    expect(dashboard.uid).toBe("oppi-model-routing");
    expect(dashboard.title).toBe("Oppi Model Routing");
    expect(dashboard.templating?.list?.map((item) => item.name)).toEqual(
      expect.arrayContaining(["provider", "route"]),
    );
    expect(dashboard.panels.map((panel) => panel.title)).toEqual(
      expect.arrayContaining([
        "Cost by model",
        "TTFT by model",
        "Turn errors by model",
        "$ / 1k output by model",
        "By provider",
        "By provider / model",
        "By provider / model + tool",
        "Tool errors",
      ]),
    );
    expect(dashboard.panels.filter((panel) => panel.type === "barchart")).toHaveLength(4);
    expect(text).toContain("server.turn_ttft_ms");
    expect(text).toContain("server.turn_duration_ms");
    expect(text).toContain("server.turn_cost");
    expect(text).toContain("server.turn_error");
    expect(text).toContain("server.tool_result");
    expect(text).toContain("server.tool_duration_ms");
    expect(text).toContain("usd_per_1k_out");
    expect(text).toContain("${provider:sqlstring}");
    expect(text).toContain("${route:sqlstring}");
    expect(text).toContain("json_extract(tags_json, '$.provider')");
    expect(text).toContain("json_extract(tags_json, '$.status') = 'error'");
  });

  it("tracks trace transport separately from reducer application", () => {
    expect(CHAT_METRIC_REGISTRY).toHaveProperty("chat.trace_fetch_ms");
    expect(CHAT_METRIC_REGISTRY).toHaveProperty("chat.reducer_load_ms");
    expect(CHAT_METRIC_REGISTRY).not.toHaveProperty("chat.full_reload_ms");

    const dashboardPath = join(
      process.cwd(),
      "docker",
      "grafana",
      "dashboards",
      "oppi-release-preflight.json",
    );
    const dashboard = readFileSync(dashboardPath, "utf8");
    expect(dashboard).toContain("chat.trace_fetch_ms");
    expect(dashboard).not.toContain("chat.full_reload_ms");
  });

  it("keeps iOS metric enum in parity with server metric names", () => {
    const metricModelsPath = join(
      process.cwd(),
      "..",
      "clients",
      "apple",
      "Oppi",
      "Core",
      "Services",
      "MetricKitModels.swift",
    );
    const source = readFileSync(metricModelsPath, "utf8");
    const iosMetricNames = [...source.matchAll(/case\s+\w+\s*=\s*"([^"]+)"/g)]
      .map((match) => match[1])
      .filter(
        (metric) =>
          metric.startsWith("chat.") ||
          metric.startsWith("plot.") ||
          metric.startsWith("device.") ||
          metric.startsWith("network."),
      );

    expect([...new Set(iosMetricNames)].sort()).toEqual([...CHAT_METRIC_NAME_VALUES].sort());
  });

  it("parses OPPI_TELEMETRY_MODE consistently", () => {
    expect(telemetryUploadsEnabledFromEnv(undefined)).toBe(true);
    expect(telemetryUploadsEnabledFromEnv("internal")).toBe(true);
    expect(telemetryUploadsEnabledFromEnv("PUBLIC")).toBe(false);
    expect(telemetryUploadsEnabledFromEnv("unknown-mode")).toBe(false);
  });
});
