const DEFAULT_MAX_DEPTH = 6;
const DEFAULT_MAX_STRING_LENGTH = 2_048;
const DEFAULT_MAX_ARRAY_LENGTH = 64;
const DEFAULT_MAX_OBJECT_KEYS = 64;

const MAX_STRING_FLOOR = 64;

export const REDACTED = "[REDACTED]";
const TRUNCATED = "[TRUNCATED]";
const CIRCULAR = "[CIRCULAR]";
const DEPTH_LIMIT = "[DEPTH_LIMIT]";

const SENSITIVE_KEY =
  /(?:^|[_-])(authorization|auth|cookie|token|secret|password|passwd|api[_-]?key|access[_-]?key|private[_-]?key|refresh[_-]?token|client[_-]?secret)(?:$|[_-])/i;

const SENSITIVE_NORMALIZED_KEY_TERMS = [
  "authorization",
  "cookie",
  "secret",
  "password",
  "passwd",
  "apikey",
  "accesskey",
  "privatekey",
  "refreshtoken",
  "clientsecret",
  "accesstoken",
  "authtoken",
] as const;

export function isSensitiveLogKey(key: string): boolean {
  if (SENSITIVE_KEY.test(key)) {
    return true;
  }

  const normalized = key.replace(/[^A-Za-z0-9]+/g, "").toLowerCase();
  if (!normalized) {
    return false;
  }

  if (normalized === "auth" || normalized === "token") {
    return true;
  }

  if (normalized.endsWith("token") && normalized !== "tokens") {
    return true;
  }

  return SENSITIVE_NORMALIZED_KEY_TERMS.some((term) => normalized.includes(term));
}

const SECRET_VALUE_PATTERNS: Array<{ pattern: RegExp; replacement: string }> = [
  {
    pattern: /Bearer\s+[A-Za-z0-9\-._~+/]+=*/gi,
    replacement: "Bearer [REDACTED]",
  },
  {
    pattern: /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----/g,
    replacement: "[REDACTED_PRIVATE_KEY]",
  },
  {
    pattern: /\bsk_(?:live|test|proj)-[A-Za-z0-9]{8,}\b/g,
    replacement: REDACTED,
  },
  {
    pattern: /\bgh[opusr]_[A-Za-z0-9]{20,}\b/g,
    replacement: REDACTED,
  },
  {
    pattern: /\bgithub_pat_[A-Za-z0-9_]{20,}\b/g,
    replacement: REDACTED,
  },
  {
    pattern: /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/g,
    replacement: REDACTED,
  },
  {
    pattern: /\bAKIA[0-9A-Z]{16}\b/g,
    replacement: REDACTED,
  },
  {
    pattern: /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9._-]{8,}\.[A-Za-z0-9._-]{8,}\b/g,
    replacement: REDACTED,
  },
  {
    pattern: /([?&](?:token|api[_-]?key|access[_-]?token|auth)=)[^&\s]+/gi,
    replacement: `$1${REDACTED}`,
  },
];

export interface LogRedactOptions {
  maxDepth?: number;
  maxStringLength?: number;
  maxArrayLength?: number;
  maxObjectKeys?: number;
}

interface ResolvedLogRedactOptions {
  maxDepth: number;
  maxStringLength: number;
  maxArrayLength: number;
  maxObjectKeys: number;
}

function resolveOptions(options: LogRedactOptions | undefined): ResolvedLogRedactOptions {
  const maxDepth = Math.max(1, Math.floor(options?.maxDepth ?? DEFAULT_MAX_DEPTH));
  const maxStringLength = Math.max(
    MAX_STRING_FLOOR,
    Math.floor(options?.maxStringLength ?? DEFAULT_MAX_STRING_LENGTH),
  );
  const maxArrayLength = Math.max(
    1,
    Math.floor(options?.maxArrayLength ?? DEFAULT_MAX_ARRAY_LENGTH),
  );
  const maxObjectKeys = Math.max(1, Math.floor(options?.maxObjectKeys ?? DEFAULT_MAX_OBJECT_KEYS));

  return {
    maxDepth,
    maxStringLength,
    maxArrayLength,
    maxObjectKeys,
  };
}

export function redactLogString(
  input: string,
  maxStringLength = DEFAULT_MAX_STRING_LENGTH,
): string {
  let output = input;
  for (const { pattern, replacement } of SECRET_VALUE_PATTERNS) {
    output = output.replace(pattern, replacement);
  }

  if (output.length <= maxStringLength) {
    return output;
  }

  const truncatedChars = output.length - maxStringLength;
  return `${output.slice(0, maxStringLength)}…${TRUNCATED}(${truncatedChars} chars)`;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function sanitizeError(error: Error, options: ResolvedLogRedactOptions): Record<string, unknown> {
  const out: Record<string, unknown> = {
    name: redactLogString(error.name, options.maxStringLength),
    message: redactLogString(error.message, options.maxStringLength),
  };

  if (typeof error.stack === "string" && error.stack.length > 0) {
    out.stack = redactLogString(error.stack, options.maxStringLength);
  }

  return out;
}

function sanitizeValue(
  value: unknown,
  key: string | undefined,
  depth: number,
  seen: WeakSet<object>,
  options: ResolvedLogRedactOptions,
): unknown {
  if (key && isSensitiveLogKey(key)) {
    return REDACTED;
  }

  if (value === null) {
    return null;
  }

  if (typeof value === "string") {
    return redactLogString(value, options.maxStringLength);
  }

  if (typeof value === "number") {
    return Number.isFinite(value) ? value : String(value);
  }

  if (typeof value === "boolean") {
    return value;
  }

  if (typeof value === "bigint") {
    return value.toString();
  }

  if (typeof value === "undefined") {
    return undefined;
  }

  if (typeof value === "symbol") {
    return value.toString();
  }

  if (typeof value === "function") {
    return "[FUNCTION]";
  }

  if (value instanceof Error) {
    return sanitizeError(value, options);
  }

  if (value instanceof Date) {
    return Number.isFinite(value.getTime()) ? value.toISOString() : "[INVALID_DATE]";
  }

  if (typeof Buffer !== "undefined" && Buffer.isBuffer(value)) {
    return `<Buffer ${value.length} bytes>`;
  }

  if (depth >= options.maxDepth) {
    return DEPTH_LIMIT;
  }

  if (typeof value === "object" && value !== null) {
    if (seen.has(value)) {
      return CIRCULAR;
    }
    seen.add(value);
  }

  if (Array.isArray(value)) {
    const out: unknown[] = [];
    const size = Math.min(value.length, options.maxArrayLength);

    for (let i = 0; i < size; i++) {
      out.push(sanitizeValue(value[i], undefined, depth + 1, seen, options));
    }

    if (value.length > options.maxArrayLength) {
      out.push(`[+${value.length - options.maxArrayLength} items]`);
    }

    return out;
  }

  if (value instanceof Set) {
    return sanitizeValue(Array.from(value.values()), key, depth + 1, seen, options);
  }

  if (value instanceof Map) {
    return sanitizeValue(Object.fromEntries(value.entries()), key, depth + 1, seen, options);
  }

  if (isRecord(value)) {
    const out: Record<string, unknown> = {};
    const entries = Object.entries(value);
    const size = Math.min(entries.length, options.maxObjectKeys);

    for (let i = 0; i < size; i++) {
      const [entryKey, entryValue] = entries[i];
      const sanitized = sanitizeValue(entryValue, entryKey, depth + 1, seen, options);
      if (sanitized !== undefined) {
        out[entryKey] = sanitized;
      }
    }

    if (entries.length > options.maxObjectKeys) {
      out._truncatedKeys = entries.length - options.maxObjectKeys;
    }

    return out;
  }

  return redactLogString(String(value), options.maxStringLength);
}

export function redactLogValue(value: unknown, options?: LogRedactOptions): unknown {
  const resolved = resolveOptions(options);
  return sanitizeValue(value, undefined, 0, new WeakSet<object>(), resolved);
}
