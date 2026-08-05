/* eslint-disable no-console */
import { AsyncLocalStorage } from "node:async_hooks";

import * as c from "../ansi.js";
import { redactCredentialString, redactCredentialValue } from "../credential-redaction.js";

export type CliJsonError = {
  message: string;
  status?: number;
  code?: string;
  expectedVersion?: number;
  currentVersion?: number;
};

export type CliJsonEnvelope =
  | { ok: true; data: Record<string, unknown> }
  | { ok: false; error: CliJsonError };

export type TerminalDetailEntry = [string, unknown];

export type TerminalListItem = {
  id?: unknown;
  title: unknown;
  status?: unknown;
  meta?: unknown[];
  details?: unknown[];
};

type CliOutputCapture = {
  chunks: string[];
  humanChunks: string[];
  includeHuman: boolean;
  exitCode: number;
};

const cliOutputCapture = new AsyncLocalStorage<CliOutputCapture>();

export async function captureCliOutput<T>(
  fn: () => Promise<T>,
  options: Readonly<{ includeHuman?: boolean }> = {},
): Promise<{ stdout: string; humanStdout: string; result: T; exitCode: number }> {
  const capture: CliOutputCapture = {
    chunks: [],
    humanChunks: [],
    includeHuman: options.includeHuman === true,
    exitCode: 0,
  };
  const result = await cliOutputCapture.run(capture, () =>
    options.includeHuman ? c.withAnsiCapture(fn) : fn(),
  );
  return {
    stdout: capture.chunks.join(""),
    humanStdout: capture.humanChunks.join(""),
    result,
    exitCode: capture.exitCode,
  };
}

export function captureHumanCliOutput(render: () => void): void {
  if (cliOutputCapture.getStore()?.includeHuman) render();
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
  const safeEnvelope = redactCredentialValue(envelope) as CliJsonEnvelope;
  const output = JSON.stringify(safeEnvelope, null, 2) + "\n";
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
    writeHumanLine(`  ${c.dim("No details returned.")}`);
    writeHumanLine("");
    return;
  }

  const width = Math.max(...entries.map(([label]) => label.length));
  for (const [label, value] of entries) {
    const renderedValue =
      label.trim().toLowerCase() === "status" ? formatStatus(value) : terminalValue(value);
    writeHumanLine(`  ${c.dim(label.padEnd(width))}  ${renderedValue}`);
  }
  writeHumanLine("");
}

export function printTextBlock(title: string, text: string): void {
  printTitle(title);
  const lines = text.replaceAll("\r\n", "\n").replaceAll("\r", "\n").split("\n");
  for (const line of lines) writeHumanLine(`  ${line}`);
  writeHumanLine("");
}

export function printList(
  title: string,
  items: TerminalListItem[],
  options: { empty?: string } = {},
): void {
  printTitle(title);
  if (items.length === 0) {
    writeHumanLine(`  ${c.dim(options.empty ?? "No rows.")}`);
    writeHumanLine("");
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
    writeHumanLine(`  ${prefix ? `${prefix}  ` : ""}${c.bold(titleText)}${metaText}`);
    for (const detail of details) {
      writeHumanLine(`    ${c.dim(detail)}`);
    }
  }
  writeHumanLine("");
}

export function printNextCommands(commands: string[]): void {
  if (commands.length === 0) return;
  printTitle("Next commands");
  for (const command of commands) {
    writeHumanLine(`  ${c.dim("$")} ${command}`);
  }
  writeHumanLine("");
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
  const styledTitle = title.startsWith("✓") ? c.bold(c.green(title)) : c.bold(title);
  writeHumanLine(styledTitle);
  writeHumanLine(c.dim("─".repeat(Math.max(12, visibleLength(title)))));
}

export function writeHumanLine(value: string): void {
  const safeValue = redactCredentialString(value);
  const capture = cliOutputCapture.getStore();
  if (capture?.includeHuman) {
    capture.humanChunks.push(`${safeValue}\n`);
    return;
  }
  console.log(safeValue);
}

/**
 * Write human output verbatim. Use only for content that is already
 * structurally redacted (for example pretty-printed redacted config), where
 * the line-oriented redaction in writeHumanLine would corrupt formatting.
 */
export function writeHumanLineRaw(value: string): void {
  const capture = cliOutputCapture.getStore();
  if (capture?.includeHuman) {
    capture.humanChunks.push(`${value}\n`);
    return;
  }
  console.log(value);
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
