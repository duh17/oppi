import { isSensitiveLogKey, REDACTED, redactLogString } from "./log-redact.js";

const STABLE_DEVICE_IDENTIFIER_KEYS = new Set(["deviceid"]);

const TOKEN_COLLECTIONS = new Map([
  ["authdevicetokens", "token"],
  ["pushdevicetokens", "token"],
  ["authaccesstokens", "token"],
  ["authdevices", "device"],
]);

function normalizedKey(key: string): string {
  return key.replace(/[^A-Za-z0-9]+/g, "").toLowerCase();
}

function collectionSummary(count: number, singular: string): string {
  return `[REDACTED ${count} ${count === 1 ? singular : `${singular}s`}]`;
}

export function redactCredentialString(value: string): string {
  const patternRedacted = redactLogString(value, Math.max(2_048, value.length * 2));
  return patternRedacted
    .split("\n")
    .map((line) => {
      const keyedValue = line.match(
        /^(\s*)(?:"([^"]+)"|([A-Z][A-Z0-9_]*))(\s*[:=]\s*)(.*?)(,?\s*)$/,
      );
      const key = keyedValue?.[2] ?? keyedValue?.[3];
      if (key && keyedValue) {
        const normalized = normalizedKey(key);
        if (
          TOKEN_COLLECTIONS.has(normalized) ||
          isSensitiveLogKey(key) ||
          STABLE_DEVICE_IDENTIFIER_KEYS.has(normalized)
        ) {
          const renderedKey = keyedValue?.[2] ? `"${key}"` : key;
          return `${keyedValue[1]}${renderedKey}${keyedValue[4]}"${REDACTED}"${keyedValue[6]}`;
        }
      }

      const trimmed = line.trim();
      if (
        !(
          (trimmed.startsWith("{") && trimmed.endsWith("}")) ||
          (trimmed.startsWith("[") && trimmed.endsWith("]"))
        )
      ) {
        return line;
      }
      try {
        return JSON.stringify(redactCredentialValue(JSON.parse(trimmed) as unknown));
      } catch {
        return line;
      }
    })
    .join("\n");
}

export function redactCredentialValue(value: unknown, key?: string): unknown {
  const normalized = key ? normalizedKey(key) : "";
  const collection = TOKEN_COLLECTIONS.get(normalized);
  if (collection && Array.isArray(value)) return collectionSummary(value.length, collection);
  if (
    key &&
    (isSensitiveLogKey(key) || STABLE_DEVICE_IDENTIFIER_KEYS.has(normalized)) &&
    normalized !== "tokencount"
  ) {
    return REDACTED;
  }

  if (value === null || value === undefined) return value;
  if (typeof value === "string") return redactCredentialString(value);
  if (typeof value === "number" || typeof value === "boolean" || typeof value === "bigint") {
    return value;
  }
  if (value instanceof Date) return value.toISOString();
  if (value instanceof Error) {
    return {
      name: redactCredentialString(value.name),
      message: redactCredentialString(value.message),
    };
  }
  if (Array.isArray(value)) return value.map((item) => redactCredentialValue(item));
  if (value instanceof Set) return [...value].map((item) => redactCredentialValue(item));
  if (value instanceof Map) {
    return Object.fromEntries(
      [...value.entries()].map(([entryKey, entryValue]) => [
        String(entryKey),
        redactCredentialValue(entryValue, String(entryKey)),
      ]),
    );
  }
  if (typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).flatMap(([entryKey, entryValue]) => {
        const redacted = redactCredentialValue(entryValue, entryKey);
        return redacted === undefined ? [] : [[entryKey, redacted]];
      }),
    );
  }
  return redactCredentialString(String(value));
}
