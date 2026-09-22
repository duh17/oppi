import { describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import {
	awaitForegroundOrBackground,
	BACKGROUND_POLICY,
	backgroundDisposition,
	backgroundPill,
	bashBackgroundAdvice,
	createJobManager,
	formatBackgroundNotice,
	type JobExecRequest,
	runBackgroundPolicy,
	wrapBackgroundCommand,
} from "./jobs.ts";

type PendingExec = JobExecRequest & {
	resolve: (result: { exitCode: number | null }) => void;
	reject: (error: Error) => void;
};

function deferredRunner() {
	const pending: PendingExec[] = [];
	return {
		pending,
		exec(request: JobExecRequest) {
			return new Promise<{ exitCode: number | null }>((resolve, reject) => {
				pending.push({ ...request, resolve, reject });
			});
		},
	};
}

function managerWith(runner: ReturnType<typeof deferredRunner>, extra: Parameters<typeof createJobManager>[0] = {}) {
	const deliveries: string[] = [];
	const manager = createJobManager({
		exec: (request) => runner.exec(request),
		onDeliver: (delivery) => deliveries.push(delivery.text),
		now: () => 1_000,
		...extra,
	});
	return { manager, deliveries };
}

describe("background job notice", () => {
	test("tells the model the result is injected and polling wastes a turn", () => {
		const notice = formatBackgroundNotice("bash-1");
		expect(notice).toContain("bash-1");
		expect(notice).toContain("follow-up");
		expect(notice).toContain("Do NOT poll");
		expect(notice).toContain("sleep");
		expect(notice).toContain("end your reply");
	});
});

describe("bash background advice", () => {
	test("blocks polls only while a job is running", () => {
		expect(bashBackgroundAdvice("npm test &", false)).toBeUndefined();
		expect(bashBackgroundAdvice("npm test && echo done", false)).toBeUndefined();
		expect(bashBackgroundAdvice("cmd >& /tmp/out", false)).toBeUndefined();
		expect(bashBackgroundAdvice("sleep 2", false)).toBeUndefined();
		expect(bashBackgroundAdvice("sleep 2", true)).toContain("Do NOT poll");
		expect(bashBackgroundAdvice("ps aux", true)).toContain("Do NOT poll");
		expect(bashBackgroundAdvice("sleep 1 && pgrep npm", true)).toContain("Do NOT poll");
		expect(bashBackgroundAdvice("tail -f /tmp/build.log", true)).toContain("Do NOT poll");
		expect(bashBackgroundAdvice("tail -n 20 /tmp/build.log", true)).toBeUndefined();
		expect(bashBackgroundAdvice("printf hi", true)).toBeUndefined();
	});
});

describe("background command wrapping", () => {
	test("quotes session exports and keeps a shell prefix ahead of the command", () => {
		const wrapped = wrapBackgroundCommand("printf hi", {
			prefix: "source ~/.profile",
			session: {
				sessionId: "sess-1",
				provider: "openai",
				model: "gpt-5'o",
				reasoning: "high",
			},
		});
		expect(wrapped).toContain("export PI_SESSION_ID='sess-1'");
		expect(wrapped).toContain("export OPPI_CALLER_SESSION_ID='sess-1'");
		expect(wrapped).toContain("export PI_PROVIDER='openai'");
		expect(wrapped).toContain("export PI_MODEL='gpt-5'\\''o'");
		expect(wrapped).toContain("export PI_REASONING_LEVEL='high'");
		expect(wrapped.indexOf("source ~/.profile")).toBeLessThan(wrapped.indexOf("printf hi"));
		expect(wrapped.indexOf("export PI_MODEL")).toBeLessThan(wrapped.indexOf("printf hi"));
	});
});

describe("background policy", () => {
	test("waits 15s, backgrounds a trailing ampersand immediately, and keeps a short timeout in the foreground", () => {
		expect(BACKGROUND_POLICY.foregroundWaitMs).toBe(15_000);
		expect(backgroundDisposition("printf hi")).toEqual({
			mode: "after-wait",
			command: "printf hi",
			waitMs: 15_000,
		});
		expect(backgroundDisposition("npm test &")).toEqual({
			mode: "immediate",
			command: "npm test",
			waitMs: 0,
		});
		expect(backgroundDisposition("slow", { timeoutSeconds: 5 }).waitMs).toBe(4_000);
		expect(backgroundDisposition("slow", { timeoutSeconds: 1 })).toMatchObject({
			mode: "foreground-only",
		});
		expect(backgroundDisposition("cmd >& /tmp/out").mode).toBe("after-wait");
	});

	test("a command that finishes inside the window is not a background job and does not wake later", async () => {
		const runner = deferredRunner();
		const { manager, deliveries } = managerWith(runner);
		const started = manager.start({
			command: "printf hi",
			cwd: "/tmp",
			holdDelivery: true,
			backgrounded: false,
		});
		if (!("settled" in started)) throw new Error("expected a started job");
		runner.pending[0]?.onData(Buffer.from("hi\n"));
		runner.pending[0]?.resolve({ exitCode: 0 });
		const result = await awaitForegroundOrBackground({
			started,
			waitMs: 15_000,
			wait: () => new Promise(() => {}),
		});
		expect(result.kind).toBe("foreground");
		if (result.kind !== "foreground") return;
		expect(result.text).toContain("hi");
		expect(result.isError).toBe(false);
		expect(deliveries).toHaveLength(0);
		expect(manager.visibleRunning()).toHaveLength(0);
	});

	test("a command still running after the window becomes a visible background job", async () => {
		const runner = deferredRunner();
		const { manager, deliveries } = managerWith(runner);
		const started = manager.start({
			command: "npm test",
			cwd: "/tmp",
			holdDelivery: true,
			backgrounded: false,
		});
		if (!("settled" in started)) throw new Error("expected a started job");
		let releaseWait: () => void = () => {};
		const resultPromise = awaitForegroundOrBackground({
			started,
			waitMs: 15_000,
			wait: () => new Promise((resolve) => {
				releaseWait = resolve;
			}),
		});
		expect(manager.visibleRunning()).toHaveLength(0);
		releaseWait();
		const result = await resultPromise;
		expect(result).toMatchObject({ kind: "background", jobId: "bash-1" });
		expect(manager.visibleRunning().map((job) => job.id)).toEqual(["bash-1"]);
		runner.pending[0]?.resolve({ exitCode: 0 });
		await started.settled;
		expect(deliveries).toHaveLength(1);
		expect(manager.visibleRunning()).toHaveLength(0);
	});

	test("a full job slot falls back to a foreground run instead of failing the command", async () => {
		const runner = deferredRunner();
		const { manager, deliveries } = managerWith(runner, { maxRunning: 1 });
		manager.start({ command: "already running", cwd: "/tmp" });
		const resultPromise = runBackgroundPolicy({
			manager,
			exec: (request) => runner.exec(request),
			command: "printf hi",
			cwd: "/tmp",
		});
		expect(runner.pending).toHaveLength(2);
		runner.pending[1]?.onData(Buffer.from("hi\n"));
		runner.pending[1]?.resolve({ exitCode: 0 });
		const result = await resultPromise;
		expect(result).toMatchObject({ backgrounded: false, isError: false });
		expect(result.text).toContain("hi");
		expect(deliveries).toHaveLength(0);
		expect(manager.visibleRunning()).toHaveLength(1);
	});

	test("an abort during the foreground window cancels the process and does not leave a pill", async () => {
		const runner = deferredRunner();
		const { manager, deliveries } = managerWith(runner);
		const started = manager.start({
			command: "slow",
			cwd: "/tmp",
			holdDelivery: true,
			backgrounded: false,
		});
		if (!("settled" in started)) throw new Error("expected a started job");
		const signal = AbortSignal.abort();
		const result = await awaitForegroundOrBackground({
			started,
			waitMs: 15_000,
			signal,
			wait: (_ms, abortSignal) =>
				new Promise((_resolve, reject) => {
					if (abortSignal?.aborted) reject(new Error("aborted"));
				}),
		});
		expect(result.kind).toBe("aborted");
		expect(runner.pending[0]?.signal.aborted).toBe(true);
		runner.pending[0]?.reject(new Error("aborted"));
		await started.settled;
		expect(deliveries).toHaveLength(0);
		expect(manager.visibleRunning()).toHaveLength(0);
	});
});

describe("background pill", () => {
	test("shows one running job and hides when nothing is backgrounded", () => {
		expect(backgroundPill([])).toBeUndefined();
		expect(
			backgroundPill([
				{ id: "bash-1", command: "npm test", status: "running", backgrounded: false },
			]),
		).toBeUndefined();
		const pill = backgroundPill([
			{ id: "bash-1", command: "npm test", status: "running", backgrounded: true },
			{ id: "bash-2", command: "go test ./...", status: "running", backgrounded: true },
		]);
		expect(pill?.title).toBe("2 jobs");
		expect(pill?.status).toContain("npm test");
		expect(pill?.rows.map((row) => row.title)).toEqual(["bash-1", "bash-2"]);
		expect(pill?.rows.map((row) => row.state)).toEqual(["running", "running"]);
		expect(pill?.terminal).toEqual([]);
	});

	test("keeps the pill label short and shows an output tail", () => {
		const pill = backgroundPill([
			{
				id: "bash-52",
				command: "prompt_file=/Users/chenda/workspace/oppi/.pi/cursor-consults/review.prompt.md",
				status: "running",
				backgrounded: true,
				output: "line one\nline two\n",
			},
		]);
		expect(pill?.rows[0]?.title).toBe("bash-52");
		expect(pill?.rows[0]?.subtitle.startsWith("prompt_file=")).toBe(true);
		expect(pill?.rows[0]?.subtitle.length).toBeLessThanOrEqual(48);
		expect(pill?.terminal).toEqual(["# bash-52", "line one", "line two"]);
	});
});

describe("job manager", () => {
	test("returns a notice immediately and delivers the output once when the command exits", async () => {
		const runner = deferredRunner();
		const { manager, deliveries } = managerWith(runner);
		const started = manager.start({ command: "printf hi", cwd: "/tmp" });
		expect("error" in started).toBe(false);
		if ("error" in started) return;
		expect(started.jobId).toBe("bash-1");
		expect(started.notice).toContain("Do NOT poll");
		expect(deliveries).toHaveLength(0);
		expect(runner.pending).toHaveLength(1);

		runner.pending[0]?.onData(Buffer.from("hi\n"));
		runner.pending[0]?.resolve({ exitCode: 0 });
		await Promise.resolve();

		expect(deliveries).toHaveLength(1);
		expect(deliveries[0]).toContain("bash-1 finished (exit 0)");
		expect(deliveries[0]).toContain("hi");
		expect(deliveries[0]).toContain("Do not poll");
	});

	test("delivers a non-zero exit as a failure, not a second success", async () => {
		const runner = deferredRunner();
		const { manager, deliveries } = managerWith(runner);
		manager.start({ command: "false", cwd: "/tmp" });
		runner.pending[0]?.onData(Buffer.from("boom\n"));
		runner.pending[0]?.resolve({ exitCode: 2 });
		runner.pending[0]?.resolve({ exitCode: 0 });
		await Promise.resolve();

		expect(deliveries).toHaveLength(1);
		expect(deliveries[0]).toContain("failed (exit 2)");
		expect(deliveries[0]).toContain("boom");
	});

	test("cancel wins over a later successful exit and does not deliver twice", async () => {
		const runner = deferredRunner();
		const { manager, deliveries } = managerWith(runner);
		const started = manager.start({ command: "sleep 30", cwd: "/tmp" });
		if ("error" in started) throw new Error(started.error);
		const cancelled = manager.cancel(started.jobId);
		expect(cancelled.ok).toBe(true);
		expect(runner.pending[0]?.signal.aborted).toBe(true);
		runner.pending[0]?.resolve({ exitCode: 0 });
		await Promise.resolve();

		expect(deliveries).toHaveLength(1);
		expect(deliveries[0]).toContain("cancelled");
		expect(deliveries[0]).not.toContain("finished (exit 0)");
		expect(manager.cancel(started.jobId).ok).toBe(false);
	});

	test("shutdown aborts running jobs without waking the agent", async () => {
		const runner = deferredRunner();
		const { manager, deliveries } = managerWith(runner);
		manager.start({ command: "sleep 30", cwd: "/tmp" });
		manager.shutdown();
		expect(runner.pending[0]?.signal.aborted).toBe(true);
		runner.pending[0]?.reject(new Error("aborted"));
		await Promise.resolve();
		expect(deliveries).toHaveLength(0);
		const after = manager.start({ command: "printf hi", cwd: "/tmp" });
		expect(after).toEqual({ error: expect.stringContaining("shut down") });
	});

	test("rejects an empty command and a full job slot without starting another process", () => {
		const runner = deferredRunner();
		const { manager } = managerWith(runner, { maxRunning: 1 });
		expect(manager.start({ command: "   ", cwd: "/tmp" })).toEqual({
			error: expect.stringContaining("command"),
		});
		expect(manager.start({ command: "ok", cwd: "/tmp", timeout: 0 })).toEqual({
			error: expect.stringContaining("timeout"),
		});
		expect(runner.pending).toHaveLength(0);

		expect("error" in manager.start({ command: "ok", cwd: "/tmp" })).toBe(false);
		expect(manager.start({ command: "again", cwd: "/tmp" })).toEqual({
			error: expect.stringContaining("Do not poll"),
		});
		expect(runner.pending).toHaveLength(1);
	});

	test("keeps only the tail when output exceeds the stored limit", async () => {
		const runner = deferredRunner();
		const { manager, deliveries } = managerWith(runner, { maxStoredChars: 4 });
		manager.start({ command: "yes", cwd: "/tmp" });
		runner.pending[0]?.onData(Buffer.from("abcdefghij"));
		runner.pending[0]?.resolve({ exitCode: 0 });
		await Promise.resolve();
		expect(deliveries[0]).toContain("ghij");
		expect(deliveries[0]).not.toContain("abcd");
		expect(deliveries[0]).toContain("truncated");
	});

	test("reports a runner timeout with the partial output", async () => {
		const runner = deferredRunner();
		const { manager, deliveries } = managerWith(runner);
		manager.start({ command: "slow", cwd: "/tmp", timeout: 30 });
		runner.pending[0]?.onData(Buffer.from("partial"));
		runner.pending[0]?.reject(new Error("timeout:30"));
		await Promise.resolve();
		expect(deliveries[0]).toContain("timed out after 30 seconds");
		expect(deliveries[0]).toContain("partial");
	});
});

describe("job manager process delivery", () => {
	test("delivers real shell output without a sleep", async () => {
		let delivered = "";
		let resolveDelivery: (text: string) => void = () => {};
		const delivery = new Promise<string>((resolve) => {
			resolveDelivery = resolve;
		});
		const manager = createJobManager({
			exec: (request) =>
				new Promise((resolve, reject) => {
					const child = spawn("/bin/bash", ["-lc", request.command], {
						cwd: request.cwd,
						env: process.env,
					});
					const onAbort = () => child.kill("SIGKILL");
					request.signal.addEventListener("abort", onAbort, { once: true });
					child.stdout?.on("data", (chunk) => request.onData(chunk));
					child.stderr?.on("data", (chunk) => request.onData(chunk));
					child.once("error", reject);
					child.once("close", (code) => {
						request.signal.removeEventListener("abort", onAbort);
						if (request.signal.aborted) {
							reject(new Error("aborted"));
							return;
						}
						resolve({ exitCode: code });
					});
				}),
			onDeliver: (result) => {
				delivered = result.text;
				resolveDelivery(result.text);
			},
		});

		const started = manager.start({ command: "printf 'hello-job'", cwd: process.cwd() });
		expect("error" in started).toBe(false);
		await delivery;
		expect(delivered).toContain("hello-job");
		expect(delivered).toContain("finished (exit 0)");
	});
});
