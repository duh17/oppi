import { redactLogValue } from "./log-redact.js";

export type LogLevel = "debug" | "info" | "warn" | "error";

export type LogContext = Record<string, unknown>;

export interface Logger {
  debug(event: string, context?: LogContext): void;
  info(event: string, context?: LogContext): void;
  warn(event: string, context?: LogContext): void;
  error(event: string, context?: LogContext): void;
  child(context: LogContext): Logger;
  isEnabled(level: LogLevel): boolean;
}

export interface LoggerOptions {
  level?: LogLevel;
  base?: LogContext;
  sink?: (level: LogLevel, line: string) => void;
  now?: () => string;
}

const LEVEL_RANK: Record<LogLevel, number> = {
  debug: 10,
  info: 20,
  warn: 30,
  error: 40,
};

const RESERVED_KEYS = new Set(["ts", "level", "event"]);

function parseLevel(raw: string | undefined): LogLevel | undefined {
  const normalized = (raw || "").trim().toLowerCase();
  switch (normalized) {
    case "debug":
      return "debug";
    case "info":
      return "info";
    case "warn":
      return "warn";
    case "error":
      return "error";
    default:
      return undefined;
  }
}

function resolveDefaultLevel(): LogLevel {
  return parseLevel(process.env.OPPI_LOG_LEVEL) ?? "info";
}

function defaultSink(_level: LogLevel, line: string): void {
  process.stderr.write(`${line}\n`);
}

function sanitizeContext(
  base: LogContext | undefined,
  context: LogContext | undefined,
): LogContext {
  const merged: LogContext = {
    ...(base ?? {}),
    ...(context ?? {}),
  };

  const redacted = redactLogValue(merged);
  if (typeof redacted !== "object" || redacted === null || Array.isArray(redacted)) {
    return {};
  }

  const out: LogContext = {};
  for (const [key, value] of Object.entries(redacted as Record<string, unknown>)) {
    if (RESERVED_KEYS.has(key)) {
      continue;
    }
    if (value === undefined) {
      continue;
    }
    out[key] = value;
  }

  return out;
}

export function createLogger(options: LoggerOptions = {}): Logger {
  const level = options.level ?? resolveDefaultLevel();
  const minRank = LEVEL_RANK[level];
  const sink = options.sink ?? defaultSink;
  const now = options.now ?? (() => new Date().toISOString());
  const base = options.base;

  const emit = (entryLevel: LogLevel, event: string, context?: LogContext): void => {
    if (LEVEL_RANK[entryLevel] < minRank) {
      return;
    }

    const payload = {
      ts: now(),
      level: entryLevel,
      event,
      ...sanitizeContext(base, context),
    };

    sink(entryLevel, JSON.stringify(payload));
  };

  return {
    debug: (event, context) => emit("debug", event, context),
    info: (event, context) => emit("info", event, context),
    warn: (event, context) => emit("warn", event, context),
    error: (event, context) => emit("error", event, context),
    child: (context) =>
      createLogger({
        level,
        base: { ...(base ?? {}), ...context },
        sink,
        now,
      }),
    isEnabled: (entryLevel) => LEVEL_RANK[entryLevel] >= minRank,
  };
}
