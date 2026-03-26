#!/usr/bin/env node

/**
 * Benchmarks for EventRing (server/src/event-ring.ts).
 *
 * Run: node bench/event-ring.bench.mjs
 * Requires: npm run build (imports from dist/)
 */

import { bench } from "./bench-utils.mjs";
import { EventRing } from "../dist/event-ring.js";

const CAP = 500;

/** Create a SequencedEvent with minimal payload. */
function makeEvent(seq) {
  return { seq, event: { type: "text_delta", text: "x" }, timestamp: Date.now() };
}

/** Build a full ring with `CAP` events (seqs 1..CAP). */
function fullRing() {
  const ring = new EventRing(CAP);
  for (let i = 1; i <= CAP; i++) {
    ring.push(makeEvent(i));
  }
  return ring;
}

// --- push: 10,000 events into a ring of capacity 500 (steady-state with overwrites) ---
await bench(
  "event_ring_push",
  () => {
    const ring = new EventRing(CAP);
    for (let i = 1; i <= 10_000; i++) {
      ring.push(makeEvent(i));
    }
  },
  { iterations: 200, warmup: 20 },
);

// --- since_miss: since(0) on a full ring — returns all 500 events (worst case) ---
{
  const ring = fullRing();
  await bench(
    "event_ring_since_miss",
    () => {
      ring.since(0);
    },
    { iterations: 1000, warmup: 50 },
  );
}

// --- since_hit: since(currentSeq - 10) on a full ring — returns 10 events (typical reconnect) ---
{
  const ring = fullRing();
  const sinceSeq = ring.currentSeq - 10;
  await bench(
    "event_ring_since_hit",
    () => {
      ring.since(sinceSeq);
    },
    { iterations: 1000, warmup: 50 },
  );
}

// --- canServe: canServe() on a full ring (fast path check) ---
{
  const ring = fullRing();
  const seq = ring.currentSeq - 10;
  await bench(
    "event_ring_canServe",
    () => {
      ring.canServe(seq);
    },
    { iterations: 1000, warmup: 50 },
  );
}
