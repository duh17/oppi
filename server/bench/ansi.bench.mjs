#!/usr/bin/env node

/**
 * Benchmarks for stripAnsiEscapes (server/src/ansi.ts).
 *
 * Run: node bench/ansi.bench.mjs
 * Requires: npm run build (imports from dist/)
 */

import { bench } from "./bench-utils.mjs";
import { stripAnsiEscapes } from "../dist/ansi.js";

// --- Test strings ---

const plain =
  "Hello world, this is a plain text line with no escapes\n".repeat(100);

const sgr =
  "\x1b[32mgreen\x1b[0m \x1b[1;31mbold red\x1b[0m normal\n".repeat(100);

const mixed =
  "\x1b[32mok\x1b[0m \x1b[2K\x1b[1A\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\\n".repeat(
    100,
  );

const heavy = mixed.repeat(10); // ~100KB

// --- no_escapes: plain text (fast path — no ESC bytes) ---
await bench(
  "ansi_no_escapes",
  () => {
    stripAnsiEscapes(plain);
  },
  { iterations: 1000, warmup: 50 },
);

// --- sgr_only: text with SGR color codes only (preserved, not stripped) ---
await bench(
  "ansi_sgr_only",
  () => {
    stripAnsiEscapes(sgr);
  },
  { iterations: 1000, warmup: 50 },
);

// --- mixed: SGR + cursor movement + OSC hyperlinks (real tool output) ---
await bench(
  "ansi_mixed",
  () => {
    stripAnsiEscapes(mixed);
  },
  { iterations: 1000, warmup: 50 },
);

// --- heavy: ~100KB with dense ANSI sequences ---
await bench(
  "ansi_heavy",
  () => {
    stripAnsiEscapes(heavy);
  },
  { iterations: 200, warmup: 20 },
);
