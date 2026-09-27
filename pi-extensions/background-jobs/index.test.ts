import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AssistantMessageEventStream, type AssistantMessage } from "@earendil-works/pi-ai";
import {
	createAgentSession,
	DefaultResourceLoader,
	ModelRuntime,
	SessionManager,
	SettingsManager,
	type AgentSession,
} from "@earendil-works/pi-coding-agent";

// Real Pi lifecycle + real shell jobs; only the provider is a deterministic fixture.
// Run with bun test pi-extensions/background-jobs, with the Pi peer dependencies available.
const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
	for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

function deferred<T>() {
	let resolve!: (value: T) => void;
	const promise = new Promise<T>((done) => { resolve = done; });
	return { promise, resolve };
}

const nextTick = () => new Promise<void>((resolve) => setImmediate(resolve));

async function fixture(jobCount = 1, tool: "background_job" | "bash" = "background_job") {
	const dir = await mkdtemp(join(tmpdir(), "background-busy-"));
	cleanups.push(() => rm(dir, { recursive: true, force: true }));
	const sockets = new Set<Socket>();
	const connections = Array.from({ length: jobCount }, () => deferred<Socket>());
	let connected = 0;
	const socketPath = join(dir, "jobs.sock");
	const server = createServer((socket) => {
		sockets.add(socket);
		socket.on("error", () => {});
		socket.on("close", () => sockets.delete(socket));
		connections[connected++]?.resolve(socket);
	});
	await new Promise<void>((resolve, reject) => {
		server.once("error", reject);
		server.listen(socketPath, resolve);
	});
	cleanups.push(async () => {
		for (const socket of sockets) socket.destroy();
		await new Promise<void>((resolve) => server.close(() => resolve()));
	});

	const waiting = deferred<void>();
	const afterResult = deferred<void>();
	const errors: string[] = [];
	const observed: string[] = [];
	let requests = 0;
	let session: AgentSession;
	const command = `node -e ${JSON.stringify(
		`const s=require('node:net').connect(${JSON.stringify(socketPath)}); s.on('data',d=>{process.stdout.write(d);s.end();});`,
	)}`;
	const settings = SettingsManager.inMemory({
		compaction: { enabled: false }, retry: { enabled: false },
	});
	const runtime = await ModelRuntime.create({
		authPath: join(dir, "auth.json"), modelsPath: null,
		modelsStorePath: join(dir, "models.json"), refreshOnCreate: false,
	});
	runtime.registerProvider("background-test", {
		api: "openai-completions", apiKey: "test-only", baseUrl: "https://unused.invalid",
		models: [{
			id: "fixture", name: "Fixture", reasoning: false, input: ["text"],
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
			contextWindow: 128_000, maxTokens: 1024,
		}],
		streamSimple(model) {
			requests += 1;
			const tools = requests === 1 && jobCount > 0;
			const text = requests <= 2 ? "Waiting for the job" : "Processed results";
			const message: AssistantMessage = {
				role: "assistant", api: model.api, provider: model.provider, model: model.id,
				content: tools
					? Array.from({ length: jobCount }, (_, index) => ({
						type: "toolCall" as const, id: `start-${index}`, name: tool,
						arguments: tool === "bash" ? { command: `${command} &` } : { action: "start", command },
					}))
					: [{ type: "text", text }],
				stopReason: tools ? "toolUse" : "stop", timestamp: Date.now(),
				usage: {
					input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
					cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
				},
			};
			const stream = new AssistantMessageEventStream();
			stream.push({ type: "done", reason: message.stopReason, message });
			stream.end(message);
			return stream;
		},
	});
	const loader = new DefaultResourceLoader({
		cwd: dir, agentDir: dir, settingsManager: settings,
		noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true,
		additionalExtensionPaths: [join(import.meta.dir, "index.ts")],
		systemPromptOverride: () => "Test fixture.", agentsFilesOverride: () => ({ agentsFiles: [] }),
	});
	await loader.reload();
	expect(loader.getExtensions().errors).toEqual([]);
	const created = await createAgentSession({
		cwd: dir, agentDir: dir, modelRuntime: runtime,
		model: runtime.getModel("background-test", "fixture"), thinkingLevel: "off",
		resourceLoader: loader, settingsManager: settings,
		sessionManager: SessionManager.inMemory(dir), tools: ["background_job", "bash"],
	});
	session = created.session;
	await session.bindExtensions({ onError: (error) => errors.push(error.error) });
	session.subscribe((event) => {
		observed.push(event.type);
		if (event.type !== "message_end" || event.message.role !== "assistant" || event.message.stopReason !== "stop") return;
		if (requests <= 2) waiting.resolve();
		else afterResult.resolve();
	});
	cleanups.push(async () => {
		// Release shells even when an assertion fails, then let their result handlers drain.
		for (const socket of sockets) socket.end("cleanup\n");
		await session.abort();
		await session.extensionRunner.emit({ type: "session_shutdown" });
		session.dispose();
	});
	return {
		session, waiting: waiting.promise, afterResult: afterResult.promise, connections,
		errors, observed, requests: () => requests,
		results: () => session.messages.filter((message) =>
			message.role === "custom" && message.customType === "background-job"),
	};
}

describe("background jobs keep Pi busy", () => {
	test.each(["background_job", "bash"] as const)("%s waits without a provider request, handles each result, then settles once", async (tool) => {
		const f = await fixture(2, tool);
		const run = f.session.prompt("Start the builds");
		await f.waiting;
		const toolResults = f.session.messages.filter((message) => message.role === "toolResult");
		expect(toolResults).toHaveLength(2);
		expect(toolResults.filter((message) => message.isError)).toEqual([]);
		const sockets = await Promise.all(f.connections.map((connection) => connection.promise));
		await nextTick();
		expect(f.session.isStreaming).toBe(true);
		expect(f.observed).not.toContain("agent_settled");
		expect(f.requests()).toBe(2);

		sockets[0]!.end("first build passed\n");
		await f.afterResult;
		await nextTick();
		expect(f.session.isStreaming).toBe(true);
		expect(f.observed).not.toContain("agent_settled");
		expect(f.results()).toHaveLength(1);

		sockets[1]!.end("second build passed\n");
		await run;
		expect(f.session.isIdle).toBe(true);
		expect(f.results()).toHaveLength(2);
		const contents = f.results().map((message) => message.content).join("\n");
		expect(contents).toContain("first build passed");
		expect(contents).toContain("second build passed");
		expect(f.observed.filter((event) => event === "agent_settled")).toHaveLength(1);
		expect(f.requests()).toBe(4);
		expect(f.errors).toEqual([]);
	}, 10_000);

	test("Stop interrupts the wait without waiting for the shell or requesting a model turn", async () => {
		const f = await fixture();
		const run = f.session.prompt("Start a build");
		await f.connections[0]!.promise;
		await f.waiting;
		await nextTick();
		expect(f.session.isStreaming).toBe(true);
		await f.session.abort();
		await run;
		expect(f.session.isIdle).toBe(true);
		expect(f.requests()).toBe(2);
		expect(f.results()).toHaveLength(0);
		expect(f.errors).toEqual([]);
	}, 10_000);

	test.each(["steer", "followUp"] as const)("%s interrupts the wait while unfinished jobs still keep the next turn busy", async (method) => {
		const f = await fixture();
		const run = f.session.prompt("Start a build");
		const socket = await f.connections[0]!.promise;
		await f.waiting;
		await nextTick();
		await f.session[method]("Change direction");
		await f.afterResult;
		await nextTick();
		expect(f.session.isStreaming).toBe(true);
		expect(f.requests()).toBe(3);
		expect(f.observed).not.toContain("agent_settled");
		socket.end("build done\n");
		await run;
		expect(f.results()).toHaveLength(1);
		expect(f.errors).toEqual([]);
	}, 10_000);

	test("shutdown releases the wait and aborts the shell without a continuation", async () => {
		const f = await fixture();
		const run = f.session.prompt("Start a build");
		const socket = await f.connections[0]!.promise;
		const disconnected = new Promise<void>((resolve) => socket.once("close", resolve));
		await f.waiting;
		await nextTick();
		expect(f.session.isStreaming).toBe(true);
		await f.session.extensionRunner.emit({ type: "session_shutdown" });
		await run;
		await disconnected;
		expect(f.session.isIdle).toBe(true);
		expect(f.requests()).toBe(2);
		expect(f.results()).toHaveLength(0);
		expect(f.errors).toEqual([]);
	}, 10_000);

	test("a session with no jobs settles normally", async () => {
		const f = await fixture(0);
		await f.session.prompt("Nothing to run");
		expect(f.session.isIdle).toBe(true);
		expect(f.requests()).toBe(1);
		expect(f.observed.filter((event) => event === "agent_settled")).toHaveLength(1);
		expect(f.errors).toEqual([]);
	}, 10_000);
});
