import { describe, expect, it, vi } from "vitest";

import {
  listCliHelpTopicPaths,
  resolveHelpTopic,
  unsupportedFlagsMessage,
} from "../src/cli/help.js";
import { localApiRequest } from "../src/cli/local-api-client.js";
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

  it("accepts every flag and long alias each help topic declares", () => {
    const paths = listCliHelpTopicPaths().filter((path) => path.length > 0);
    let checked = 0;
    for (const path of paths) {
      for (const flag of resolveHelpTopic(path)?.flags ?? []) {
        for (const spelling of [flag.name, ...(flag.aliases ?? [])]) {
          if (!spelling.startsWith("--")) continue;
          const [command, ...positional] = path;
          const message = unsupportedFlagsMessage(command!, positional, {
            [spelling.slice(2)]: "value",
          });
          expect(message, `${path.join(" ")} ${spelling}`).toBeUndefined();
          checked += 1;
        }
      }
    }
    expect(checked).toBeGreaterThan(100);
  });
});
