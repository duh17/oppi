/**
 * Catalog validation shared by app-event ingest and the server emitter. One
 * implementation, so an event the server would store is exactly an event the
 * catalog allows.
 */

import {
  EVENT_DEFS,
  NAME_TAG_FALLBACK,
  NAME_TAG_PATTERN,
  TAG_DEFS,
  eventOrigin,
  fieldSpec,
  type EmitRule,
  type EventDef,
  type TelemetryOrigin,
} from "./catalog.js";
import type { TelemetryDropReason } from "../types.js";

export interface ValidatedEvent {
  name: string;
  fields: Record<string, number>;
  tags: Record<string, string>;
}

export type ValidationResult =
  { ok: true; event: ValidatedEvent } | { ok: false; reason: TelemetryDropReason };

const PRIVATE_HOST_SUFFIX = /\.(local|lan|internal|localdomain|ts\.net|home\.arpa)$/i;
const IPV4 = /^\d{1,3}(\.\d{1,3}){3}(:\d+)?$/;
const HOST_PORT = /^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+:\d{2,5}$/;
const USER_AT_HOST = /^[^@]+@[^@]*\.[A-Za-z]{2,}$/;

/**
 * True when a name looks like a URL, host, address, or filesystem path rather
 * than an identifier. A tag source is not trusted to be a vocabulary: a
 * configured endpoint or an unregistered client string must not reach storage as
 * a "name". The Swift twin in `TelemetryName` applies the same rules.
 */
export function looksLikeLocation(value: string, allowRoute = false): boolean {
  if (value.includes("://") || value.startsWith("~")) return true;
  if (value.startsWith("/") && !allowRoute) return true;
  if (/(^|[^A-Za-z0-9])localhost([^A-Za-z0-9]|$)/i.test(value)) return true;
  return (
    PRIVATE_HOST_SUFFIX.test(value) ||
    IPV4.test(value) ||
    HOST_PORT.test(value) ||
    USER_AT_HOST.test(value)
  );
}

/**
 * A `name` tag value as stored: safe identifiers pass, anything else (including
 * anything shaped like a host, URL, or path) is `unknown`.
 */
export function sanitizeNameTag(value: string, allowRoute = false): string {
  return NAME_TAG_PATTERN.test(value) && !looksLikeLocation(value, allowRoute)
    ? value
    : NAME_TAG_FALLBACK;
}

/** True when `tags` satisfy a catalog `where` filter (absent selects everything). */
export function tagsMatch(
  where: Readonly<Record<string, readonly string[]>> | undefined,
  tags: Readonly<Record<string, string>>,
): boolean {
  if (!where) return true;
  for (const [key, values] of Object.entries(where)) {
    const value = tags[key];
    if (value === undefined || !values.includes(value)) return false;
  }
  return true;
}

/** True when no emit rule of the event rejects these values. */
export function passesEmitPolicy(
  rules: readonly EmitRule[] | undefined,
  fields: Readonly<Record<string, number>>,
  tags: Readonly<Record<string, string>>,
): boolean {
  if (!rules) return true;
  for (const rule of rules) {
    const value = fields[rule.field];
    if (value === undefined || !tagsMatch(rule.where, tags)) continue;
    if (rule.min !== undefined && value < rule.min) return false;
    if (rule.max !== undefined && value >= rule.max) return false;
  }
  return true;
}

function validateFields(
  def: EventDef,
  raw: unknown,
): { ok: true; fields: Record<string, number> } | { ok: false; reason: TelemetryDropReason } {
  if (raw !== undefined && (raw === null || typeof raw !== "object" || Array.isArray(raw))) {
    return { ok: false, reason: "malformed" };
  }
  const input = (raw ?? {}) as Record<string, unknown>;
  const fields: Record<string, number> = {};
  for (const [key, value] of Object.entries(input)) {
    const fieldDef = def.fields[key];
    if (!fieldDef) return { ok: false, reason: "unknown_field" };
    if (value === null || value === undefined) continue;
    if (typeof value !== "number" || !Number.isFinite(value)) {
      return { ok: false, reason: "invalid_field_value" };
    }
    const unit = fieldSpec(fieldDef).unit;
    if (unit === "bool" && value !== 0 && value !== 1) {
      return { ok: false, reason: "invalid_field_value" };
    }
    fields[key] = value;
  }
  for (const [key, fieldDef] of Object.entries(def.fields)) {
    if (!fieldSpec(fieldDef).optional && fields[key] === undefined) {
      return { ok: false, reason: "missing_field" };
    }
  }
  return { ok: true, fields };
}

function validateTags(
  def: EventDef,
  raw: unknown,
): { ok: true; tags: Record<string, string> } | { ok: false; reason: TelemetryDropReason } {
  if (raw !== undefined && (raw === null || typeof raw !== "object" || Array.isArray(raw))) {
    return { ok: false, reason: "malformed" };
  }
  const input = (raw ?? {}) as Record<string, unknown>;
  const uses = def.tags ?? {};
  const tags: Record<string, string> = {};
  for (const [key, value] of Object.entries(input)) {
    const use = uses[key];
    const tagDef = TAG_DEFS[key];
    if (!use || !tagDef) return { ok: false, reason: "unknown_tag" };
    if (value === null || value === undefined || value === "") continue;
    if (typeof value !== "string") return { ok: false, reason: "invalid_tag_value" };
    switch (tagDef.kind) {
      case "name":
        tags[key] = sanitizeNameTag(value, tagDef.route === true);
        break;
      case "enum": {
        const allowed = use.values ?? tagDef.values;
        if (!allowed.includes(value)) return { ok: false, reason: "invalid_tag_value" };
        tags[key] = value;
        break;
      }
      case "bucket":
        if (!tagDef.buckets.some((bucket) => bucket.name === value)) {
          return { ok: false, reason: "invalid_tag_value" };
        }
        tags[key] = value;
        break;
    }
  }
  for (const [key, use] of Object.entries(uses)) {
    if (use.required && tags[key] === undefined) return { ok: false, reason: "missing_tag" };
  }
  return { ok: true, tags };
}

/**
 * Validate one event against the catalog: name and origin, every field and
 * its unit, every tag key and value, then the emit policy. The whole event is
 * dropped on the first violation; `name` tags are sanitized, never dropped.
 */
export function validateEvent(
  origin: TelemetryOrigin,
  name: unknown,
  rawFields: unknown,
  rawTags: unknown,
): ValidationResult {
  if (typeof name !== "string") return { ok: false, reason: "malformed" };
  const def = Object.hasOwn(EVENT_DEFS, name) ? EVENT_DEFS[name] : undefined;
  if (!def) return { ok: false, reason: "unknown_event" };
  if (eventOrigin(name) !== origin) return { ok: false, reason: "wrong_origin" };

  const fields = validateFields(def, rawFields);
  if (!fields.ok) return fields;
  const tags = validateTags(def, rawTags);
  if (!tags.ok) return tags;
  if (!passesEmitPolicy(def.emit, fields.fields, tags.tags)) {
    return { ok: false, reason: "emit_policy" };
  }
  return { ok: true, event: { name, fields: fields.fields, tags: tags.tags } };
}
