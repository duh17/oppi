import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { beforeEach, describe, expect, it, vi } from "vitest";

import { runCliMain } from "../src/cli.js";
import { cmdAgent } from "../src/cli/commands/agent.js";
import { cmdControl } from "../src/cli/commands/control.js";
import { cmdSchedule } from "../src/cli/commands/schedule.js";
import { inspectSession } from "../src/cli/commands/session-inspect.js";
import { cmdWait } from "../src/cli/commands/wait.js";
import { localApiRequest, type LocalApiConnection } from "../src/cli/local-api-client.js";
import { captureCliOutput } from "../src/cli/output.js";
import { runCli } from "../src/cli/runner.js";

vi.mock("../src/cli/local-api-client.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/cli/local-api-client.js")>();
  return { ...actual, localApiRequest: vi.fn() };
});

const storage = {} as LocalApiConnection;
const request = vi.mocked(localApiRequest);

beforeEach(() => request.mockReset());

describe("oppi control", () => {
  const session = {
    id: "11111111-1111-4111-8111-111111111111",
    status: "ready",
    serverDurable: { conversationId: 9, role: "control" },
  };

  it("open posts the find-or-create request and reports both ids", async () => {
    request.mockResolvedValueOnce({ session } as never);
    const { stdout, exitCode } = await captureCliOutput(() =>
      cmdControl(storage, "open", [], { json: "true" }),
    );
    expect(exitCode).toBe(0);
    expect(request).toHaveBeenCalledWith(storage, "/control-conversation", {
      method: "POST",
      body: {},
    });
    expect(JSON.parse(stdout)).toEqual({
      ok: true,
      data: { session_id: session.id, conversation_id: 9, status: "ready" },
    });
  });

  it("send opens, then prompts with a caller-chosen turn id it returns", async () => {
    request
      .mockResolvedValueOnce({ session } as never)
      .mockResolvedValueOnce({ messages: [] } as never);
    const { stdout } = await captureCliOutput(() =>
      cmdControl(storage, "send", ["Pause the nightly run"], { json: "true" }),
    );
    const data = JSON.parse(stdout).data as { turn_id: string };
    expect(data).toEqual({ session_id: session.id, conversation_id: 9, turn_id: data.turn_id });
    const [, path, options] = request.mock.calls[1]!;
    expect(path).toBe(`/sessions/${session.id}/command`);
    expect(options).toMatchObject({
      method: "POST",
      body: {
        type: "prompt",
        message: "Pause the nightly run",
        clientTurnId: data.turn_id,
        requestId: data.turn_id,
      },
    });
  });

  it("send with bad input fails before the conversation is created", async () => {
    const { stdout, exitCode } = await captureCliOutput(() =>
      cmdControl(storage, "send", [], { json: "true" }),
    );
    expect(exitCode).toBe(1);
    expect(JSON.parse(stdout)).toMatchObject({ ok: false });
    expect(request).not.toHaveBeenCalled();
  });

  it("surfaces the server's refusal while experimental.serverDurable is off", async () => {
    request.mockRejectedValueOnce(
      Object.assign(new Error("The control conversation is not available on this server"), {
        status: 409,
      }),
    );
    const { stdout, exitCode } = await captureCliOutput(() =>
      cmdControl(storage, "open", [], { json: "true" }),
    );
    expect(exitCode).toBe(1);
    expect(JSON.parse(stdout)).toMatchObject({
      ok: false,
      error: { message: expect.stringContaining("not available"), status: 409 },
    });
  });
});

describe("agent create idempotency flag", () => {
  it("sends the key with the definition and reports a conflict code", async () => {
    request.mockResolvedValueOnce({ agent: { id: "a1", name: "Scribe", version: 1 } } as never);
    await captureCliOutput(() =>
      cmdAgent(storage, "create", [], { name: "Scribe", "idempotency-key": "k-1", json: "true" }),
    );
    expect(request).toHaveBeenCalledWith(storage, "/agents", {
      method: "POST",
      body: { name: "Scribe", idempotencyKey: "k-1" },
    });

    request.mockRejectedValueOnce(
      Object.assign(new Error("Idempotency key already created Agent a1"), {
        status: 409,
        code: "AGENT_IDEMPOTENCY_CONFLICT",
      }),
    );
    const { stdout } = await captureCliOutput(() =>
      cmdAgent(storage, "create", [], { name: "Other", "idempotency-key": "k-1", json: "true" }),
    );
    expect(JSON.parse(stdout)).toMatchObject({
      ok: false,
      error: { status: 409, code: "AGENT_IDEMPOTENCY_CONFLICT" },
    });
  });
});

describe("schedule create idempotency flag", () => {
  const flags = { workspace: "w1", prompt: "go", every: "1h", tz: "UTC", json: "true" };
  const answer = async (_storage: unknown, path: string) =>
    String(path).startsWith("/workspaces")
      ? { workspaces: [{ id: "w1", name: "w1" }], workspace: { id: "w1", name: "w1" } }
      : { schedule: { id: "sch1" } };

  it("sends the key with the schedule", async () => {
    request.mockImplementation(answer as never);
    await captureCliOutput(() =>
      cmdSchedule(storage, "create", [], { ...flags, name: "Nightly", "idempotency-key": "k-1" }),
    );
    expect(request).toHaveBeenLastCalledWith(storage, "/schedules", {
      method: "POST",
      body: expect.objectContaining({ name: "Nightly", idempotencyKey: "k-1" }),
    });
  });

  it("needs a name, whose default would change between a call and its retry", async () => {
    request.mockImplementation(answer as never);
    const { stdout, exitCode } = await captureCliOutput(() =>
      cmdSchedule(storage, "create", [], { ...flags, "idempotency-key": "k-1" }),
    );
    expect(exitCode).toBe(1);
    expect(JSON.parse(stdout)).toMatchObject({
      ok: false,
      error: { message: expect.stringContaining("pass a name") },
    });
    expect(request).not.toHaveBeenCalledWith(storage, "/schedules", expect.anything());
  });
});

describe("script-facing CLI touches", () => {
  it("session inspect --turns last selects only the final turn", async () => {
    const trace = [
      { type: "user", text: "first question" },
      { type: "assistant", text: "first answer" },
      { type: "user", text: "second question" },
      { type: "assistant", text: "second answer" },
    ];
    const call = vi.fn(async () => ({ session: { id: "s" }, trace })) as never;
    const last = await inspectSession("s", [], { turns: "last", view: "response" }, call);
    expect(last.selected_turns).toEqual([2]);
    expect(last.text).toBe("second answer");

    const empty = vi.fn(async () => ({ session: { id: "s" }, trace: [] })) as never;
    expect(
      (await inspectSession("s", [], { turns: "last", view: "response" }, empty)).selected_turns,
    ).toEqual([]);
  });

  it("wait timeout carries the documented wait_timeout code", async () => {
    request.mockImplementation(async (_storage, path) => {
      if (String(path).startsWith("/sessions?idPrefix=")) return { sessions: [{ id: "s" }] };
      return { session: { id: "s", status: "busy" } };
    });
    const { stdout, exitCode } = await captureCliOutput(() =>
      cmdWait(storage, "session", ["s"], { json: "true", timeout: "40ms", poll: "10ms" }),
    );
    expect(exitCode).toBe(1);
    expect(JSON.parse(stdout)).toMatchObject({ ok: false, error: { code: "wait_timeout" } });
  });

  it("config validate failure carries the documented config_invalid code", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-validate-"));
    const bad = join(dataDir, "bad.json");
    writeFileSync(bad, "{ not json");
    const bad2 = await runCli(["config", "validate", "--config-file", bad], {
      dataDir,
      captureHuman: true,
      forceJson: true,
    });
    expect(bad2.json).toMatchObject({ ok: true, data: { valid: false, code: "config_invalid" } });

    const good = join(dataDir, "good.json");
    writeFileSync(good, JSON.stringify({}));
    const ok = await runCli(["config", "validate", "--config-file", good], {
      dataDir,
      captureHuman: true,
      forceJson: true,
    });
    expect(ok.json).toMatchObject({ ok: true, data: { valid: true } });
    expect((ok.json as { data: Record<string, unknown> }).data).not.toHaveProperty("code");
  });

  it("version emits an envelope under --json and the plain line otherwise", async () => {
    const json = await captureCliOutput(() => runCliMain(["version", "--json"]));
    expect(JSON.parse(json.stdout)).toMatchObject({
      ok: true,
      data: { name: "oppi-server", version: expect.any(String) },
    });

    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    try {
      await runCliMain(["version"]);
      expect(log.mock.calls.flat().join("")).toMatch(/^oppi-server \d/);
    } finally {
      log.mockRestore();
    }
  });
});
