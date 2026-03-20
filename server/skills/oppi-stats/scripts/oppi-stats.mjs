#!/usr/bin/env node
/**
 * oppi-stats.mjs — Oppi server session stats.
 *
 * Usage: node oppi-stats.mjs [--range 7|30|90] [--json]
 */

import https from "node:https";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const CONFIG_PATH = join(homedir(), ".config", "oppi", "config.json");
const AGENT = new https.Agent({ rejectUnauthorized: false });

function loadConfig() {
  const config = JSON.parse(readFileSync(CONFIG_PATH, "utf8"));
  const token = config.token || "";
  const port = Number.parseInt(String(config.port ?? 7749), 10) || 7749;
  if (!token) throw new Error("No token in ~/.config/oppi/config.json");
  return { token, port };
}

function api(method, path, { token, port }) {
  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        hostname: "localhost",
        port,
        method,
        path,
        headers: { Authorization: `Bearer ${token}` },
        agent: AGENT,
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const raw = Buffer.concat(chunks).toString("utf8");
          const status = res.statusCode ?? 500;
          try {
            const data = JSON.parse(raw);
            status >= 200 && status < 300
              ? resolve(data)
              : reject(new Error(data.error || `HTTP ${status}`));
          } catch {
            reject(new Error(`HTTP ${status}: ${raw.slice(0, 200)}`));
          }
        });
      },
    );
    req.on("error", reject);
    req.end();
  });
}

function formatTokens(n) {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(0)}k`;
  return String(n);
}

function parseRange(argv) {
  const idx = argv.indexOf("--range");
  if (idx === -1) return 7;
  const val = Number(argv[idx + 1]);
  return [7, 30, 90].includes(val) ? val : 7;
}

async function main() {
  const argv = process.argv.slice(2);
  const jsonMode = argv.includes("--json");
  const range = parseRange(argv);
  const config = loadConfig();

  const stats = await api("GET", `/server/stats?range=${range}`, config);

  if (jsonMode) {
    console.log(JSON.stringify(stats, null, 2));
    return;
  }

  const { totals, modelBreakdown, workspaceBreakdown, activeSessions, memory } = stats;

  // ─── Header ───
  const costStr = `$${totals.cost.toFixed(2)}`;
  const tokStr = formatTokens(totals.tokens);
  console.log(`\nstats  ${totals.sessions} sessions over ${range}d  cost: ${costStr}  tokens: ${tokStr}`);

  if (memory) {
    console.log(`memory  heap ${memory.heapUsed}/${memory.heapTotal} MB  rss ${memory.rss} MB`);
  }

  // ─── Model breakdown ───
  if (modelBreakdown && modelBreakdown.length > 0) {
    console.log("\nModel breakdown");

    const pad = (s, n) => String(s).padStart(n);
    const padE = (s, n) => String(s).padEnd(n);

    console.log(`  ${padE("Model", 30)} ${pad("Sess", 5)} ${pad("Cost", 9)} ${pad("Share", 6)}`);
    console.log("  " + "─".repeat(54));

    for (const m of modelBreakdown) {
      const name = m.model.length > 29 ? m.model.slice(0, 28) + "…" : m.model;
      const share = `${(m.share * 100).toFixed(0)}%`;
      console.log(
        `  ${padE(name, 30)} ${pad(m.sessions, 5)} ${pad("$" + m.cost.toFixed(2), 9)} ${pad(share, 6)}`,
      );
    }
  }

  // ─── Workspace breakdown ───
  if (workspaceBreakdown && workspaceBreakdown.length > 0) {
    console.log("\nWorkspace breakdown");

    const pad = (s, n) => String(s).padStart(n);
    const padE = (s, n) => String(s).padEnd(n);

    console.log(`  ${padE("Workspace", 30)} ${pad("Sess", 5)} ${pad("Cost", 9)}`);
    console.log("  " + "─".repeat(46));

    for (const w of workspaceBreakdown) {
      const name = w.name.length > 29 ? w.name.slice(0, 28) + "…" : w.name;
      console.log(`  ${padE(name, 30)} ${pad(w.sessions, 5)} ${pad("$" + w.cost.toFixed(2), 9)}`);
    }
  }

  // ─── Active sessions ───
  if (activeSessions && activeSessions.length > 0) {
    console.log("\nActive sessions");

    const pad = (s, n) => String(s).padStart(n);
    const padE = (s, n) => String(s).padEnd(n);

    console.log(`  ${padE("ID", 12)} ${padE("Status", 10)} ${padE("Model", 24)} Name`);
    console.log("  " + "─".repeat(70));

    for (const s of activeSessions) {
      const id = s.id.slice(0, 8);
      const status = s.status.slice(0, 9);
      const model = (s.model ?? "—").slice(0, 23);
      const name = s.name ?? "—";
      const indent = s.parentSessionId ? "↳ " : "  ";
      console.log(`${indent}${padE(id, 12)} ${padE(status, 10)} ${padE(model, 24)} ${name}`);
    }
  }

  console.log();
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
