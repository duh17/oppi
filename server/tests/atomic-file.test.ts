import { mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { FileLiveActivityStateStore } from "../src/live-activity-state-store.js";
import {
  materializeToolMediaContentBlocks,
  storeUserMessageImages,
} from "../src/session-attachments.js";
import { writeFileAtomic, type AtomicWriteStep } from "../src/storage/atomic-file.js";
import { extractAutoTitle } from "../src/storage/auto-title-extension-migration.js";
import { DictationDictionaryStore } from "../src/storage/dictation-dictionary-store.js";
import { FileVoiceCallStore } from "../src/voice-call-store.js";
import { makeTempDir } from "./harness/temp-dir.js";

/**
 * What every `fsyncSync` in the process synced, in order; `failDirectory` fails the directory's.
 * `failFileClose` fails the next file close the way the kernel does: the descriptor is released.
 */
const sync = vi.hoisted(() => ({
  calls: [] as Array<"file" | "directory">,
  failDirectory: false,
  failFileClose: false,
}));

vi.mock("node:fs", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs")>();
  return {
    ...actual,
    fsyncSync(fd: number) {
      const kind = actual.fstatSync(fd).isDirectory() ? "directory" : "file";
      sync.calls.push(kind);
      if (kind === "directory" && sync.failDirectory) throw new Error("EIO: directory sync");
      actual.fsyncSync(fd);
    },
    closeSync(fd: number) {
      const failing = sync.failFileClose && actual.fstatSync(fd).isFile();
      actual.closeSync(fd);
      if (!failing) return;
      sync.failFileClose = false;
      throw new Error("EIO: close");
    },
  };
});

beforeEach(() => {
  sync.calls = [];
  sync.failDirectory = false;
  sync.failFileClose = false;
});

const leftovers = (dir: string) => readdirSync(dir).filter((name) => name.endsWith(".tmp"));

describe("writeFileAtomic", () => {
  it.each([
    [
      true,
      ["after_temp_write", "after_temp_fsync", "before_rename", "after_rename"],
      ["file", "directory"],
    ],
    [false, ["after_temp_write", "before_rename", "after_rename"], []],
  ])("durable=%s: steps in order, syncs %j, private file, no temp", (durable, steps, synced) => {
    const dir = makeTempDir("oppi-atomic-");
    const seen: AtomicWriteStep[] = [];
    writeFileSync(join(dir, "a"), "old", { mode: 0o644 });

    writeFileAtomic(join(dir, "a"), "new", { durable, onStep: (s) => seen.push(s) });

    expect(seen).toEqual(steps);
    expect(sync.calls).toEqual(synced);
    expect(readFileSync(join(dir, "a"), "utf8")).toBe("new");
    expect(statSync(join(dir, "a")).mode & 0o777).toBe(0o600);
    expect(readdirSync(dir)).toEqual(["a"]);
  });

  it("keeps the old file and removes its temp file when a step, the rename, the close, or the directory sync fails", () => {
    const dir = makeTempDir("oppi-atomic-");
    writeFileSync(join(dir, "a"), "old");
    const onStep = () => {
      throw new Error("stop");
    };
    expect(() => writeFileAtomic(join(dir, "a"), "new", { durable: true, onStep })).toThrow("stop");
    expect(readFileSync(join(dir, "a"), "utf8")).toBe("old");

    mkdirSync(join(dir, "occupied", "child"), { recursive: true });
    expect(() => writeFileAtomic(join(dir, "occupied"), "x", { durable: true })).toThrow();

    sync.failFileClose = true;
    expect(() => writeFileAtomic(join(dir, "a"), "new", { durable: true })).toThrow("EIO: close");
    expect(readFileSync(join(dir, "a"), "utf8")).toBe("old");

    sync.failDirectory = true;
    expect(() => writeFileAtomic(join(dir, "b"), "x", { durable: true })).toThrow("directory sync");
    expect(leftovers(dir)).toEqual([]);
  });
});

// Each caller below used to differ from the winner in one way; these pin what it does now.
describe("writers that share writeFileAtomic", () => {
  it("fails a dictionary write whose directory cannot be synced (it used to ignore that)", () => {
    const store = new DictationDictionaryStore(makeTempDir("oppi-atomic-dict-"));
    sync.failDirectory = true;

    expect(() => store.add(null, "Yuwp")).toThrow(/write failed/);
  });

  // Each writer used to sync only the file, or nothing.
  it.each([
    ["live activity state", (dir: string) => saveLiveActivity(dir), 1],
    ["voice calls", (dir: string) => new FileVoiceCallStore(join(dir, "s.json")).save([]), 1],
    ["auto-title carry-over and config", (dir: string) => extractAutoTitleOf(dir), 2],
    ["stored attachment and manifest", (dir: string) => storeAttachment(dir), 2],
  ])("syncs file then directory for %s", (_name, run, writes) => {
    run(makeTempDir("oppi-atomic-"));

    expect(sync.calls).toEqual(Array(writes).fill(["file", "directory"]).flat());
  });

  it("does not sync again when the same tool image is stored a second time", () => {
    const dataDir = makeTempDir("oppi-atomic-");
    const store = () =>
      materializeToolMediaContentBlocks({
        dataDir,
        sessionId: "s",
        toolCallId: "call-1",
        contents: [{ type: "image", data: "cG5n", mimeType: "image/png" }],
      });

    const first = store();
    const second = store();

    expect(second).toEqual(first);
    expect(sync.calls).toEqual(["file", "directory", "file", "directory"]);
  });
});

const saveLiveActivity = (dir: string) =>
  new FileLiveActivityStateStore(join(dir, "s.json")).save(new Map());

function extractAutoTitleOf(dataDir: string): void {
  const autoTitle = { enabled: true, model: "anthropic/claude-haiku-5" };
  writeFileSync(join(dataDir, "config.json"), JSON.stringify({ port: 1, autoTitle }));
  extractAutoTitle(dataDir);
}

const storeAttachment = (dataDir: string) =>
  storeUserMessageImages({
    dataDir,
    sessionId: "s",
    content: [{ type: "image", data: "cG5n", mimeType: "image/png" }],
  });
