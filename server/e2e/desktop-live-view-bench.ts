#!/usr/bin/env tsx
/**
 * Shaped-link bench for the desktop live-view lane.
 * Fake companion + userspace shaper + headless WSS client. No Screen Recording.
 */

import { createServer as createNetServer, connect as netConnect, type Socket } from "node:net";
import { generateKeyPairSync } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { WebSocket } from "ws";

import { desktopCompanionOwnerSocketPath } from "../src/desktop-companion-still-client.js";
import {
  CompanionFrameReader,
  encodeCompanionJson,
  encodeCompanionMedia,
  encodeMediaFrame,
  parseControlJson,
  parseMediaFrame,
} from "../src/desktop-view-stream-codec.js";
import { DESKTOP_VIEW_LADDER } from "../src/desktop-view-rate-controller.js";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import {
  DESKTOP_VIEW_ERROR,
  DESKTOP_VIEW_FEATURE_H264_ANNEXB,
  DESKTOP_VIEW_STREAM_PATH,
  DESKTOP_VIEW_WIRE_VERSION,
} from "../src/types/protocol.js";

type Preset = {
  name: string;
  rateBps: number;
  delayMs: number;
  jitterMs: number;
  stallEveryMs: number;
  stallMs: number;
};

const PRESETS: Preset[] = [
  { name: "lan", rateBps: 100_000_000, delayMs: 1, jitterMs: 0, stallEveryMs: 0, stallMs: 0 },
  {
    name: "tailscale-wan",
    rateBps: 20_000_000,
    delayMs: 40,
    jitterMs: 10,
    stallEveryMs: 5_000,
    stallMs: 200,
  },
  { name: "lte", rateBps: 8_000_000, delayMs: 60, jitterMs: 20, stallEveryMs: 4_000, stallMs: 300 },
  {
    name: "bad-cell",
    rateBps: 1_500_000,
    delayMs: 120,
    jitterMs: 40,
    stallEveryMs: 3_000,
    stallMs: 800,
  },
];

const RUN_MS = 4_000;

type RunResult = {
  preset: string;
  ttffMs: number;
  fps: number;
  ageP50: number;
  ageP95: number;
  ageMax: number;
  gapsOver100: number;
  bitrateKbps: number;
  ladder: string;
  controlPingP50: number;
  controlPingP95: number;
  revokeToCloseMs: number;
};

async function main(): Promise<void> {
  const only = process.argv.includes("--preset")
    ? process.argv[process.argv.indexOf("--preset") + 1]
    : undefined;
  const presets = only ? PRESETS.filter((preset) => preset.name === only) : PRESETS;
  if (presets.length === 0) throw new Error(`Unknown preset ${only}`);
  const results: RunResult[] = [];
  for (const preset of presets) {
    results.push(await runPreset(preset));
  }
  printTable(results);
}

async function runPreset(preset: Preset): Promise<RunResult> {
  const dataDir = mkdtempSync(join(tmpdir(), "oppi-dv-bench-data-"));
  const companionRoot = mkdtempSync(join(tmpdir(), "oppi-dv-bench-comp-"));
  mkdirSync(join(companionRoot, "run"), { recursive: true });
  const previousTls = process.env.NODE_TLS_REJECT_UNAUTHORIZED;
  process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
  const storage = new Storage(dataDir);
  storage.updateConfig({
    port: 0,
    host: "127.0.0.1",
    tls: { mode: "self-signed" },
    experimental: { desktopLiveView: true },
  });
  storage.ensurePaired();
  const { publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" }) as { x: string; y: string };
  const enrolled = storage.enrollViaPairing(storage.issuePairingToken(), {
    publicKey: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y },
    name: "bench-phone",
  });
  if (!enrolled) throw new Error("enrollment failed");

  const levels: number[] = [];
  const companion = await listenCompanion(companionRoot, enrolled.deviceId, (encode) => {
    const fps = Number(encode.fps) || 15;
    const bitrate = Number(encode.bitrate) || 800_000;
    const matched = DESKTOP_VIEW_LADDER.find(
      (rung) => rung.fps === Number(encode.fps) && rung.scale === Number(encode.scale),
    );
    levels.push(matched?.level ?? 0);
    const bytes = Math.max(64, Math.ceil(bitrate / 8 / fps));
    return encodeMediaFrame(
      {
        keyframe: encode.keyframe === true || Number(encode.frameId) === 1,
        frameId: Number(encode.frameId),
        capturedAtMs: Date.now(),
        width: 640,
        height: 360,
      },
      Buffer.alloc(bytes, 0x11),
    );
  });

  const server = new Server(storage, undefined, { desktopCompanionRuntimeRoot: companionRoot });
  await server.start();
  const targetPort = server.port;
  const shaper = await listenShaper(preset, "127.0.0.1", targetPort);

  const ages: number[] = [];
  const arrivals: number[] = [];
  const controlPings: number[] = [];
  let bytes = 0;
  let firstFrameAt = 0;
  const openedAt = Date.now();

  const media = new WebSocket(`wss://127.0.0.1:${shaper.port}${DESKTOP_VIEW_STREAM_PATH}`, {
    headers: { Authorization: `Bearer ${enrolled.accessToken}` },
  });
  const control = new WebSocket(`wss://127.0.0.1:${shaper.port}/app/events/stream`, {
    headers: { Authorization: `Bearer ${enrolled.accessToken}` },
  });
  media.on("error", () => {});
  control.on("error", () => {});
  control.on("pong", (data) => {
    const sent = Number(data.toString("utf8"));
    if (Number.isFinite(sent)) controlPings.push(Date.now() - sent);
  });
  const pingTimer = setInterval(() => {
    if (control.readyState === WebSocket.OPEN) control.ping(Buffer.from(String(Date.now())));
  }, 200);

  media.on("message", (data, binary) => {
    if (!binary) {
      const parsed = parseControlJson(Buffer.from(data as Buffer));
      if (parsed?.type === "ping") {
        media.send(JSON.stringify({ type: "pong", t: parsed.t }));
      }
      return;
    }
    const buf = Buffer.isBuffer(data) ? data : Buffer.from(data as Buffer);
    const now = Date.now();
    if (firstFrameAt === 0) firstFrameAt = now;
    arrivals.push(now);
    bytes += buf.length;
    try {
      const parsed = parseMediaFrame(buf);
      ages.push(now - parsed.header.capturedAtMs);
      media.send(JSON.stringify({ type: "ack", frameId: parsed.header.frameId, receivedAt: now }));
    } catch {
      // ignore malformed bench payload
    }
  });

  await delay(RUN_MS);
  const closedAtPromise = waitClose(media, 2_000);
  const revokeAt = Date.now();
  companion.revoke();
  const closedAt = await closedAtPromise;
  clearInterval(pingTimer);
  control.close();
  media.close();
  await server.stop();
  shaper.close();
  companion.close();
  rmSync(dataDir, { recursive: true, force: true });
  rmSync(companionRoot, { recursive: true, force: true });
  if (previousTls === undefined) delete process.env.NODE_TLS_REJECT_UNAUTHORIZED;
  else process.env.NODE_TLS_REJECT_UNAUTHORIZED = previousTls;

  const durationSec = Math.max(0.001, ((firstFrameAt || Date.now()) === 0 ? RUN_MS : RUN_MS) / 1000);
  const gaps = arrivals.filter((at, i) => i > 0 && at - arrivals[i - 1]! > 100).length;
  const fps = arrivals.length / (RUN_MS / 1000);
  return {
    preset: preset.name,
    ttffMs: firstFrameAt ? firstFrameAt - openedAt : -1,
    fps: round(fps, 2),
    ageP50: percentile(ages, 0.5),
    ageP95: percentile(ages, 0.95),
    ageMax: ages.length ? Math.max(...ages) : -1,
    gapsOver100: gaps,
    bitrateKbps: round((bytes * 8) / durationSec / 1000, 1),
    ladder: summarizeLadder(levels),
    controlPingP50: percentile(controlPings, 0.5),
    controlPingP95: percentile(controlPings, 0.95),
    revokeToCloseMs: closedAt ? closedAt - revokeAt : -1,
  };
}

function listenCompanion(
  runtimeRoot: string,
  deviceId: string,
  produce: (encode: Record<string, unknown>) => Buffer,
): Promise<{ close: () => void; revoke: () => void }> {
  const path = desktopCompanionOwnerSocketPath(runtimeRoot);
  let active: Socket | undefined;
  const server = createNetServer((socket) => {
    let buf = Buffer.alloc(0);
    let upgraded = false;
    const reader = new CompanionFrameReader();
    const write = (bytes: Buffer): void => {
      if (!socket.destroyed && socket.writable) socket.write(bytes);
    };
    const handleFrames = (chunk: Buffer): void => {
      for (const frame of reader.push(chunk)) {
        const parsed = parseControlJson(frame.payload);
        if (parsed?.type === "encode") write(encodeCompanionMedia(produce(parsed)));
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
      write(
        Buffer.from(
          "HTTP/1.1 101 Switching Protocols\r\nUpgrade: oppi-desktop-view\r\nConnection: Upgrade\r\n\r\n",
        ),
      );
      upgraded = true;
      active = socket;
      write(
        encodeCompanionJson({
          type: "hello",
          version: DESKTOP_VIEW_WIRE_VERSION,
          features: [DESKTOP_VIEW_FEATURE_H264_ANNEXB],
          grantId: "11111111-1111-4111-8111-111111111111",
          deviceId,
          surface: { windowId: 1, title: "Bench" },
          width: 640,
          height: 360,
        }),
      );
      const leftover = buf.subarray(sep + 4);
      if (leftover.length > 0) handleFrames(leftover);
    });
  });
  return new Promise((resolve, reject) => {
    server.listen(path, () => {
      resolve({
        close: () => server.close(),
        revoke: () => {
          if (!active || active.destroyed || !active.writable) return;
          active.write(
            encodeCompanionJson({
              type: "error",
              code: DESKTOP_VIEW_ERROR.grantRevoked,
              message: "View grant revoked",
              fatal: true,
            }),
          );
          active.end();
        },
      });
    });
    server.on("error", reject);
  });
}

function listenShaper(
  preset: Preset,
  host: string,
  port: number,
): Promise<{ port: number; close: () => void }> {
  const bytesPerMs = preset.rateBps / 8 / 1000;
  let stallUntil = 0;
  let lastStall = Date.now();
  const server = createNetServer((client) => {
    const upstream = netConnect(port, host);
    const pipe = (from: Socket, to: Socket): void => {
      let chain = Promise.resolve();
      from.on("data", (chunk) => {
        chain = chain.then(async () => {
          const now = Date.now();
          if (preset.stallEveryMs > 0 && now - lastStall >= preset.stallEveryMs) {
            lastStall = now;
            stallUntil = now + preset.stallMs;
          }
          const jitter = preset.jitterMs ? Math.random() * preset.jitterMs : 0;
          const wait = Math.max(0, stallUntil - Date.now()) + preset.delayMs + jitter;
          if (wait > 0) await delay(wait);
          const minMs = bytesPerMs > 0 ? chunk.length / bytesPerMs : 0;
          if (minMs > 1) await delay(minMs);
          if (!to.destroyed && to.writable) to.write(chunk);
        });
      });
      from.on("close", () => {
        void chain.finally(() => to.destroy());
      });
      from.on("error", () => to.destroy());
    };
    pipe(client, upstream);
    pipe(upstream, client);
  });
  return new Promise((resolve, reject) => {
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        reject(new Error("shaper bind failed"));
        return;
      }
      resolve({ port: address.port, close: () => server.close() });
    });
    server.on("error", reject);
  });
}

function printTable(results: RunResult[]): void {
  const header = [
    "preset",
    "ttff_ms",
    "fps",
    "age_p50",
    "age_p95",
    "age_max",
    "gaps>100ms",
    "kbps",
    "ladder",
    "ctrl_p50",
    "ctrl_p95",
    "revoke_ms",
  ];
  console.error(header.join("\t"));
  for (const row of results) {
    const line = [
      row.preset,
      row.ttffMs,
      row.fps,
      row.ageP50,
      row.ageP95,
      row.ageMax,
      row.gapsOver100,
      row.bitrateKbps,
      row.ladder,
      row.controlPingP50,
      row.controlPingP95,
      row.revokeToCloseMs,
    ].join("\t");
    console.error(line);
    console.log(
      `METRIC ${row.preset}_ttff_ms=${row.ttffMs}\nMETRIC ${row.preset}_fps=${row.fps}\nMETRIC ${row.preset}_age_p95_ms=${row.ageP95}\nMETRIC ${row.preset}_revoke_ms=${row.revokeToCloseMs}`,
    );
  }
}

function summarizeLadder(levels: number[]): string {
  if (levels.length === 0) return "-";
  const first = levels[0];
  const last = levels[levels.length - 1];
  const max = Math.max(...levels);
  return `${first}->${max}->${last}`;
}

function percentile(values: number[], p: number): number {
  if (values.length === 0) return -1;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.ceil(p * sorted.length) - 1)]!;
}

function round(value: number, digits: number): number {
  const scale = 10 ** digits;
  return Math.round(value * scale) / scale;
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function waitClose(ws: WebSocket, ms: number): Promise<number | undefined> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(undefined), ms);
    ws.once("close", () => {
      clearTimeout(timer);
      resolve(Date.now());
    });
  });
}

void main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});
