import { readFileSync } from "node:fs";

import { describe, expect, it } from "vitest";

import {
  PI_TUI_MIRROR_REMOTE_COMMANDS,
  PI_TUI_MIRROR_UNSUPPORTED_REMOTE_COMMAND_REASONS,
} from "../src/pi-tui-mirror-contract.js";
import {
  OPPI_MIRROR_BRIDGE_COMMANDS,
  OPPI_MIRROR_CAPABILITIES,
  OPPI_MIRROR_SERVER_REMOTE_COMMANDS,
  OPPI_MIRROR_TERMINAL_CONTROL_COMMANDS,
} from "../../pi-extensions/oppi-mirror/extensions/oppi-mirror-contract.ts";

function sorted(values: readonly string[]): string[] {
  return [...values].sort((a, b) => a.localeCompare(b));
}

function expectNoDuplicates(name: string, values: readonly string[]): void {
  const duplicates = values.filter((value, index) => values.indexOf(value) !== index);
  expect(duplicates, `${name} contains duplicate entries`).toEqual([]);
}

function runCommandCases(): string[] {
  const source = readFileSync(
    new URL("../../pi-extensions/oppi-mirror/extensions/oppi-mirror.ts", import.meta.url),
    "utf8",
  );
  const start = source.indexOf("async function runCommand");
  const end = source.indexOf("function mirrorAgentEventPayload", start);
  expect(start).toBeGreaterThanOrEqual(0);
  expect(end).toBeGreaterThan(start);

  const runCommandSource = source.slice(start, end);
  return [
    ...new Set([...runCommandSource.matchAll(/case\s+"([^"]+)":/g)].map((match) => match[1])),
  ];
}

describe("pi-tui mirror contract", () => {
  it("keeps server and extension remote command manifests aligned", () => {
    expectNoDuplicates("server remote commands", PI_TUI_MIRROR_REMOTE_COMMANDS);
    expectNoDuplicates("extension server remote commands", OPPI_MIRROR_SERVER_REMOTE_COMMANDS);

    expect(sorted(OPPI_MIRROR_SERVER_REMOTE_COMMANDS)).toEqual(
      sorted(PI_TUI_MIRROR_REMOTE_COMMANDS),
    );
  });

  it("keeps the extension command manifest aligned with runCommand cases", () => {
    expectNoDuplicates("extension bridge commands", OPPI_MIRROR_BRIDGE_COMMANDS);
    expect(sorted(runCommandCases())).toEqual(sorted(OPPI_MIRROR_BRIDGE_COMMANDS));
  });

  it("keeps terminal-owned commands out of the server remote command set", () => {
    expect(sorted(OPPI_MIRROR_TERMINAL_CONTROL_COMMANDS)).toEqual([
      "follow_up",
      "prompt",
      "steer",
      "stop",
    ]);
    for (const command of OPPI_MIRROR_TERMINAL_CONTROL_COMMANDS) {
      expect(PI_TUI_MIRROR_REMOTE_COMMANDS).not.toContain(command);
    }
  });

  it("keeps unsupported command reasons disjoint from supported remote commands", () => {
    const unsupportedCommands = Object.keys(PI_TUI_MIRROR_UNSUPPORTED_REMOTE_COMMAND_REASONS);
    for (const command of unsupportedCommands) {
      expect(PI_TUI_MIRROR_REMOTE_COMMANDS).not.toContain(command);
    }
  });

  it("keeps advertised capabilities deduplicated", () => {
    expectNoDuplicates("extension capabilities", OPPI_MIRROR_CAPABILITIES);
  });
});
