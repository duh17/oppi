#!/usr/bin/env tsx
/**
 * Shaped-link bench for the desktop live-view lane.
 * Fake companion + userspace shaper + headless WSS client. No Screen Recording.
 */

import { createServer as createNetServer, connect as netConnect, type Socket } from "node:net";
import { generateKeyPairSync, randomFillSync } from "node:crypto";
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
  DESKTOP_VIEW_FEATURE_H264_AVCC,
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

const RUN_MS = 30_000;

type Verdict = {
  target: string;
  pass: boolean;
  detail: string;
  gate: boolean;
};

type SocketClose = {
  code: number;
  reason: string;
  atMs: number;
};

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
  l7AfterFirstMs: number;
  linkBps: number;
  overLinkMs: number;
  postRamp: Map<number, number>;
  postRampTotalMs: number;
  cascadeDown: boolean;
  mediaClose: SocketClose | undefined;
  controlClose: SocketClose | undefined;
  mediaError: string | undefined;
  shaperDrops: string[];
  mediaAliveAtRevoke: boolean;
  verdicts: Verdict[];
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
  const failed = results.flatMap((row) => row.verdicts.filter((item) => item.gate && !item.pass));
  if (failed.length > 0) {
    for (const item of failed) console.error(`FAIL ${item.target}: ${item.detail}`);
    process.exitCode = 1;
  }
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

  const levelSamples: Array<{ at: number; level: number }> = [];
  const companion = await listenCompanion(companionRoot, enrolled.deviceId, (encode) => {
    const fps = Number(encode.fps) || 15;
    const bitrate = Number(encode.bitrate) || 800_000;
    const matched = DESKTOP_VIEW_LADDER.find(
      (rung) => rung.fps === Number(encode.fps) && rung.scale === Number(encode.scale),
    );
    levelSamples.push({ at: Date.now(), level: matched?.level ?? 0 });
    const pBytes = Math.max(64, Math.ceil(bitrate / 8 / fps));
    const bytes = encode.keyframe === true || Number(encode.frameId) === 1 ? pBytes * 6 : pBytes;
    const payload = Buffer.allocUnsafe(bytes);
    randomFillSync(payload);
    return encodeMediaFrame(
      {
        keyframe: encode.keyframe === true || Number(encode.frameId) === 1,
        frameId: Number(encode.frameId),
        capturedAtMs: Date.now(),
        width: 640,
        height: 360,
      },
      payload,
    );
  });

  const server = new Server(storage, { desktopCompanionRuntimeRoot: companionRoot });
  await server.start();
  const targetPort = server.port;
  const openedAt = Date.now();
  const shaperDrops: string[] = [];
  const shaper = await listenShaper(preset, "127.0.0.1", targetPort, (event) => {
    shaperDrops.push(`${Date.now() - openedAt}ms ${event}`);
  });

  const ages: number[] = [];
  const arrivals: number[] = [];
  const controlPings: number[] = [];
  let bytes = 0;
  let firstFrameAt = 0;
  let lastArrival = 0;
  let mediaError: string | undefined;
  let mediaClose: SocketClose | undefined;
  let controlClose: SocketClose | undefined;

  const media = new WebSocket(`wss://127.0.0.1:${shaper.port}${DESKTOP_VIEW_STREAM_PATH}`, {
    headers: { Authorization: `Bearer ${enrolled.accessToken}` },
  });
  const control = new WebSocket(`wss://127.0.0.1:${shaper.port}/app/events/stream`, {
    headers: { Authorization: `Bearer ${enrolled.accessToken}` },
  });
  media.on("error", (error) => {
    console.error(`MEDIA_WS_ERROR ${preset.name} ${String(error)}`);
  });
  control.on("error", (error) => {
    console.error(`CONTROL_WS_ERROR ${preset.name} ${String(error)}`);
  });
  media.on("close", (code, reason) => {
    mediaClose = {
      code,
      reason: Buffer.isBuffer(reason) ? reason.toString() : String(reason ?? ""),
      atMs: Date.now() - openedAt,
    };
    console.error(
      `MEDIA_CLOSE ${preset.name} code=${code} reason=${JSON.stringify(mediaClose.reason)} atMs=${mediaClose.atMs}`,
    );
  });
  control.on("close", (code, reason) => {
    controlClose = {
      code,
      reason: Buffer.isBuffer(reason) ? reason.toString() : String(reason ?? ""),
      atMs: Date.now() - openedAt,
    };
    console.error(
      `CONTROL_CLOSE ${preset.name} code=${code} reason=${JSON.stringify(controlClose.reason)} atMs=${controlClose.atMs}`,
    );
  });
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
      if (parsed?.type === "error") {
        mediaError = `${String(parsed.code)} ${String(parsed.message ?? "")}`;
        console.error(`MEDIA_ERROR ${preset.name} ${mediaError}`);
      }
      return;
    }
    const buf = Buffer.isBuffer(data) ? data : Buffer.from(data as Buffer);
    const now = Date.now();
    if (firstFrameAt === 0) firstFrameAt = now;
    lastArrival = now;
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
  const mediaAliveAtRevoke = media.readyState === WebSocket.OPEN;
  const closedAtPromise = waitClose(media, 5_000);
  const revokeAt = Date.now();
  companion.revoke();
  const closedAt = await closedAtPromise;
  clearInterval(pingTimer);
  control.close();
  media.close();
  await delay(50);
  await server.stop();
  shaper.close();
  companion.close();
  rmSync(dataDir, { recursive: true, force: true });
  rmSync(companionRoot, { recursive: true, force: true });
  if (previousTls === undefined) delete process.env.NODE_TLS_REJECT_UNAUTHORIZED;
  else process.env.NODE_TLS_REJECT_UNAUTHORIZED = previousTls;

  const endAt = lastArrival || Date.now();
  const spanMs = Math.max(1, endAt - (firstFrameAt || Date.now()));
  const spanSec = spanMs / 1000;
  const gaps = arrivals.filter((at, i) => i > 0 && at - arrivals[i - 1]! > 100).length;
  const firstL7 = levelSamples.find((sample) => sample.level === 7);
  const l7AfterFirstMs = firstFrameAt && firstL7 ? Math.max(0, firstL7.at - firstFrameAt) : -1;
  const postRampStart = rampEndAt(levelSamples, firstFrameAt, endAt);
  const postRamp = dwellByLevel(levelSamples, postRampStart, endAt);
  const postRampTotalMs = [...postRamp.values()].reduce((sum, ms) => sum + ms, 0);
  const result: RunResult = {
    preset: preset.name,
    ttffMs: firstFrameAt ? firstFrameAt - openedAt : -1,
    fps: round(arrivals.length / spanSec, 2),
    ageP50: percentile(ages, 0.5),
    ageP95: percentile(ages, 0.95),
    ageMax: ages.length ? Math.max(...ages) : -1,
    gapsOver100: gaps,
    bitrateKbps: round((bytes * 8) / spanSec / 1000, 1),
    ladder: summarizeLadder(levelSamples, endAt),
    controlPingP50: percentile(controlPings, 0.5),
    controlPingP95: percentile(controlPings, 0.95),
    revokeToCloseMs: closedAt ? closedAt - revokeAt : -1,
    l7AfterFirstMs,
    postRamp,
    postRampTotalMs,
    linkBps: preset.rateBps,
    overLinkMs: 0,
    cascadeDown: hasCascadeDown(levelSamples, 2_000),
    mediaClose,
    controlClose,
    mediaError,
    shaperDrops,
    mediaAliveAtRevoke,
    verdicts: [],
  };
  result.overLinkMs = commandedOverLinkMs(postRamp, preset.rateBps);
  result.verdicts = evaluateTargets(result);
  return result;
}

function listenCompanion(
  runtimeRoot: string,
  deviceId: string,
  produce: (encode: Record<string, unknown>) => Buffer,
): Promise<{ close: () => void; revoke: () => void }> {
  const path = desktopCompanionOwnerSocketPath(runtimeRoot);
  let active: Socket | undefined;
  let claimedDeviceId: string | undefined;
  const server = createNetServer((socket) => {
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
      const headerText = buf.subarray(0, sep).toString("utf8");
      const requestLine = headerText.split("\r\n")[0] ?? "";
      const device =
        headerText
          .split("\r\n")
          .find((line) => line.toLowerCase().startsWith("x-oppi-device-id:"))
          ?.slice("x-oppi-device-id:".length)
          .trim() ?? "";
      if (requestLine.startsWith("GET /view/session")) {
        if (!device) {
          write(
            Buffer.from(
              "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            ),
          );
          socket.end();
          return;
        }
        if (claimedDeviceId && claimedDeviceId !== device) {
          const body = "view session not granted\n";
          write(
            Buffer.from(
              `HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: ${Buffer.byteLength(body)}\r\nConnection: close\r\n\r\n${body}`,
            ),
          );
          socket.end();
          return;
        }
        claimedDeviceId = device;
        const body = JSON.stringify({
          grantId: "11111111-1111-4111-8111-111111111111",
          capability: "view",
          deviceId: device,
          expiresAt: new Date(Date.now() + 15 * 60_000).toISOString(),
          caption: "View session\u2014not live delivery",
        });
        write(
          Buffer.from(
            `HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: ${Buffer.byteLength(body)}\r\nConnection: close\r\n\r\n${body}`,
          ),
        );
        socket.end();
        return;
      }
      if (
        !requestLine.startsWith("GET /view/stream") ||
        !claimedDeviceId ||
        device !== claimedDeviceId
      ) {
        const body = "view session not granted\n";
        write(
          Buffer.from(
            `HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: ${Buffer.byteLength(body)}\r\nConnection: close\r\n\r\n${body}`,
          ),
        );
        socket.end();
        return;
      }
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
          features: [DESKTOP_VIEW_FEATURE_H264_AVCC],
          grantId: "11111111-1111-4111-8111-111111111111",
          deviceId,
          surface: { windowId: 1, title: "Bench" },
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
  onDrop?: (event: string) => void,
): Promise<{ port: number; close: () => void }> {
  const bytesPerMs = preset.rateBps / 8 / 1000;
  let stallUntil = 0;
  let lastStall = Date.now();
  const nextFreeAt = { up: 0, down: 0 };
  const lastDeliverAt = { up: 0, down: 0 };
  let connSeq = 0;
  const server = createNetServer((client) => {
    const connId = `c${(connSeq += 1)}`;
    const upstream = netConnect(port, host);
    client.on("error", (error) => {
      onDrop?.(`${connId} client-error ${error.message}`);
    });
    upstream.on("error", (error) => {
      onDrop?.(`${connId} upstream-error ${error.message}`);
    });
    const pipe = (from: Socket, to: Socket, direction: "up" | "down"): void => {
      let pending = 0;
      let closed = false;
      let queue = Promise.resolve();
      const flushClose = (): void => {
        if (closed && pending === 0 && !to.destroyed) {
          onDrop?.(`${connId} ${direction} destroy-peer pending=0`);
          to.destroy();
        }
      };
      from.on("data", (chunk) => {
        const now = Date.now();
        if (preset.stallEveryMs > 0 && now - lastStall >= preset.stallEveryMs) {
          lastStall = now;
          stallUntil = now + preset.stallMs;
        }
        const start = Math.max(now, nextFreeAt[direction]);
        nextFreeAt[direction] = start + (bytesPerMs > 0 ? chunk.length / bytesPerMs : 0);
        const jitter = preset.jitterMs ? Math.random() * preset.jitterMs : 0;
        // Strictly increasing deliverAt so equal-ms setTimeouts cannot reorder TLS records.
        const deliverAt = Math.max(
          start + preset.delayMs + jitter,
          stallUntil,
          lastDeliverAt[direction] + 1,
        );
        lastDeliverAt[direction] = deliverAt;
        pending += 1;
        queue = queue.then(async () => {
          try {
            const wait = Math.max(0, deliverAt - Date.now());
            if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
            if (!to.destroyed && to.writable) to.write(chunk);
          } finally {
            pending -= 1;
            flushClose();
          }
        });
      });
      from.on("close", () => {
        onDrop?.(`${connId} ${direction} from-close pending=${pending}`);
        closed = true;
        flushClose();
      });
      from.on("error", (error) => {
        onDrop?.(`${connId} ${direction} from-error ${error.message} → destroy peer`);
        to.destroy();
      });
    };
    pipe(client, upstream, "up");
    pipe(upstream, client, "down");
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
    "over_link_ms",
    "media_close",
    "ctrl_close",
    "alive",
    "gates",
    "bands",
  ];
  console.error(header.join("\t"));
  for (const row of results) {
    const gates = row.verdicts
      .filter((item) => item.gate)
      .map((item) => `${item.pass ? "PASS" : "FAIL"}:${item.target}`)
      .join(",");
    const bands = row.verdicts
      .filter((item) => !item.gate)
      .map((item) => `${item.pass ? "PASS" : "FAIL"}:${item.target}`)
      .join(",");
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
      row.overLinkMs,
      formatClose(row.mediaClose),
      formatClose(row.controlClose),
      row.mediaAliveAtRevoke ? "yes" : "no",
      gates,
      bands,
    ].join("\t");
    console.error(line);
    if (row.shaperDrops.length > 0) {
      console.error(`SHAPER ${row.preset} ${row.shaperDrops.join(" | ")}`);
    }
    if (row.mediaError) console.error(`MEDIA_ERROR ${row.preset} ${row.mediaError}`);
    console.log(
      `METRIC ${row.preset}_ttff_ms=${row.ttffMs}\nMETRIC ${row.preset}_fps=${row.fps}\nMETRIC ${row.preset}_age_p95_ms=${row.ageP95}\nMETRIC ${row.preset}_ctrl_p95_ms=${row.controlPingP95}\nMETRIC ${row.preset}_revoke_ms=${row.revokeToCloseMs}\nMETRIC ${row.preset}_over_link_ms=${row.overLinkMs}\nMETRIC ${row.preset}_media_alive=${row.mediaAliveAtRevoke ? 1 : 0}`,
    );
  }
}

function formatClose(close: SocketClose | undefined): string {
  if (!close) return "-";
  const reason = close.reason ? `:${close.reason}` : "";
  return `${close.code}${reason}@${close.atMs}ms`;
}

function rampEndAt(
  samples: Array<{ at: number; level: number }>,
  firstFrameAt: number,
  endAt: number,
): number {
  for (let i = 1; i < samples.length; i += 1) {
    if (samples[i]!.level < samples[i - 1]!.level) return samples[i]!.at;
  }
  let maxLevel = 0;
  for (const sample of samples) maxLevel = Math.max(maxLevel, sample.level);
  const steady = samples.find((sample) => sample.level === maxLevel);
  return steady?.at ?? firstFrameAt ?? endAt;
}

function dwellByLevel(
  samples: Array<{ at: number; level: number }>,
  startAt: number,
  endAt: number,
): Map<number, number> {
  const dwell = new Map<number, number>();
  for (let i = 0; i < samples.length; i += 1) {
    const current = samples[i]!;
    const nextAt = samples[i + 1]?.at ?? endAt;
    const from = Math.max(current.at, startAt);
    const to = Math.min(nextAt, endAt);
    const ms = Math.max(0, to - from);
    if (ms === 0) continue;
    dwell.set(current.level, (dwell.get(current.level) ?? 0) + ms);
  }
  return dwell;
}

function bandShare(dwell: Map<number, number>, total: number, levels: number[]): number {
  if (total <= 0) return 0;
  let ms = 0;
  for (const level of levels) ms += dwell.get(level) ?? 0;
  return ms / total;
}

function hasCascadeDown(samples: Array<{ at: number; level: number }>, windowMs: number): boolean {
  for (let i = 1; i < samples.length; i += 1) {
    const previous = samples[i - 1]!;
    const current = samples[i]!;
    if (current.level >= previous.level) continue;
    let lowest = current.level;
    for (let j = i; j < samples.length && samples[j]!.at - current.at <= windowMs; j += 1) {
      lowest = Math.min(lowest, samples[j]!.level);
    }
    if (previous.level - lowest >= 3) return true;
  }
  return false;
}

function commandedOverLinkMs(dwell: Map<number, number>, linkBps: number): number {
  let ms = 0;
  for (const [level, time] of dwell) {
    const rung = DESKTOP_VIEW_LADDER.find((item) => item.level === level);
    if (rung && rung.bitrate > linkBps) ms += time;
  }
  return ms;
}

function evaluateTargets(row: RunResult): Verdict[] {
  const verdicts: Verdict[] = [];
  const l0 = bandShare(row.postRamp, row.postRampTotalMs, [0]);
  verdicts.push({
    target: `${row.preset}:post-ramp-L0<=20%`,
    pass: row.postRampTotalMs > 0 && l0 <= 0.2,
    detail: `L0 ${Math.round(l0 * 100)}% of ${row.postRampTotalMs}ms`,
    gate: false,
  });
  verdicts.push({
    target: `${row.preset}:no-stall-cascade`,
    pass: !row.cascadeDown,
    detail: row.cascadeDown ? "down-stepped 3+ rungs within 2s" : "ok",
    gate: false,
  });
  verdicts.push({
    target: `${row.preset}:over-link<=2s`,
    pass: row.mediaAliveAtRevoke && row.overLinkMs <= 2_000,
    detail: row.mediaAliveAtRevoke
      ? `${row.overLinkMs}ms commanded above ${row.linkBps}bps`
      : `run truncated (media dead before revoke); over-link ${row.overLinkMs}ms`,
    gate: true,
  });
  verdicts.push({
    target: `${row.preset}:media-alive-until-revoke`,
    pass: row.mediaAliveAtRevoke,
    detail: row.mediaAliveAtRevoke
      ? "open at revoke"
      : `closed ${formatClose(row.mediaClose)} ctrl ${formatClose(row.controlClose)}`,
    gate: true,
  });
  verdicts.push({
    target: `${row.preset}:revoke-ms-measured`,
    pass: row.revokeToCloseMs >= 0,
    detail: row.revokeToCloseMs >= 0 ? `${row.revokeToCloseMs}ms` : "stream already gone",
    gate: true,
  });
  if (row.preset === "lan") {
    verdicts.push({
      target: "lan:L7<=1s",
      pass: row.l7AfterFirstMs >= 0 && row.l7AfterFirstMs <= 1_000,
      detail: `L7 ${row.l7AfterFirstMs}ms after first frame`,
      gate: true,
    });
  }
  if (row.preset === "tailscale-wan") {
    const share = bandShare(row.postRamp, row.postRampTotalMs, [6, 7]);
    verdicts.push({
      target: "tailscale-wan:majority-L6-L7",
      pass: share > 0.5,
      detail: `L6-L7 ${Math.round(share * 100)}%`,
      gate: false,
    });
  }
  if (row.preset === "lte") {
    const share = bandShare(row.postRamp, row.postRampTotalMs, [5, 6]);
    verdicts.push({
      target: "lte:settles-L5-L6",
      pass: share > 0.5,
      detail: `L5-L6 ${Math.round(share * 100)}%`,
      gate: false,
    });
  }
  if (row.preset === "bad-cell") {
    const share = bandShare(row.postRamp, row.postRampTotalMs, [2, 3, 4]);
    verdicts.push({
      target: "bad-cell:settles-L2-L4",
      pass: share > 0.5,
      detail: `L2-L4 ${Math.round(share * 100)}%`,
      gate: false,
    });
  }
  return verdicts;
}

function summarizeLadder(samples: Array<{ at: number; level: number }>, endAt: number): string {
  if (samples.length === 0) return "-";
  const dwell = new Map<number, number>();
  let down = 0;
  for (let i = 0; i < samples.length; i += 1) {
    const current = samples[i]!;
    const nextAt = samples[i + 1]?.at ?? endAt;
    dwell.set(current.level, (dwell.get(current.level) ?? 0) + Math.max(0, nextAt - current.at));
    if (i > 0 && current.level < samples[i - 1]!.level) down += 1;
  }
  const total = [...dwell.values()].reduce((sum, ms) => sum + ms, 0) || 1;
  const parts = [...dwell.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([level, ms]) => `L${level}:${Math.round((ms / total) * 100)}%`);
  return `${parts.join(" ")} down=${down}`;
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
