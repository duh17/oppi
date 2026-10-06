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
    ["the control family", ["control", "send", "hello"]],
    ["the control family, even to ask for help", ["control", "open", "--help"]],
    ["status, which blocks the event loop", ["status"]],
    ["config set", ["config", "set", "port", "1"]],
    ["a config file", ["config", "validate", "--config-file", "/tmp/x.json"]],
    ["an --idempotency-key=value key", ["agent", "create", "--name", "x", "--idempotency-key=k"]],
    ["a --request-id=value key", ["schedule", "run", "s1", "--request-id=r"]],
    ["a --turn-id=value key", ["session", "send", "s1", "--text", "hi", "--turn-id=t"]],
    [
      "an = key where it used to shift the verb",
      ["--idempotency-key=x", "agent", "create", "--name", "x"],
    ],
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

describe("control host replay keys", () => {
  /** The value after `flag` in what reached the runner. */
  const keyOf = (argv: readonly string[], flag: string): string => {
    const at = argv.indexOf(flag);
    expect(at, `${flag} in ${JSON.stringify(argv)}`).toBeGreaterThan(-1);
    return argv[at + 1]!;
  };

  it.each([
    [["agent", "create", "--name", "x"], "--idempotency-key"],
    [["session", "create", "--workspace", "w", "--prompt", "p"], "--idempotency-key"],
    [["session", "start", "--workspace", "w", "--prompt", "p"], "--idempotency-key"],
    [
      ["schedule", "create", "--workspace", "w", "--prompt", "p", "--every", "1h", "--name", "n"],
      "--idempotency-key",
    ],
    [["schedule", "run", "s1"], "--request-id"],
    [["session", "send", "s1", "--text", "hi"], "--turn-id"],
  ])("gives %j one key derived from the call", async (argv, flag) => {
    await host().run(argv, options());
    await host().run(argv, options());
    const [first, second] = runner.mock.calls.map(([sent]) => sent);
    expect(keyOf(first!, flag)).toMatch(/^7:0:[0-9a-f]{12}$/);
    expect(first).toEqual(second);
    expect(first!.filter((word) => word === flag)).toHaveLength(1);
  });

  it("overwrites a key the script chose, so a rerun with a fresh one is still the same write", async () => {
    await host().run(["schedule", "run", "s1", "--request-id", "t1"], options());
    await host().run(["schedule", "run", "s1", "--request-id", "t2"], options());
    await host().run(["agent", "create", "--idempotency-key", "a", "--name", "x"], options());
    await host().run(["agent", "create", "--name", "x", "--idempotency-key"], options());
    await host().run(["session", "send", "s1", "--turn-id", "u1", "--text", "hi"], options());
    await host().run(["session", "send", "s1", "--text", "hi", "--turn-id", "u2"], options());
    const sent = runner.mock.calls.map(([argv]) => argv);
    expect(keyOf(sent[0]!, "--request-id")).toBe(keyOf(sent[1]!, "--request-id"));
    expect(sent[0]).not.toContain("t1");
    expect(sent[1]).not.toContain("t2");
    expect(keyOf(sent[2]!, "--idempotency-key")).toBe(keyOf(sent[3]!, "--idempotency-key"));
    expect(sent[2]).not.toContain("a");
    expect(keyOf(sent[4]!, "--turn-id")).toBe(keyOf(sent[5]!, "--turn-id"));
    expect(sent[4]).not.toContain("u1");
    expect(sent[5]).not.toContain("u2");
  });

  it("gives another call at the same index another key, and leaves other commands alone", async () => {
    await host().run(["agent", "create", "--name", "A"], options());
    await host().run(["agent", "create", "--name", "B"], options());
    await host().run(["agent", "list"], options());
    const [a, b, list] = runner.mock.calls.map(([argv]) => argv);
    expect(keyOf(a!, "--idempotency-key")).not.toBe(keyOf(b!, "--idempotency-key"));
    expect(list).toEqual(["agent", "list"]);
  });

  it("keeps a positional that looks like the flag after `--`", async () => {
    await host().run(["session", "send", "--text", "hi", "--", "--turn-id"], options());
    const sent = runner.mock.calls[0]![0];
    expect(sent.slice(sent.indexOf("--") + 1)).toEqual(["--turn-id"]);
  });

  it("does not refuse the = form of a key when it is a positional after `--`", async () => {
    const result = await host().run(
      ["session", "send", "--text", "hi", "--", "--turn-id=literal"],
      options(),
    );
    expect(result.envelope).not.toMatchObject({ error: { code: "refused" } });
    expect(runner.mock.calls[0]![0].slice(-2)).toEqual(["--", "--turn-id=literal"]);
  });
});

describe("control host self-targeting", () => {
  it.each([
    ["wait session", ["wait", "session", "s1"]],
    ["session wait", ["session", "wait", "s1"]],
  ])("`%s` refuses the conversation's own session before any request", async (_name, argv) => {
    // No server runs behind this data directory: only a local refusal can answer with this message.
    const result = await host().run(argv, options());
    expect(runner).toHaveBeenCalledOnce();
    expect(result.envelope).toMatchObject({
      ok: false,
      error: { message: "Cannot target the calling Oppi session (s1)" },
    });
  });
});
