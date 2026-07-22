/* eslint-disable no-console, local/structured-log-format */
import { AsyncLocalStorage } from "node:async_hooks";

import * as c from "../ansi.js";

export type CliJsonEnvelope =
  | { ok: true; data: Record<string, unknown> }
  | { ok: false; error: { message: string; status?: number } };

export type TerminalDetailEntry = [string, unknown];

export type TerminalListItem = {
  id?: unknown;
  title: unknown;
  status?: unknown;
  meta?: unknown[];
  details?: unknown[];
};

type CliOutputCapture = { chunks: string[]; exitCode: number };

const cliOutputCapture = new AsyncLocalStorage<CliOutputCapture>();

export async function captureCliOutput<T>(
  fn: () => Promise<T>,
): Promise<{ stdout: string; result: T; exitCode: number }> {
  const capture: CliOutputCapture = { chunks: [], exitCode: 0 };
  const result = await cliOutputCapture.run(capture, fn);
  return { stdout: capture.chunks.join(""), result, exitCode: capture.exitCode };
}

export function setCapturedCliExitCode(exitCode: number): void {
  const capture = cliOutputCapture.getStore();
  if (capture) {
    capture.exitCode = exitCode;
    return;
  }
  process.exitCode = exitCode;
}

export function writeJsonEnvelope(envelope: CliJsonEnvelope): void {
  const output = JSON.stringify(envelope, null, 2) + "\n";
  const capture = cliOutputCapture.getStore();
  if (capture) {
    capture.chunks.push(output);
    return;
  }
  process.stdout.write(output);
}

export function codeValue(value: unknown, fallback = "—"): string {
  const text = scalarText(value);
  return text ? c.cyan(text) : fallback;
}

export function terminalValue(value: unknown, fallback = "—"): string {
  const text = scalarText(value);
  return text || fallback;
}

export function nonEmptyDetails(entries: TerminalDetailEntry[]): TerminalDetailEntry[] {
  return entries.filter(([, value]) => terminalValue(value, "") !== "");
}

export function printDetails(title: string, entries: TerminalDetailEntry[]): void {
  printTitle(title);
  if (entries.length === 0) {
    console.log(`  ${c.dim("No details returned.")}`);
    console.log("");
    return;
  }

  const width = Math.max(...entries.map(([label]) => label.length));
  for (const [label, value] of entries) {
    console.log(`  ${c.dim(label.padEnd(width))}  ${terminalValue(value)}`);
  }
  console.log("");
}

export function printList(
  title: string,
  items: TerminalListItem[],
  options: { empty?: string } = {},
): void {
  printTitle(title);
  if (items.length === 0) {
    console.log(`  ${c.dim(options.empty ?? "No rows.")}`);
    console.log("");
    return;
  }

  for (const item of items) {
    const id = scalarText(item.id);
    const status = scalarText(item.status);
    const titleText = terminalValue(item.title, "(unnamed)");
    const meta = (item.meta ?? []).map((value) => scalarText(value)).filter(Boolean);
    const details = (item.details ?? []).map((value) => scalarText(value)).filter(Boolean);

    const prefix = [id ? codeValue(id) : undefined, status ? formatStatus(status) : undefined]
      .filter(Boolean)
      .join("  ");
    const metaText = meta.length > 0 ? `  ${c.dim(meta.join(" · "))}` : "";
    console.log(`  ${prefix ? `${prefix}  ` : ""}${c.bold(titleText)}${metaText}`);
    for (const detail of details) {
      console.log(`    ${c.dim(detail)}`);
    }
  }
  console.log("");
}

export function printNextCommands(commands: string[]): void {
  if (commands.length === 0) return;
  printTitle("Next commands");
  for (const command of commands) {
    console.log(`  ${c.dim("$")} ${command}`);
  }
  console.log("");
}

export function formatStatus(status: unknown): string {
  const text = terminalValue(status, "?");
  const normalized = text.toLowerCase();
  if (["ready", "active", "running", "accepted", "success", "ok"].includes(normalized)) {
    return c.green(text);
  }
  if (["busy", "starting", "stopping", "pending", "queued", "paused"].includes(normalized)) {
    return c.yellow(text);
  }
  if (["stopped", "archived", "complete", "completed"].includes(normalized)) {
    return c.dim(text);
  }
  if (["error", "failed", "failure", "rejected"].includes(normalized)) {
    return c.red(text);
  }
  return text;
}

function printTitle(title: string): void {
  const styledTitle = title.startsWith("✓") ? c.green(title) : c.bold(title);
  console.log(styledTitle);
  console.log(c.dim("─".repeat(Math.max(12, visibleLength(title)))));
}

function scalarText(value: unknown): string {
  if (value === undefined || value === null) return "";
  if (value instanceof Date) return value.toISOString();
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" || typeof value === "boolean" || typeof value === "bigint") {
    return String(value);
  }
  return JSON.stringify(value);
}

function visibleLength(value: string): number {
  return [...value].length;
}
