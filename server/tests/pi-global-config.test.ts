import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { Worker } from "node:worker_threads";

import { getDocsPath, getExamplesPath, getReadmePath } from "@earendil-works/pi-coding-agent";
import { afterEach, describe, expect, it } from "vitest";

const settingsManagerHref = pathToFileURL(
  join(
    dirname(fileURLToPath(import.meta.url)),
    "../node_modules/@earendil-works/pi-coding-agent/dist/core/settings-manager.js",
  ),
).href;

import {
  PI_BUILTIN_TOOL_NAMES,
  readPiDefaultTools,
  readPiSystemPrompt,
  writePiDefaultTools,
} from "../src/pi-global-config.js";

const fixtures: string[] = [];

function makeAgentDir(): string {
  const root = mkdtempSync(join(tmpdir(), "oppi-pi-global-config-"));
  const agentDir = join(root, ".pi", "agent");
  mkdirSync(agentDir, { recursive: true });
  fixtures.push(root);
  return agentDir;
}

afterEach(() => {
  for (const root of fixtures.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

describe("Pi global system prompt", () => {
  it("returns the built-in default template when SYSTEM.md is missing", () => {
    const agentDir = makeAgentDir();

    const snapshot = readPiSystemPrompt(agentDir);

    expect(snapshot.source).toBe("default");
    expect(snapshot.path).toBe("~/.pi/agent/SYSTEM.md");
    expect(snapshot.resolvedPath).toBeUndefined();
    expect(snapshot.content).toContain("You are an expert coding assistant operating inside pi");
    expect(snapshot.content).toContain(`Main documentation: ${getReadmePath()}`);
    expect(snapshot.content).toContain(`Additional docs: ${getDocsPath()}`);
    expect(snapshot.content).toContain(`Examples: ${getExamplesPath()}`);
    expect(snapshot.content).toContain("- read: Read file contents");
    expect(snapshot.content).toContain("- bash: Execute bash commands");
    expect(snapshot.content).not.toContain("Current working directory:");
    expect(snapshot.content).not.toContain("<project_context>");
    expect(snapshot.content).not.toMatch(/<project_instructions[\s\S]*AGENTS\.md/);
  });

  it("returns live SYSTEM.md contents when the file exists", () => {
    const agentDir = makeAgentDir();
    writeFileSync(join(agentDir, "SYSTEM.md"), "# Custom Pi prompt\nBe terse.\n");

    const snapshot = readPiSystemPrompt(agentDir);

    expect(snapshot).toEqual({
      source: "file",
      path: "~/.pi/agent/SYSTEM.md",
      resolvedPath: join(agentDir, "SYSTEM.md"),
      content: "# Custom Pi prompt\nBe terse.\n",
    });
  });
});

describe("Pi defaultTools persistence", () => {
  it("treats a missing defaultTools key as inherit", () => {
    const agentDir = makeAgentDir();
    writeFileSync(
      join(agentDir, "settings.json"),
      JSON.stringify({ defaultProvider: "openai", theme: "dark" }, null, 2),
    );

    expect(readPiDefaultTools(agentDir)).toEqual({ defaultTools: null });
  });

  it("returns an empty array as an exact empty selection", () => {
    const agentDir = makeAgentDir();
    writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ defaultTools: [] }, null, 2));

    expect(readPiDefaultTools(agentDir)).toEqual({ defaultTools: [] });
  });

  it("writes only defaultTools and preserves every other key", () => {
    const agentDir = makeAgentDir();
    writeFileSync(
      join(agentDir, "settings.json"),
      JSON.stringify(
        {
          defaultProvider: "anthropic",
          packages: ["oppi-voice"],
          defaultTools: ["read"],
          theme: "dark",
        },
        null,
        2,
      ),
    );

    const snapshot = writePiDefaultTools(agentDir, ["read", "grep"]);
    const persisted = JSON.parse(readFileSync(join(agentDir, "settings.json"), "utf8")) as Record<
      string,
      unknown
    >;

    expect(snapshot).toEqual({ defaultTools: ["read", "grep"] });
    expect(Object.keys(persisted)).toEqual([
      "defaultProvider",
      "packages",
      "defaultTools",
      "theme",
    ]);
    expect(persisted).toEqual({
      defaultProvider: "anthropic",
      packages: ["oppi-voice"],
      defaultTools: ["read", "grep"],
      theme: "dark",
    });
  });

  it("omits defaultTools on inherit without rewriting other keys", () => {
    const agentDir = makeAgentDir();
    writeFileSync(
      join(agentDir, "settings.json"),
      JSON.stringify(
        {
          defaultProvider: "anthropic",
          defaultTools: ["bash"],
          theme: "dark",
        },
        null,
        2,
      ),
    );

    expect(writePiDefaultTools(agentDir, null)).toEqual({ defaultTools: null });
    expect(JSON.parse(readFileSync(join(agentDir, "settings.json"), "utf8"))).toEqual({
      defaultProvider: "anthropic",
      theme: "dark",
    });
  });

  it("allows an exact empty array", () => {
    const agentDir = makeAgentDir();
    writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ theme: "dark" }, null, 2));

    expect(writePiDefaultTools(agentDir, [])).toEqual({ defaultTools: [] });
    expect(JSON.parse(readFileSync(join(agentDir, "settings.json"), "utf8"))).toEqual({
      theme: "dark",
      defaultTools: [],
    });
  });

  it("rejects powershell and unknown names", () => {
    const agentDir = makeAgentDir();
    writeFileSync(
      join(agentDir, "settings.json"),
      JSON.stringify({ defaultProvider: "openai", defaultTools: ["read"] }, null, 2),
    );

    expect(() => writePiDefaultTools(agentDir, ["powershell"])).toThrow(/built-in/i);
    expect(() => writePiDefaultTools(agentDir, ["read", "not-a-tool"])).toThrow(/built-in/i);
    expect(JSON.parse(readFileSync(join(agentDir, "settings.json"), "utf8"))).toEqual({
      defaultProvider: "openai",
      defaultTools: ["read"],
    });
  });

  it("exposes the built-in catalog without powershell", () => {
    expect([...PI_BUILTIN_TOOL_NAMES]).toEqual([
      "read",
      "bash",
      "edit",
      "write",
      "grep",
      "find",
      "ls",
    ]);
  });

  it("coordinates with a concurrent FileSettingsStorage writer and preserves other keys", async () => {
    const agentDir = makeAgentDir();
    writeFileSync(
      join(agentDir, "settings.json"),
      JSON.stringify(
        {
          defaultProvider: "openai",
          packages: ["oppi-voice"],
          theme: "dark",
        },
        null,
        2,
      ),
    );

    const worker = new Worker(
      `
import { parentPort, workerData } from "node:worker_threads";
import { FileSettingsStorage } from ${JSON.stringify(settingsManagerHref)};

const storage = new FileSettingsStorage(workerData.agentDir, workerData.agentDir);
storage.withLock("global", (current) => {
  parentPort.postMessage("locked");
  const parsed = JSON.parse(current);
  parsed.theme = "light";
  parsed.defaultProvider = "anthropic";
  const start = Date.now();
  while (Date.now() - start < 80) {}
  return JSON.stringify(parsed, null, 2);
});
parentPort.postMessage("done");
`,
      { eval: true, type: "module", workerData: { agentDir } },
    );
    const pending = queuedWorkerMessages(worker);

    try {
      await pending.next("locked");
      writePiDefaultTools(agentDir, ["read", "grep"]);
      await pending.next("done");
    } finally {
      pending.stop();
      await worker.terminate();
    }

    expect(JSON.parse(readFileSync(join(agentDir, "settings.json"), "utf8"))).toEqual({
      defaultProvider: "anthropic",
      packages: ["oppi-voice"],
      theme: "light",
      defaultTools: ["read", "grep"],
    });
  });
});

function queuedWorkerMessages(worker: Worker): {
  next: (expected: string) => Promise<void>;
  stop: () => void;
} {
  const queue: unknown[] = [];
  let wake: (() => void) | undefined;
  let failed: Error | undefined;
  const onMessage = (message: unknown): void => {
    queue.push(message);
    wake?.();
  };
  const onError = (error: Error): void => {
    failed = error;
    wake?.();
  };
  worker.on("message", onMessage);
  worker.on("error", onError);
  return {
    async next(expected: string) {
      for (;;) {
        if (failed) throw failed;
        if (queue.length > 0) {
          const message = queue.shift();
          if (message === expected) return;
          throw new Error(`unexpected worker message: ${String(message)}`);
        }
        await new Promise<void>((resolve) => {
          wake = resolve;
        });
      }
    },
    stop() {
      worker.off("message", onMessage);
      worker.off("error", onError);
    },
  };
}
