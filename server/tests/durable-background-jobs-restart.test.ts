import { copyFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import {
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall,
  type FauxResponseStep,
} from "@earendil-works/pi-ai/providers/faux";
import { Harness, type Conversation } from "@earendil-works/pi-durable";
import { DurableJobs } from "../plugins/background-jobs/contract.js";
import { GondolinExecutionEnv } from "../src/durable-gondolin-env.js";
import { DurableHarness, DurableRuntime, durableStoreDir } from "../src/durable-harness.js";
import { DurableSessionDoc } from "../src/durable-session-doc.js";
import type { GondolinVm } from "../src/gondolin-ops.js";
import { makeTempDir } from "./harness/temp-dir.js";

/**
 * Background jobs and foreground bash across real store restarts (`DurableHarness.openHost` ->
 * `closeAll()` -> reopen -> `resume()`). Host cases spawn a real child process; sandbox cases run
 * through `GondolinExecutionEnv`.
 */
const STORE_ID = "jobs-host";
const SESSION_ID = "jobs-session";
const CLEAN_STOP_TEXT =
  "was stopped by the server restart; its process was killed and its output is lost — rerun it if still needed.";
const harnesses = new Set<Harness>();
const owners = new Set<DurableHarness>();
afterEach(async () => {
  await Promise.all([...harnesses].map((h) => h.close(context).catch(() => undefined)));
  harnesses.clear();
  await Promise.all([...owners].map((o) => o.closeAll().catch(() => undefined)));
  owners.clear();
  vi.restoreAllMocks();
});

const tool = (name: string, args: Record<string, unknown>): FauxResponseStep =>
  fauxAssistantMessage([fauxToolCall(name, args)], { stopReason: "toolUse" });
const answer = (text = "Integrated the result.") => fauxAssistantMessage(text);

async function waitFor(check: () => boolean | Promise<boolean>, timeoutMs = 8_000): Promise<void> {
  const started = Date.now();
  while (!(await check())) {
    if (Date.now() - started > timeoutMs) throw new Error("condition not met in time");
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
}

function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function fixture(responses: FauxResponseStep[]) {
  const dir = makeTempDir("oppi-background-jobs-restart-");
  const models = await ModelRuntime.create({
    authPath: join(dir, "auth.json"),
    modelsPath: null,
    modelsStorePath: join(dir, "models-cache.json"),
    refreshOnCreate: false,
  });
  const faux = fauxProvider();
  faux.setResponses(responses);
  models.registerNativeProvider(faux.provider);
  await models.setRuntimeApiKey("faux", "test-only-faux-credential");
  await models.refresh({ allowNetwork: false });
  vi.spyOn(ModelRuntime, "create").mockResolvedValue(models);
  vi.spyOn(SettingsManager, "create").mockReturnValue(
    SettingsManager.inMemory({ compaction: { enabled: false } }),
  );
  const openStore = async (dataDir = dir) => {
    const owner = new DurableHarness(dataDir);
    owner.bindSessionRecords({
      activity: async () => undefined,
      storeIdOf: (id) => (id === SESSION_ID ? STORE_ID : undefined),
    });
    owners.add(owner);
    const host = await owner.openHost(STORE_ID, { cwd: dir });
    const harness = (await host.open()).harness;
    harnesses.add(harness);
    return { owner, host, harness };
  };
  const opened = await openStore();
  const root = await opened.harness.root(context, {
    agent: { model: { provider: "faux", modelId: "faux-1" }, cwd: dir },
  });
  await root.commit(async (tx) => {
    (await tx.doc(DurableSessionDoc, root.id)).sessionId = SESSION_ID;
  }, context);
  return { dir, root, ...opened, openStore };
}

type Fixture = Awaited<ReturnType<typeof fixture>>;

async function stopServer(f: Fixture): Promise<void> {
  f.owner.shuttingDown = true;
  owners.delete(f.owner);
  harnesses.delete(f.harness);
  await f.owner.closeAll();
}

async function startServer(
  f: Fixture,
  dataDir = f.dir,
): Promise<{ harness: Harness; root: Conversation }> {
  const reopened = await f.openStore(dataDir);
  const root = (await reopened.harness.conversation(f.root.id, context))!;
  reopened.harness.resume();
  Object.assign(f, reopened);
  return { harness: reopened.harness, root };
}

async function prompt(root: Conversation, content = "Start the job") {
  expect(
    (await (await root.submit({ type: "input", content }, context)).wait(context)).status,
  ).toBe("done");
  await root.waitForIdle(context);
}

async function reports(root: Conversation): Promise<string> {
  return JSON.stringify(
    (await root.context(context)).messages.filter(
      (m) => m.role === "user" && JSON.stringify(m.content).includes("Background job bash-"),
    ),
  );
}

function sandboxVm(killSucceeds: boolean) {
  let markStarted!: () => void;
  let release!: () => void;
  const started = new Promise<void>((r) => (markStarted = r));
  const finish = new Promise<void>((r) => (release = r));
  const okResult = { ok: true, exitCode: 0, stdout: "", stdoutBuffer: Buffer.alloc(0) };
  const vm = {
    exec: vi.fn((args: string[] | string) => {
      if (args.includes("oppi-kill")) {
        release();
        return killSucceeds
          ? Promise.resolve(okResult)
          : Promise.reject(new Error("Guest kill failed"));
      }
      return Object.assign(
        finish.then(() => okResult),
        {
          async *output() {
            yield { stream: "stdout", data: Buffer.from("42 12345\n") };
            markStarted();
            await finish;
          },
          write() {},
          end() {},
        },
      );
    }),
  } as unknown as GondolinVm;
  return { vm, started };
}

describe("a background job across a server restart", () => {
  it("kills a live host job on graceful close, clears clean-close on open, and reports it cleanly", async () => {
    const f = await fixture([
      tool("background_job", { action: "start", command: "echo $$ > shell.pid; sleep 60" }),
      answer(),
      answer(),
    ]);
    await prompt(f.root);
    const pidFile = join(f.dir, "shell.pid");
    await waitFor(() => existsSync(pidFile));
    const pid = Number(readFileSync(pidFile, "utf8").trim());
    expect(pidAlive(pid)).toBe(true);
    const job = (await f.harness.snapshot(DurableJobs, f.root.id, context))!.jobs[0]!;

    await stopServer(f);
    await waitFor(() => !pidAlive(pid));
    const cleanCloseFile = join(durableStoreDir(f.dir, STORE_ID), ".clean-close");
    expect(existsSync(cleanCloseFile)).toBe(true);
    expect(existsSync(join(f.dir, ".pi"))).toBe(false);

    const { harness, root } = await startServer(f);
    expect(existsSync(cleanCloseFile)).toBe(false);
    await harness.waitForTask(job.taskId, context);
    await root.waitForIdle(context);
    const delivered = await reports(root);
    expect(delivered).toContain(`Background job bash-1 ${CLEAN_STOP_TEXT}`);
    expect(delivered).not.toContain("may still be running");
    expect((await harness.snapshot(DurableJobs, f.root.id, context))!.jobs[0]).toMatchObject({
      status: "interrupted",
      resumed: "stopped",
    });
  });

  it("uses the same clean-restart wording for foreground bash", async () => {
    const f = await fixture([tool("bash", { command: "echo $$ > shell.pid; sleep 60" }), answer()]);
    const submission = await f.root.submit({ type: "input", content: "Run bash" }, context);
    const pidFile = join(f.dir, "shell.pid");
    await waitFor(() => existsSync(pidFile));
    const pid = Number(readFileSync(pidFile, "utf8").trim());
    expect(pidAlive(pid)).toBe(true);

    await stopServer(f);
    await waitFor(() => !pidAlive(pid));
    void submission.wait(context).catch(() => undefined);

    const { root } = await startServer(f);
    await root.waitForIdle(context);
    const messages = JSON.stringify((await root.context(context)).messages);
    expect(messages).toContain(`Command ${CLEAN_STOP_TEXT}`);
    expect(messages).not.toContain("may still be running");
  });

  it("keeps the process-may-still-run warning when a store reopens without a clean close", async () => {
    const f = await fixture([
      tool("background_job", { action: "start", command: "echo $$ > shell.pid; sleep 60" }),
      answer(),
      answer(),
    ]);
    await prompt(f.root);
    await waitFor(() => existsSync(join(f.dir, "shell.pid")));
    const job = (await f.harness.snapshot(DurableJobs, f.root.id, context))!.jobs[0]!;

    // Copy the live store before closing: an exact crash image with no `.clean-close`.
    const crashedDir = makeTempDir("oppi-background-jobs-crash-");
    const src = durableStoreDir(f.dir, STORE_ID);
    const dst = durableStoreDir(crashedDir, STORE_ID);
    mkdirSync(dst, { recursive: true, mode: 0o700 });
    for (const file of ["meta.json", "session.sqlite", "session.sqlite-wal", "session.sqlite-shm"])
      if (existsSync(join(src, file))) copyFileSync(join(src, file), join(dst, file));
    await stopServer(f);

    const { harness, root } = await startServer(f, crashedDir);
    await harness.waitForTask(job.taskId, context);
    await root.waitForIdle(context);
    const delivered = await reports(root);
    expect(delivered).toContain("interrupted by a host restart");
    expect(delivered).toContain("previous host or guest process may still be running");
    expect(delivered).toContain("Do not start it again until it is confirmed dead");
    const resumed = (await harness.snapshot(DurableJobs, f.root.id, context))!.jobs[0]!;
    expect(resumed.status).toBe("interrupted");
    expect(resumed.resumed).toBeUndefined();
  });

  it.each([
    { label: "clean guest kill", killSucceeds: true },
    { label: "failed guest kill", killSucceeds: false },
  ])(
    "handles sandbox close ($label) and resumes without an attached VM",
    async ({ killSucceeds }) => {
      const f = await fixture([
        tool("background_job", { action: "start", command: "sleep 60" }),
        answer(),
        answer(),
      ]);
      await f.root.commit(async (tx) => {
        Object.assign(await tx.doc(DurableRuntime, f.root.id), {
          kind: "sandbox",
          workspaceId: "ws-1",
        });
      }, context);
      const { vm, started } = sandboxVm(killSucceeds);
      f.host.bindSandboxEnv(f.root.id, new GondolinExecutionEnv(vm, "ws-1", "/workspace"));
      await prompt(f.root);
      await started;
      const job = (await f.harness.snapshot(DurableJobs, f.root.id, context))!.jobs[0]!;

      if (killSucceeds) await stopServer(f);
      else await expect(stopServer(f)).rejects.toThrow("Failed to kill durable sandbox guest work");
      expect(existsSync(join(durableStoreDir(f.dir, STORE_ID), ".clean-close"))).toBe(killSucceeds);

      // Reopen without bindSandboxEnv: clean-close resolves by runtime+context, never by env.
      const { harness, root } = await startServer(f);
      await harness.waitForTask(job.taskId, context);
      await root.waitForIdle(context);
      const delivered = await reports(root);
      if (killSucceeds) {
        expect(delivered).toContain(`Background job bash-1 ${CLEAN_STOP_TEXT}`);
        expect(delivered).not.toContain("may still be running");
      } else {
        expect(delivered).toContain("previous host or guest process may still be running");
        expect(delivered).toContain("Do not start it again until it is confirmed dead");
      }
    },
  );
});
