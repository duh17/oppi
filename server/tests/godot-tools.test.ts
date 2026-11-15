import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Readable } from "node:stream";
import { afterEach, describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import {
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall,
  type FauxResponseStep,
} from "@earendil-works/pi-ai/providers/faux";
import { Harness, createRegistry } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";

import { DurableGodot } from "../plugins/godot/server.js";
import { GodotService } from "../src/godot/godot-service.js";
import { GODOT_PANE_CLIENT_CAPABILITY } from "../src/godot/godot-protocol.js";
import type { GodotLinkServerMessage, Session, Workspace } from "../src/types.js";
import { makeTempDir } from "./harness/temp-dir.js";

// The tools run in a bare Harness, which binds no Oppi Session: `oppiHost().godot` answers as
// the server does for the Session "s-1" of workspace "ws".
const bound = vi.hoisted(() => ({ games: undefined as GodotService | undefined }));
vi.mock("oppi/v1", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/oppi-v1.js")>();
  const mocked = {
    ...actual,
    oppiHost: () => ({ godot: async () => bound.games?.forSession("s-1") }),
  };
  return { ...mocked, default: mocked };
});

const PNG = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47]), Buffer.alloc(32, 1)]);
const harnesses = new Set<Harness>();
const services = new Set<GodotService>();
afterEach(async () => {
  await Promise.all([...harnesses].map((h) => h.close(context)));
  harnesses.clear();
  for (const service of services) service.close();
  services.clear();
  bound.games = undefined;
});

/** A game with one release and a scripted player that answers like the app does. */
async function playingGodot() {
  const root = makeTempDir("oppi-godot-tools-");
  const dir = join(root, "tide");
  mkdirSync(join(dir, "build"), { recursive: true });
  writeFileSync(join(dir, "project.godot"), 'config/name="Tide"\n');
  writeFileSync(join(dir, "build", "tide.pck"), Buffer.from("GDPCbytes"));
  const workspace = { id: "ws", hostMount: root, runtime: "host" } as unknown as Workspace;
  const dataDir = makeTempDir("oppi-godot-tools-data-");
  const games = new GodotService({
    listWorkspaces: () => [workspace],
    getWorkspace: () => workspace,
    getSession: (id) => (id === "s-1" ? ({ id, workspaceId: "ws" } as Session) : undefined),
    getDataDir: () => dataDir,
  });
  services.add(games);
  bound.games = games;
  const [project] = await games.list();
  const id = project?.id ?? "";
  const commands: string[] = [];
  const handle = games.link(id, "player", {
    send: (message: GodotLinkServerMessage) => {
      if (message.type !== "command") return;
      const { command } = message;
      commands.push(command.name);
      const answer = (output: Record<string, unknown>) =>
        handle?.receive({ type: "result", id: message.id, ok: true, output });
      if (command.name === "capture") {
        void games.uploadCapture(id, command.captureId, Readable.from([PNG])).then(() =>
          answer({
            captureId: command.captureId,
            mimeType: "image/png",
            width: 744,
            height: 512,
          }),
        );
      } else if (command.name === "input") {
        answer({ steps: command.steps.length, ms: 140 });
      } else if (command.name === "reload") {
        handle?.receive({
          type: "result",
          id: message.id,
          ok: false,
          error: { code: "failed", message: "Parse error at res://player.gd:12" },
        });
      }
    },
    close: () => {},
  });
  handle?.receive({
    type: "attach",
    capabilities: [GODOT_PANE_CLIENT_CAPABILITY],
    device: "Alex's iPad mini",
    runtimes: [{ engine: "godot", formats: ["pck"] }],
    state: { phase: "running", release: 1, tier: "scene", fps: 60 },
  });
  handle?.receive({
    type: "log",
    entries: [
      {
        level: "error",
        message: "Invalid access to property 'velocity'",
        source: { file: "res://player.gd", line: 42, function: "_physics_process" },
        backtrace: [
          { file: "res://player.gd", line: 42, function: "_physics_process" },
          { file: "res://main.gd", line: 12, function: "_ready" },
        ],
      },
    ],
  });
  return { games, id, commands };
}

async function run(steps: FauxResponseStep[]) {
  const dir = makeTempDir("oppi-godot-tools-harness-");
  const models = await ModelRuntime.create({
    authPath: join(dir, "auth.json"),
    modelsPath: null,
    modelsStorePath: join(dir, "models-cache.json"),
    refreshOnCreate: false,
  });
  const faux = fauxProvider();
  faux.setResponses([...steps, fauxAssistantMessage("DONE")]);
  models.registerNativeProvider(faux.provider);
  await models.setRuntimeApiKey("faux", "test-only-faux-credential");
  await models.refresh({ allowNetwork: false });
  const env = new NodeExecutionEnv({ cwd: dir });
  const registry = createRegistry();
  registry.install(DurableGodot);
  const storage = await openNodeSqliteStorage(join(dir, "store.sqlite"));
  const harness = await Harness.open(
    storage,
    { models, registry, env: () => env, settings: { compaction: { enabled: false } } },
    context,
  );
  harnesses.add(harness);
  const conversation = await harness.root(context, {
    agent: { model: { provider: "faux", modelId: "faux-1" }, cwd: dir, extensions: [DurableGodot] },
  });
  const submission = await conversation.submit(
    { type: "input", content: "check the game" },
    context,
  );
  expect((await submission.wait(context)).status).toBe("done");
  await conversation.waitForIdle(context);
  return (await conversation.context(context)).messages.filter((m) => m.role === "toolResult");
}

const call = (name: string, args: Record<string, unknown>): FauxResponseStep =>
  fauxAssistantMessage([fauxToolCall(name, args)], { stopReason: "toolUse" });

function textOf(content: unknown): string {
  return (content as Array<{ type: string; text?: string }>)
    .filter((block) => block.type === "text")
    .map((block) => block.text)
    .join("");
}

describe("game tools", { timeout: 20_000 }, () => {
  it("show the game's state and errors, and its log with file, line, and backtrace", async () => {
    await playingGodot();
    const [status, logs] = await run([
      call("godot_status", {}),
      call("godot_logs", { level: "error" }),
    ]);
    const statusText = textOf(status?.content);
    expect(statusText).toContain("Tide (tide-");
    expect(statusText).toMatch(/Release 1, exported .* ago: pck 1 KB, reload hint scene\./);
    expect(statusText).toContain(
      "(Alex's iPad mini): running, release 1, applied as scene, 60 fps",
    );
    expect(statusText).toContain(
      "Invalid access to property 'velocity' (res://player.gd:42 in _physics_process)",
    );
    const logText = textOf(logs?.content);
    expect(logText).toContain("[error] Invalid access to property 'velocity' (res://player.gd:42");
    expect(logText).toContain("    at _ready (res://main.gd:12)");
    expect(logText).toMatch(/next: \d+$/);
  });

  it("return a capture as an image the model sees", async () => {
    const { commands } = await playingGodot();
    const [capture, input] = await run([
      call("godot_capture", {}),
      call("godot_input", {
        steps: [
          { kind: "tap", at: { x: 0.5, y: 0.8 } },
          { kind: "action", action: "jump", holdMs: 200 },
        ],
        capture: true,
      }),
    ]);
    expect(capture?.isError).toBe(false);
    expect(textOf(capture?.content)).toContain("(744x512)");
    // The pixels travel only as the image block, never as a data URL in the caption.
    expect(textOf(capture?.content)).not.toContain("data:");
    const image = (
      capture?.content as Array<{ type: string; data?: string; mimeType?: string }>
    ).find((block) => block.type === "image");
    expect(image?.mimeType).toBe("image/png");
    expect(Buffer.from(image?.data ?? "", "base64").equals(PNG)).toBe(true);

    expect(textOf(input?.content)).toContain("Sent 2 input steps in 140 ms.");
    expect((input?.content as Array<{ type: string }>).some((b) => b.type === "image")).toBe(true);
    expect(commands).toEqual(["capture", "input", "capture"]);
  });

  it("report a failed reload as an error the model can act on", async () => {
    await playingGodot();
    const [reload, unknown] = await run([
      call("godot_reload", { tier: "scripts" }),
      call("godot_status", { project: "pong" }),
    ]);
    expect(reload?.isError).toBe(true);
    expect(textOf(reload?.content)).toBe(
      "reload failed (failed): Parse error at res://player.gd:12",
    );
    expect(unknown?.isError).toBe(true);
    expect(textOf(unknown?.content)).toMatch(
      /^No game pong in this workspace\.\n- tide-[0-9a-f]{8}: Tide, tide in workspace ws/,
    );
  });
});
