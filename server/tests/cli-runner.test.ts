import { afterEach, describe, expect, it, vi } from "vitest";

import { localApiRequest } from "../src/cli/local-api-client.js";
import { quotaHeadroomState } from "../src/cli/quota.js";
import { runCli } from "../src/cli/runner.js";

vi.mock("../src/cli/local-api-client.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/cli/local-api-client.js")>();
  return { ...actual, localApiRequest: vi.fn() };
});

const request = vi.mocked(localApiRequest);

afterEach(() => {
  request.mockReset();
});

describe("canonical CLI runner", () => {
  it.each([
    [51, "healthy"],
    [50, "constrained"],
    [21, "constrained"],
    [20, "critical"],
    [19, "critical"],
  ] as const)("classifies %s%% quota headroom as %s", (remaining, expected) => {
    expect(quotaHeadroomState(remaining)).toBe(expected);
  });

  it("executes one canonical command and captures its JSON and complete ANSI human output", async () => {
    request.mockResolvedValueOnce({
      agent: { id: "agent-1", name: "Reviewer", status: "active", version: 3 },
    } as never);

    const originalArgv = [...process.argv];
    const consoleLog = vi.spyOn(console, "log").mockImplementation(() => {});
    let result: Awaited<ReturnType<typeof runCli>>;
    try {
      result = await runCli(["agent", "get", "agent-1"], {
        dataDir: "/tmp/oppi-runner-test",
        captureHuman: true,
        forceJson: true,
      });
    } finally {
      consoleLog.mockRestore();
    }

    expect(consoleLog).not.toHaveBeenCalled();
    expect(process.argv).toEqual(originalArgv);
    expect(result).toMatchObject({ ok: true, exitCode: 0 });
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: true,
      data: { agent: { id: "agent-1", name: "Reviewer" } },
    });
    expect(result.humanOutput).toContain("Reviewer");
    expect(result.humanOutput).toContain("\u001b[");
    expect(request).toHaveBeenCalledTimes(1);
  });

  it("uses the canonical help renderer for write-command help", async () => {
    const result = await runCli(["session", "delete", "--help"], {
      dataDir: "/tmp/oppi-runner-help-test",
      captureHuman: true,
      forceJson: true,
    });

    expect(result).toMatchObject({ ok: true, exitCode: 0 });
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: true,
      data: { help: { title: "Delete session" } },
    });
    expect(result.humanOutput).toContain("Delete session");
    expect(result.humanOutput).toContain("\u001b[");
    expect(request).not.toHaveBeenCalled();
  });

  it("returns a redacted status envelope and the same command-owned human output", async () => {
    const result = await runCli(["status"], {
      dataDir: "/tmp/oppi-runner-status-test",
      captureHuman: true,
      forceJson: true,
    });

    expect(result.ok).toBe(true);
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: true,
      data: { status: { server: { transport: expect.any(String) } } },
    });
    expect(result.humanOutput).toContain("Server Configuration");
    expect(result.humanOutput).toContain("\u001b[");
  });

  it("renders quota help without contacting the server", async () => {
    const result = await runCli(["quota", "--help"], {
      dataDir: "/tmp/oppi-runner-quota-help-test",
      captureHuman: true,
      forceJson: true,
    });

    expect(result).toMatchObject({ ok: true, exitCode: 0 });
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: true,
      data: { help: { path: ["quota"], title: "Provider quotas" } },
    });
    expect(result.humanOutput).toContain("oppi quota");
    expect(request).not.toHaveBeenCalled();
  });

  it("queries and renders every configured provider quota", async () => {
    request.mockResolvedValueOnce({
      providers: [
        {
          providerId: "openai-codex",
          displayName: "Codex",
          authenticated: true,
          planType: "prolite",
          windows: [
            {
              key: "weekly",
              shortLabel: "7d",
              title: "Weekly",
              usedPercent: 73,
              remainingPercent: 27,
              limitWindowSeconds: 604_800,
              resetAt: 1_787_196_783,
              includeWeekdayInReset: true,
            },
          ],
          credits: { hasCredits: false, unlimited: false, balance: "0" },
          prepaidBalanceCents: null,
          fetchedAt: 1_786_785_160_944,
        },
        {
          providerId: "unconfigured",
          displayName: "Unconfigured",
          authenticated: false,
          planType: null,
          windows: [],
          credits: null,
          prepaidBalanceCents: null,
          fetchedAt: 1_786_785_160_944,
        },
      ],
      fetchedAt: 1_786_785_160_944,
    } as never);

    const result = await runCli(["quota"], {
      dataDir: "/tmp/oppi-runner-quota-test",
      captureHuman: true,
      forceJson: true,
    });

    expect(result).toMatchObject({ ok: true, exitCode: 0 });
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: true,
      data: {
        providers: [
          {
            providerId: "openai-codex",
            planType: "prolite",
            windows: [{ key: "weekly", remainingPercent: 27 }],
          },
          { providerId: "unconfigured", authenticated: false },
        ],
      },
    });
    expect(result.humanOutput).toContain("Provider quotas");
    expect(result.humanOutput).toContain("Codex");
    expect(result.humanOutput).toContain("27% left");
    expect(result.humanOutput).toContain("Unconfigured");
    expect(result.humanOutput).toContain("Not configured");
    expect(request).toHaveBeenCalledWith(expect.anything(), "/server/provider-quotas", undefined);
  });

  it("renders models help without contacting the server", async () => {
    const result = await runCli(["models", "--help"], {
      dataDir: "/tmp/oppi-runner-models-help-test",
      captureHuman: true,
      forceJson: true,
    });

    expect(result).toMatchObject({ ok: true, exitCode: 0 });
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: true,
      data: { help: { path: ["models"], title: "Models" } },
    });
    expect(result.humanOutput).toContain("oppi models");
    expect(request).not.toHaveBeenCalled();
  });

  it("groups models by provider with quota colors and Pi-style columns", async () => {
    request.mockImplementation(async (_storage, path) => {
      if (path === "/models") {
        return {
          models: [
            {
              id: "openai-codex/gpt-5.6-sol",
              name: "gpt-5.6-sol",
              provider: "openai-codex",
              contextWindow: 272_000,
            },
            {
              id: "omlx/Qwen3.8-27B-8bit",
              name: "Qwen3.8-27B-8bit",
              provider: "omlx",
              contextWindow: 262_144,
            },
            {
              id: "openai-codex/gpt-5.4",
              name: "gpt-5.4",
              provider: "openai-codex",
              contextWindow: 272_000,
            },
          ],
        } as never;
      }
      if (path === "/server/provider-quotas") {
        return {
          providers: [
            {
              providerId: "openai-codex",
              displayName: "Codex",
              authenticated: true,
              planType: "prolite",
              windows: [
                {
                  key: "weekly",
                  shortLabel: "7d",
                  title: "Weekly",
                  usedPercent: 73,
                  remainingPercent: 27,
                  limitWindowSeconds: 604_800,
                  resetAt: null,
                  includeWeekdayInReset: true,
                },
              ],
              credits: { hasCredits: false, unlimited: false, balance: "0" },
              prepaidBalanceCents: null,
              fetchedAt: 1_786_785_160_944,
            },
          ],
          fetchedAt: 1_786_785_160_944,
        } as never;
      }
      throw new Error(`unexpected path ${path}`);
    });

    const result = await runCli(["models", "sol"], {
      dataDir: "/tmp/oppi-runner-models-test",
      captureHuman: true,
      forceJson: true,
    });

    expect(result).toMatchObject({ ok: true, exitCode: 0 });
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: true,
      data: {
        query: "sol",
        providers: [
          {
            provider: "openai-codex",
            display_name: "Codex",
            models: [{ id: "openai-codex/gpt-5.6-sol", name: "gpt-5.6-sol" }],
          },
        ],
      },
    });
    expect(result.humanOutput).toContain("Codex");
    expect(result.humanOutput).toContain("27% left");
    expect(result.humanOutput).toContain("openai-codex/gpt-5.6-sol");
    expect(result.humanOutput).toContain("272K");
    expect(result.humanOutput).not.toContain("Qwen3.8-27B-8bit");
    expect(result.humanOutput).toContain("\u001b[");
  });

  it("returns one error envelope for a malformed provider quota response", async () => {
    request.mockResolvedValueOnce({
      providers: [{ displayName: 42, windows: "broken" }],
      fetchedAt: 1_786_785_160_944,
    } as never);

    const result = await runCli(["quota"], {
      dataDir: "/tmp/oppi-runner-quota-malformed-test",
      captureHuman: true,
      forceJson: true,
    });

    expect(result).toMatchObject({ ok: false, exitCode: 1 });
    expect(JSON.parse(result.stdout)).toEqual({
      ok: false,
      error: { message: "Invalid provider quota response from local API" },
    });
    expect(result.humanOutput).toContain("Invalid provider quota response");
  });

  it("renders an empty provider quota response clearly", async () => {
    request.mockResolvedValueOnce({ providers: [], fetchedAt: 1_786_785_160_944 } as never);

    const result = await runCli(["quota"], {
      dataDir: "/tmp/oppi-runner-quota-empty-test",
      captureHuman: true,
      forceJson: true,
    });

    expect(result).toMatchObject({ ok: true, exitCode: 0 });
    expect(result.humanOutput).toContain("No quota providers reported");
  });

  it("does not terminate the process when a canonical command reports an error", async () => {
    request.mockRejectedValueOnce(new Error("No owner bearer token configured"));

    const result = await runCli(["agent", "list"], {
      dataDir: "/tmp/oppi-runner-error-test",
      captureHuman: true,
      forceJson: true,
    });

    expect(result).toMatchObject({ ok: false, exitCode: 1 });
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: false,
      error: { message: expect.stringContaining("No owner") },
    });
    expect(result.humanOutput).toContain("No owner");
    expect(result.humanOutput).toContain("[REDACTED]");
    expect(result.humanOutput).toContain("\u001b[");
  });

  it("forces JSON semantics when the invocation supplies a value-bearing JSON flag", async () => {
    request.mockRejectedValueOnce(new Error("No owner bearer token configured"));
    const exit = vi.spyOn(process, "exit").mockImplementation((() => undefined) as never);
    try {
      const result = await runCli(["agent", "list", "--json", "false"], {
        dataDir: "/tmp/oppi-runner-forced-json-test",
        captureHuman: true,
        forceJson: true,
      });

      expect(exit).not.toHaveBeenCalled();
      expect(result).toMatchObject({ ok: false, exitCode: 1 });
      expect(JSON.parse(result.stdout)).toMatchObject({
        ok: false,
        error: { message: expect.stringContaining("No owner") },
      });
      expect(result.humanOutput).toContain("\u001b[");
    } finally {
      exit.mockRestore();
    }
  });

  it("rejects an in-flight session wait promptly when its AbortSignal is triggered", async () => {
    const controller = new AbortController();
    let resolveInFlight!: (value: unknown) => void;
    let rejectInFlight!: (reason?: unknown) => void;
    const inFlight = new Promise<unknown>((resolve, reject) => {
      resolveInFlight = resolve;
      rejectInFlight = reject;
    });
    request.mockImplementation(async (_storage, _path, options) => {
      const onAbort = (): void => {
        rejectInFlight(Object.assign(new Error("Operation aborted"), { name: "AbortError" }));
      };
      options?.signal?.addEventListener("abort", onAbort, { once: true });
      try {
        return (await inFlight) as never;
      } finally {
        options?.signal?.removeEventListener("abort", onAbort);
      }
    });

    const cliPromise = runCli(
      ["session", "wait", "sess-1", "--for", "idle", "--poll", "1h", "--timeout", "1h"],
      {
        dataDir: "/tmp/oppi-runner-cancellation-test",
        captureHuman: true,
        forceJson: true,
        signal: controller.signal,
      },
    );

    await vi.waitFor(() => expect(request).toHaveBeenCalledOnce());
    controller.abort();

    let timeout: ReturnType<typeof setTimeout> | undefined;
    try {
      // Red before the fix: the signal never reached the pending API call, so this race returned
      // "pending" instead of the single AbortError rejection asserted below.
      const settled = await Promise.race([
        cliPromise.then(
          () => ({ state: "resolved" as const }),
          (error: unknown) => ({ state: "rejected" as const, error }),
        ),
        new Promise<"pending">((resolve) => {
          timeout = setTimeout(() => resolve("pending"), 100);
        }),
      ]);
      expect(settled).toEqual({
        state: "rejected",
        error: expect.objectContaining({ name: "AbortError" }),
      });
    } finally {
      if (timeout !== undefined) clearTimeout(timeout);
      resolveInFlight({ session: { status: "ready" }, events: [], currentSeq: 1 });
      await cliPromise.catch(() => undefined);
    }
  });
});
