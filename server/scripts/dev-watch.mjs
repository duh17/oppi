#!/usr/bin/env node
/**
 * Gated dev-watch: hot-reload the Oppi server only when code compiles.
 *
 * Unlike `tsx watch` which kills the server before checking syntax,
 * this script keeps the old server running until the new code passes
 * esbuild's transform check. Syntax errors are logged but don't cause downtime.
 *
 * Usage: node scripts/dev-watch.mjs serve --data-dir ~/.config/oppi
 *   (all args after the script are forwarded to tsx src/cli.ts)
 */

import { transformSync } from "esbuild";
import { spawn } from "node:child_process";
import { watch, readFileSync, readdirSync } from "node:fs";
import { resolve, join, relative, extname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = fileURLToPath(new URL(".", import.meta.url));
const serverDir = resolve(__dirname, "..");
const srcDir = join(serverDir, "src");

// Forward args: everything after this script path goes to tsx
const forwardArgs = process.argv.slice(2);

// Resolve tsx binary
const tsxBin = join(serverDir, "node_modules", ".bin", "tsx");

// Delay after killing old server before starting new one (port release)
const PORT_RELEASE_MS = 500;

// ── Server process management ──────────────────────────────────────

let serverProc = null;
let intentionalRestart = false;

function startServer() {
  const args = [join(srcDir, "cli.ts"), ...forwardArgs];
  console.log(`[dev-watch] Starting server: tsx ${args.join(" ")}`);

  serverProc = spawn(tsxBin, args, {
    cwd: serverDir,
    stdio: "inherit",
    env: { ...process.env },
  });

  serverProc.on("exit", (code, signal) => {
    console.log(`[dev-watch] Server exited: code=${code} signal=${signal}`);
    serverProc = null;

    // If we initiated this restart, restartServer handles the re-spawn.
    if (intentionalRestart) return;

    // Unexpected exit (runtime error, OOM, etc.) — restart after delay.
    console.log("[dev-watch] Unexpected exit, restarting in 2s...");
    setTimeout(startServer, 2000);
  });
}

function restartServer() {
  intentionalRestart = true;

  if (serverProc) {
    console.log("[dev-watch] Killing old server...");
    const proc = serverProc;

    proc.on("exit", () => {
      // Brief delay for port release before starting new server
      setTimeout(() => {
        intentionalRestart = false;
        startServer();
      }, PORT_RELEASE_MS);
    });

    proc.kill("SIGTERM");

    // Force kill after 3s if SIGTERM doesn't work
    setTimeout(() => {
      if (proc.exitCode === null) {
        console.log("[dev-watch] Force-killing old server (SIGKILL)");
        proc.kill("SIGKILL");
      }
    }, 3000);
  } else {
    intentionalRestart = false;
    startServer();
  }
}

// ── Syntax checking ────────────────────────────────────────────────

/**
 * Check all .ts files in src/ for syntax errors using esbuild transform.
 * Returns { ok: true } or { ok: false, errors: [...] }.
 */
function checkAllFiles() {
  const errors = [];
  walkTs(srcDir, (filePath) => {
    try {
      const code = readFileSync(filePath, "utf8");
      transformSync(code, {
        loader: extname(filePath) === ".tsx" ? "tsx" : "ts",
        logLevel: "silent",
      });
    } catch (e) {
      const rel = relative(serverDir, filePath);
      const msg = e.errors?.[0]?.text || e.message;
      errors.push(`${rel}: ${msg}`);
    }
  });
  return errors.length === 0 ? { ok: true } : { ok: false, errors };
}

/** Recursively find .ts/.tsx files */
function walkTs(dir, cb) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory() && entry.name !== "node_modules") {
      walkTs(full, cb);
    } else if (
      entry.isFile() &&
      (entry.name.endsWith(".ts") || entry.name.endsWith(".tsx"))
    ) {
      cb(full);
    }
  }
}

// ── File watcher ───────────────────────────────────────────────────

let debounceTimer = null;
const DEBOUNCE_MS = 300;

function onFileChange(_eventType, filename) {
  if (!filename) return;
  if (!filename.endsWith(".ts") && !filename.endsWith(".tsx")) return;

  // Debounce rapid changes (editors do multiple writes)
  clearTimeout(debounceTimer);
  debounceTimer = setTimeout(() => {
    console.log(`[dev-watch] Change detected: ${filename}`);

    const result = checkAllFiles();
    if (result.ok) {
      console.log("[dev-watch] Syntax check passed, restarting server...");
      restartServer();
    } else {
      console.log(
        `[dev-watch] Syntax check FAILED (${result.errors.length} error(s)), keeping old server:`,
      );
      for (const err of result.errors) {
        console.log(`  ${err}`);
      }
    }
  }, DEBOUNCE_MS);
}

// ── Main ───────────────────────────────────────────────────────────

// Initial syntax check
const initial = checkAllFiles();
if (!initial.ok) {
  console.log("[dev-watch] WARNING: src/ has syntax errors on startup:");
  for (const err of initial.errors) {
    console.log(`  ${err}`);
  }
  console.log("[dev-watch] Starting server anyway (may crash)...");
}

startServer();

// Watch src/ recursively (macOS supports recursive: true natively)
watch(srcDir, { recursive: true }, onFileChange);

// Forward signals to server
for (const sig of ["SIGTERM", "SIGINT"]) {
  process.on(sig, () => {
    console.log(`[dev-watch] Received ${sig}, shutting down...`);
    if (serverProc) {
      serverProc.kill(sig);
      serverProc.on("exit", () => process.exit(0));
      setTimeout(() => process.exit(1), 5000);
    } else {
      process.exit(0);
    }
  });
}

console.log(`[dev-watch] Watching ${srcDir} for changes`);
