import { randomBytes } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

import { HttpStatusError } from "../http-status-error.js";
import { isRecord } from "../json-shape.js";
import { cleanLabel } from "../layout-validation.js";
import type { Pin, PinTarget } from "../types.js";
import { writeFileAtomic } from "./atomic-file.js";

export class PinsError extends HttpStatusError {}

export const MAX_PINS = 50;
export const MAX_PIN_LABEL_CHARACTERS = 40;
const MAX_PIN_PATH_BYTES = 1024;
const MAX_PIN_SESSION_ID_BYTES = 256;
const PIN_ID = /^pin_[A-Za-z0-9_-]{12}$/;

interface PinsRecord {
  version: 1;
  revision: number;
  pins: Pin[];
}

/** A `PUT /pins` entry: which pin, in this place, with this label (absent clears it). */
export interface PinOrderEntry {
  id: string;
  label?: string;
}

/** The result of a change: `changed` is false when the list was already that way. */
export interface PinsChange {
  revision: number;
  pins: Pin[];
  changed: boolean;
}

/**
 * A relative path of plain segments: no `.` or `..`, no empty segment, no controls, at most 1 KiB.
 * A trailing `/` is dropped. This is what keeps a pin inside its root before anything is read.
 */
function plainRelativePath(path: string): string | null {
  const trimmed = path.endsWith("/") ? path.slice(0, -1) : path;
  if (!trimmed) return "";
  if (Buffer.byteLength(trimmed, "utf8") > MAX_PIN_PATH_BYTES) return null;
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001f\u007f]/.test(trimmed)) return null;
  const segments = trimmed.split("/");
  if (segments.some((segment) => !segment || segment === "." || segment === "..")) return null;
  return trimmed;
}

/**
 * The target a pin may store, in its one canonical form, or a 400. A host path is `~` or `~/…`
 * (never absolute, never `~user`); a workspace path is relative to the workspace root; a session
 * target names a session id of plain characters.
 */
export function validatePinTarget(value: unknown): PinTarget {
  if (isRecord(value) && value.origin === "session") {
    const id = value.sessionId;
    if (
      Object.keys(value).length !== 2 ||
      typeof id !== "string" ||
      !id ||
      Buffer.byteLength(id, "utf8") > MAX_PIN_SESSION_ID_BYTES ||
      // eslint-disable-next-line no-control-regex
      /[\u0000-\u001f\u007f]/.test(id)
    ) {
      throw new PinsError(400, "A session pin names a session id");
    }
    return { origin: "session", sessionId: id };
  }
  if (!isRecord(value) || typeof value.path !== "string") {
    throw new PinsError(400, "Expected target with origin and path");
  }
  if (value.origin === "host" && Object.keys(value).length === 2) {
    if (value.path === "~" || value.path === "~/") return { origin: "host", path: "~" };
    const rest = value.path.startsWith("~/") ? plainRelativePath(value.path.slice(2)) : null;
    if (!rest) throw new PinsError(400, "A Home pin names a path inside ~/");
    return { origin: "host", path: `~/${rest}` };
  }
  if (
    value.origin === "workspace" &&
    Object.keys(value).length === 3 &&
    typeof value.workspaceId === "string" &&
    value.workspaceId
  ) {
    const path = value.path.startsWith("~") ? null : plainRelativePath(value.path);
    if (path === null)
      throw new PinsError(400, "A workspace pin names a path inside the workspace");
    return { origin: "workspace", workspaceId: value.workspaceId, path };
  }
  throw new PinsError(400, "Expected target with origin and path");
}

/** A label as it is stored: cleaned, 1–40 characters, or undefined for none. */
export function validatePinLabel(value: unknown): string | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "string") throw new PinsError(400, "label must be a string");
  const label = cleanLabel(value);
  if (!label) return undefined;
  if ([...label].length > MAX_PIN_LABEL_CHARACTERS) {
    throw new PinsError(400, `A pin label has at most ${MAX_PIN_LABEL_CHARACTERS} characters`);
  }
  return label;
}

/** The entries of a `PUT /pins`: at most 50, each an id once, with an optional label. */
export function validatePinOrder(value: unknown): PinOrderEntry[] {
  if (!Array.isArray(value) || value.length > MAX_PINS) {
    throw new PinsError(400, `Expected pins, at most ${MAX_PINS}`);
  }
  const entries = value.map((entry): PinOrderEntry => {
    if (
      !isRecord(entry) ||
      typeof entry.id !== "string" ||
      Object.keys(entry).some((key) => key !== "id" && key !== "label")
    ) {
      throw new PinsError(400, "Expected pins of { id, label? }");
    }
    const label = validatePinLabel(entry.label);
    return label === undefined ? { id: entry.id } : { id: entry.id, label };
  });
  if (new Set(entries.map((entry) => entry.id)).size !== entries.length) {
    throw new PinsError(400, "Duplicate pin id");
  }
  return entries;
}

function sameTarget(a: PinTarget, b: PinTarget): boolean {
  switch (a.origin) {
    case "host":
      return b.origin === "host" && a.path === b.path;
    case "workspace":
      return b.origin === "workspace" && a.workspaceId === b.workspaceId && a.path === b.path;
    case "session":
      return b.origin === "session" && a.sessionId === b.sessionId;
  }
}

function validStoredPin(value: unknown): value is Pin {
  if (!isRecord(value) || typeof value.id !== "string" || !PIN_ID.test(value.id)) return false;
  if (value.kind !== "directory" && value.kind !== "file" && value.kind !== "session") return false;
  if (typeof value.createdAt !== "number") return false;
  try {
    const target = validatePinTarget(value.target);
    // A session target is a session pin, and only it is.
    if ((target.origin === "session") !== (value.kind === "session")) return false;
    return (
      sameTarget(target, value.target as PinTarget) && value.label === validatePinLabel(value.label)
    );
  } catch {
    return false;
  }
}

/**
 * The server's pins, in `<dataDir>/settings/pins.json`. Every change bumps `revision` once; a
 * change that leaves the list as it was does not. Writes are synchronous, so a read-change-write
 * never interleaves with another in this process.
 */
export class PinsStore {
  private readonly directory: string;
  private readonly path: string;

  constructor(dataDir: string) {
    this.directory = join(dataDir, "settings");
    this.path = join(this.directory, "pins.json");
  }

  list(): { revision: number; pins: Pin[] } {
    const record = this.read();
    return { revision: record.revision, pins: record.pins };
  }

  /** Saves a new pin last, or answers the saved pin with the same target. */
  add(target: PinTarget, kind: Pin["kind"], label: string | undefined): PinsChange & { pin: Pin } {
    const record = this.read();
    const existing = record.pins.find((pin) => sameTarget(pin.target, target));
    if (existing)
      return { revision: record.revision, pins: record.pins, changed: false, pin: existing };
    if (record.pins.length >= MAX_PINS) {
      throw new PinsError(400, `A server keeps at most ${MAX_PINS} pins`);
    }
    const pin: Pin = {
      id: `pin_${randomBytes(9).toString("base64url")}`,
      target,
      kind,
      ...(label === undefined ? {} : { label }),
      createdAt: Date.now(),
    };
    const next = { ...record, revision: record.revision + 1, pins: [...record.pins, pin] };
    this.persist(next);
    return { revision: next.revision, pins: next.pins, changed: true, pin };
  }

  /**
   * Puts the pins in `entries`' order with their labels and removes the rest. A stale
   * `baseRevision` changes nothing and answers `conflict`; an id the list does not hold is a 400.
   */
  reorder(baseRevision: number, entries: PinOrderEntry[]): PinsChange | { conflict: true } {
    const record = this.read();
    if (baseRevision !== record.revision) return { conflict: true };
    const byId = new Map(record.pins.map((pin) => [pin.id, pin]));
    const pins = entries.map((entry): Pin => {
      const pin = byId.get(entry.id);
      if (!pin) throw new PinsError(400, "Unknown pin id");
      const { label: _old, ...rest } = pin;
      return entry.label === undefined ? rest : { ...rest, label: entry.label };
    });
    const unchanged =
      pins.length === record.pins.length &&
      pins.every((pin, index) => {
        const before = record.pins[index];
        return before?.id === pin.id && before.label === pin.label;
      });
    if (unchanged) return { revision: record.revision, pins: record.pins, changed: false };
    const next = { ...record, revision: record.revision + 1, pins };
    this.persist(next);
    return { revision: next.revision, pins, changed: true };
  }

  private read(): PinsRecord {
    if (!existsSync(this.path)) return { version: 1, revision: 0, pins: [] };
    try {
      const stat = lstatSync(this.path);
      if (!stat.isFile() || stat.isSymbolicLink()) throw Error();
      const value: unknown = JSON.parse(readFileSync(this.path, "utf8"));
      if (
        !isRecord(value) ||
        value.version !== 1 ||
        typeof value.revision !== "number" ||
        !Number.isSafeInteger(value.revision) ||
        value.revision < 0 ||
        !Array.isArray(value.pins) ||
        value.pins.length > MAX_PINS ||
        !value.pins.every(validStoredPin)
      ) {
        throw Error();
      }
      return { version: 1, revision: value.revision, pins: value.pins };
    } catch {
      // Never overwrite a damaged file: rewriting it from nothing would drop every pin.
      throw new PinsError(503, "Pins unavailable; repair required");
    }
  }

  private persist(record: PinsRecord): void {
    try {
      if (existsSync(this.directory)) {
        const stat = lstatSync(this.directory);
        if (!stat.isDirectory() || stat.isSymbolicLink()) throw Error();
      } else mkdirSync(this.directory, { recursive: true, mode: 0o700 });
      writeFileAtomic(this.path, JSON.stringify(record), { durable: true });
    } catch {
      throw new PinsError(503, "Pins unavailable; write failed");
    }
  }
}
