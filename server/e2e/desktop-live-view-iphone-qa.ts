#!/usr/bin/env tsx
/**
 * Isolated live-view QA server: fake companion replays the committed AVCC fixture.
 * Does not touch the user's data dir or companion.sock.
 *
 * Usage:
 *   bun server/e2e/desktop-live-view-iphone-qa.ts
 * Stdin: pause | resume | quit
 */

import { createServer as createNetServer, type Socket } from "node:net";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";

import { desktopCompanionOwnerSocketPath } from "../src/desktop-companion-still-client.js";
import {
  CompanionFrameReader,
  encodeCompanionJson,
  encodeCompanionMedia,
  encodeMediaFrame,
  parseControlJson,
} from "../src/desktop-view-stream-codec.js";
import { generateInvite } from "../src/invite.js";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import {
  DESKTOP_VIEW_FEATURE_H264_AVCC,
  DESKTOP_VIEW_WIRE_VERSION,
} from "../src/types/protocol.js";

type FixtureFrame = {
  frameId: number;
  keyframe: boolean;
  width: number;
  height: number;
  avccHex: string;
};

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "../..");
const fixturePath = join(
  repoRoot,
  "clients/apple/OppiTests/Fixtures/desktop-live-view-avcc.json",
);
const fixture = JSON.parse(readFileSync(fixturePath, "utf8")) as { frames: FixtureFrame[] };
if (!fixture.frames?.length) throw new Error("AVCC fixture is empty");

const dataDir = mkdtempSync(join(tmpdir(), "oppi-dv-iphone-qa-data-"));
const companionRoot = mkdtempSync(join(tmpdir(), "oppi-dv-iphone-qa-comp-"));
mkdirSync(join(companionRoot, "run"), { recursive: true });

let paused = false;
let frameIndex = 0;
let lastPausedSend = 0;
let activeCompanion: Socket | undefined;
const controlPath = process.env.OPPI_DV_QA_CONTROL;

function writeMedia(socket: Socket, encode: Record<string, unknown>): void {
  if (!socket.destroyed && socket.writable) {
    socket.write(encodeCompanionMedia(nextFrame(encode)));
  }
}

function nextFrame(encode: Record<string, unknown>): Buffer {
  const wantKey = encode.keyframe === true || Number(encode.frameId) === 1;
  const frames = fixture.frames;
  let chosen = frames[0]!;
  for (let i = 0; i < frames.length; i += 1) {
    chosen = frames[frameIndex % frames.length]!;
    frameIndex += 1;
    if (!wantKey || chosen.keyframe) break;
  }
  return encodeMediaFrame(
    {
      keyframe: chosen.keyframe || wantKey,
      frameId: Number(encode.frameId) || chosen.frameId,
      capturedAtMs: Date.now(),
      width: chosen.width,
      height: chosen.height,
    },
    Buffer.from(chosen.avccHex, "hex"),
  );
}

if (controlPath) {
  setInterval(() => {
    let command = "";
    try {
      command = readFileSync(controlPath, "utf8").trim();
    } catch {
      command = "";
    }
    if (command === "drop") {
      activeCompanion?.end();
      try {
        writeFileSync(controlPath, "resume\n");
      } catch {
        // ignore
      }
      command = "resume";
    }
    const nowPaused = command === "pause";
    if (paused && !nowPaused && activeCompanion) {
      writeMedia(activeCompanion, { frameId: 1, keyframe: true });
    }
    paused = nowPaused;
  }, 100);
}

async function listenCompanion(runtimeRoot: string): Promise<{ close: () => void }> {
  const path = desktopCompanionOwnerSocketPath(runtimeRoot);
  const server = createNetServer((socket: Socket) => {
    socket.on("error", () => {});
    let buf = Buffer.alloc(0);
    let upgraded = false;
    const reader = new CompanionFrameReader();
    const write = (bytes: Buffer): void => {
      if (!socket.destroyed && socket.writable) socket.write(bytes);
    };
    const handleFrames = (chunk: Buffer): void => {
      for (const frame of reader.push(chunk)) {
        const parsed = parseControlJson(frame.payload);
        if (parsed?.type !== "encode") continue;
        if (paused) {
          setTimeout(() => {
            if (activeCompanion === socket) writeMedia(socket, parsed);
          }, 2_200);
          continue;
        }
        writeMedia(socket, parsed);
      }
    };
    socket.on("data", (chunk) => {
      if (upgraded) {
        handleFrames(chunk);
        return;
      }
      buf = Buffer.concat([buf, chunk]);
      const sep = buf.indexOf("\r\n\r\n");
      if (sep < 0) return;
      const headerText = buf.subarray(0, sep).toString("utf8");
      const leftover = buf.subarray(sep + 4);
      const device =
        headerText
          .split("\r\n")
          .find((line) => line.toLowerCase().startsWith("x-oppi-device-id:"))
          ?.slice("x-oppi-device-id:".length)
          .trim() ?? "qa-phone";
      write(
        Buffer.from(
          "HTTP/1.1 101 Switching Protocols\r\nUpgrade: oppi-desktop-view\r\nConnection: Upgrade\r\n\r\n",
        ),
      );
      upgraded = true;
      activeCompanion = socket;
      socket.on("close", () => {
        if (activeCompanion === socket) activeCompanion = undefined;
      });
      write(
        encodeCompanionJson({
          type: "hello",
          version: DESKTOP_VIEW_WIRE_VERSION,
          features: [DESKTOP_VIEW_FEATURE_H264_AVCC],
          grantId: "11111111-1111-4111-8111-111111111111",
          deviceId: device,
          surface: { windowId: 1, title: "QA Notes" },
        }),
      );
      if (leftover.length > 0) handleFrames(leftover);
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.listen(path, () => resolve());
    server.on("error", reject);
  });
  return { close: () => server.close() };
}

const storage = new Storage(dataDir);
storage.updateConfig({
  port: 0,
  host: "127.0.0.1",
  tls: { mode: "self-signed" },
  experimental: { desktopLiveView: true },
});
storage.ensurePaired();

const companion = await listenCompanion(companionRoot);
const server = new Server(storage, undefined, { desktopCompanionRuntimeRoot: companionRoot });
await server.start();
storage.updateConfig({ port: server.port });

const invite = generateInvite(storage, () => "127.0.0.1", () => "qa-live-view", {
  pairingTokenTtlMs: 30 * 60_000,
  ignorePublicUrl: true,
});

const info = {
  dataDir,
  companionRoot,
  companionSock: desktopCompanionOwnerSocketPath(companionRoot),
  port: server.port,
  inviteURL: invite.inviteURL,
  experimentKey: "dev.chenda.Oppi.experiments.desktopLiveView",
};
const infoPath = process.env.OPPI_DV_QA_INFO ?? join(tmpdir(), "oppi-dv-iphone-qa.json");
writeFileSync(infoPath, `${JSON.stringify(info, null, 2)}\n`);
console.log(infoPath);
console.log(JSON.stringify(info, null, 2));
console.error("stdin: pause | resume | drop | quit; SIGUSR1 pause, SIGUSR2 resume");

const rl = createInterface({ input: process.stdin, terminal: false });
const shutdown = async (): Promise<void> => {
  rl.close();
  companion.close();
  await server.stop();
  rmSync(dataDir, { recursive: true, force: true });
  rmSync(companionRoot, { recursive: true, force: true });
  process.exit(0);
};
rl.on("line", (line) => {
  const command = line.trim();
  if (command === "pause") {
    paused = true;
    console.error("paused");
  } else if (command === "resume") {
    paused = false;
    console.error("resumed");
  } else if (command === "drop") {
    activeCompanion?.end();
    console.error("dropped companion");
  } else if (command === "quit" || command === "exit") {
    void shutdown();
  }
});
process.on("SIGUSR1", () => {
  paused = true;
  console.error("paused");
});
process.on("SIGUSR2", () => {
  paused = false;
  console.error("resumed");
});
process.on("SIGINT", () => {
  void shutdown();
});
process.on("SIGTERM", () => {
  void shutdown();
});
