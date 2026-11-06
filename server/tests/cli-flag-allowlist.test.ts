import { describe, expect, it, vi } from "vitest";

import { parseCliArgs } from "../src/cli/args.js";
import {
  listCliHelpTopicPaths,
  resolveHelpTopic,
  unsupportedFlagsMessage,
} from "../src/cli/help.js";
import { localApiRequest } from "../src/cli/local-api-client.js";
import { RUNNER_COMMANDS } from "../src/cli/args.js";
import { runCli } from "../src/cli/runner.js";

vi.mock("../src/cli/local-api-client.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/cli/local-api-client.js")>();
  return { ...actual, localApiRequest: vi.fn() };
});

describe("CLI flag allow-list", () => {
  it("fails a guessed flag on a noun that used to ignore it, before any request", async () => {
    const result = await runCli(["agent", "list", "--bogus", "--json"], { captureHuman: true });

    expect(result.ok).toBe(false);
    expect(result.exitCode).toBe(1);
    expect(result.error?.message).toBe(
      "Unsupported flag for 'agent list': --bogus. Accepted flags: --json. Run 'oppi agent list --help'.",
    );
    expect(vi.mocked(localApiRequest)).not.toHaveBeenCalled();
  });

  it("accepts every flag and alias each help topic declares", () => {
    const paths = listCliHelpTopicPaths().filter((path) => path.length > 0);
    let checked = 0;
    for (const path of paths) {
      for (const flag of resolveHelpTopic(path)?.flags ?? []) {
        for (const spelling of [flag.name, ...(flag.aliases ?? [])]) {
          const argv = [...path, spelling, "value"];
          expect(unsupportedFlagsMessage(parseCliArgs(argv)), argv.join(" ")).toBeUndefined();
          checked += 1;
        }
      }
    }
    expect(checked).toBeGreaterThan(100);
  });

  it("accepts --json on every command runCli dispatches, which Oppi Control always adds", () => {
    const paths = listCliHelpTopicPaths().filter((path) => RUNNER_COMMANDS.has(path[0] ?? ""));
    expect(paths.length).toBeGreaterThan(RUNNER_COMMANDS.size);
    for (const path of paths) {
      const argv = [...path, "--json"];
      expect(unsupportedFlagsMessage(parseCliArgs(argv)), argv.join(" ")).toBeUndefined();
    }
  });
});
