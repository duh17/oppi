import { afterEach, describe, expect, it, vi } from "vitest";
import type { ConversationId } from "@earendil-works/pi-durable";

import { DurableControlCli } from "../src/durable-control-cli.js";
import { runCli } from "../src/cli/runner.js";

vi.mock("../src/cli/runner.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/cli/runner.js")>();
  return { ...actual, runCli: vi.fn(actual.runCli) };
});

const runner = vi.mocked(runCli);

afterEach(() => {
  runner.mockClear();
});

function host() {
  return new DurableControlCli({ dataDir: "/tmp/oppi-control-cli-test", sessionIdOf: () => "s1" });
}
const options = () => ({
  conversationId: 1 as ConversationId,
  key: "7:0",
  signal: new AbortController().signal,
  onWrite: vi.fn(async () => {}),
});

describe("control host argv denylist", () => {
  it.each([
    ["a definition file", ["agent", "create", "--definition", "/etc/hosts"]],
    ["a definition file for a schedule", ["schedule", "update", "s", "--definition", "p.json"]],
    [
      "an instructions file",
      ["agent", "create", "--name", "x", "--instructions-file", "/etc/hosts"],
    ],
    ["a dictionary file", ["dictionary", "add", "--file", "/etc/hosts"]],
    ["stdin phrases", ["dictionary", "add", "--phrases", "@-"]],
    ["stdin as a prompt", ["session", "send", "abc", "--text", "@-"]],
    ["stdin as a positional", ["session", "create", "--workspace", "w", "--prompt", "@-"]],
    ["config set", ["config", "set", "port", "1"]],
    ["a config file", ["config", "validate", "--config-file", "/tmp/x.json"]],
  ])("refuses %s before runCli", async (_name, argv) => {
    const call = options();
    const result = await host().run(argv, call);
    expect(result).toMatchObject({
      wrote: false,
      envelope: { ok: false, error: { code: "refused" } },
    });
    expect(runner).not.toHaveBeenCalled();
    expect(call.onWrite).not.toHaveBeenCalled();
  });

  it("still runs the inline forms of the same commands", async () => {
    const result = await host().run(
      ["agent", "create", "--definition-json", '{"name":"x"}', "--idempotency-key", "k"],
      options(),
    );
    expect(runner).toHaveBeenCalledOnce();
    // No server behind this data directory: the command ran and failed on its own terms.
    expect(result.envelope).toMatchObject({ ok: false });
    expect((result.envelope.error as { code?: string }).code).not.toBe("refused");
  });
});

describe("control host idempotency keys", () => {
  it.each([
    [
      ["agent", "create", "--name", "x"],
      ["--idempotency-key", "7:0"],
    ],
    [
      ["session", "create", "--workspace", "w", "--prompt", "p"],
      ["--idempotency-key", "7:0"],
    ],
    [
      ["schedule", "run", "s1"],
      ["--request-id", "7:0"],
    ],
  ])("derives the key of %j from the call", async (argv, added) => {
    await host().run(argv, options());
    const sent = runner.mock.calls[0]![0];
    expect(sent).toEqual([...argv, ...added]);
  });

  it("keeps a key the script chose and adds none to other commands", async () => {
    await host().run(["schedule", "run", "s1", "--request-id", "mine"], options());
    await host().run(["agent", "list"], options());
    expect(runner.mock.calls.map(([argv]) => argv)).toEqual([
      ["schedule", "run", "s1", "--request-id", "mine"],
      ["agent", "list"],
    ]);
  });
});
