#!/usr/bin/env node
/**
 * Run the relay on Node.
 *
 *   OPPI_RELAY_APP_ID=AZAQMY4SPZ.dev.chenda.Oppi OPPI_RELAY_BUNDLE_ID=dev.chenda.Oppi \
 *   APNS_KEY_PATH=./AuthKey.p8 APNS_KEY_ID=... APNS_TEAM_ID=... node dist/node/main.js
 *
 * Capture mode records each APNs request instead of sending it:
 *
 *   node dist/node/main.js --capture ./apns-capture.jsonl
 *
 * Environment: OPPI_RELAY_PORT (default 8787), OPPI_RELAY_HOST (default 127.0.0.1),
 * OPPI_RELAY_STORE (JSON file; in memory when unset), OPPI_RELAY_TRUST_FORWARDED_FOR=1 behind
 * a reverse proxy (rate limits use the first X-Forwarded-For address).
 */

import { readFileSync } from "node:fs";
import { CaptureApnsSender, Http2ApnsSender } from "./apns-http2.js";
import { MemoryRelayStore } from "./memory-store.js";
import { startNodeRelay } from "./server.js";

function required(name: string): string {
  const value = process.env[name];
  if (!value) {
    console.error(`missing ${name}`);
    process.exit(2);
  }
  return value;
}

const captureIndex = process.argv.indexOf("--capture");
const capturePath = captureIndex >= 0 ? process.argv[captureIndex + 1] : undefined;
if (captureIndex >= 0 && !capturePath) {
  console.error("usage: main.js [--capture <file>]");
  process.exit(2);
}

const apns = capturePath
  ? new CaptureApnsSender(capturePath)
  : new Http2ApnsSender({
      keyP8: readFileSync(required("APNS_KEY_PATH"), "utf8"),
      keyId: required("APNS_KEY_ID"),
      teamId: required("APNS_TEAM_ID"),
    });

const relay = await startNodeRelay({
  store: new MemoryRelayStore(
    process.env.OPPI_RELAY_STORE ? { persistPath: process.env.OPPI_RELAY_STORE } : {},
  ),
  apns,
  config: { appId: required("OPPI_RELAY_APP_ID"), bundleId: required("OPPI_RELAY_BUNDLE_ID") },
  log: (event, fields) => console.log(JSON.stringify({ event, ...fields })),
  host: process.env.OPPI_RELAY_HOST ?? "127.0.0.1",
  port: Number(process.env.OPPI_RELAY_PORT ?? 8787),
  trustForwardedFor: process.env.OPPI_RELAY_TRUST_FORWARDED_FOR === "1",
});
console.log(JSON.stringify({ event: "relay.listening", url: relay.url, capture: Boolean(capturePath) }));
