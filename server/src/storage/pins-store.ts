import { randomBytes } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

import { GODOT_PROJECT_ID } from "../godot/godot-protocol.js";
import { HttpStatusError } from "../http-status-error.js";
import { isRecord } from "../json-shape.js";
import { cleanLabel, isLoopbackHost } from "../layout-validation.js";
import type { Pin, PinRoute } from "../types.js";
import { writeFileAtomic } from "./atomic-file.js";

export class PinsError extends HttpStatusError {}

export const MAX_PINS = 50;
export const MAX_PIN_LABEL_CHARACTERS = 40;
const MAX_PIN_PATH_BYTES = 1024;
const MAX_PIN_NAME_BYTES = 256;
const MAX_PIN_URL_BYTES = 2048;
const PIN_ID = /^pin_[A-Za-z0-9_-]{12}$/;
/** Route kinds a link opens that a pin no longer names; a stored one is dropped on read. */
const UNPINNED_KINDS = new Set(["git", "commit"]);

/**
 * `pins.json`. Version 2 stores pane routes; version 1 (folders, files, and sessions as
 * `{ origin, … }` targets with a `kind`) is read as routes and written as version 2 on the next
 * change.
 */
interface PinsRecord {
  version: 2;
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

/** A home path as stored: `~` for the home folder itself, else `~/` and a plain relative path. */
function homePath(path: string): string | null {
  if (path === "~" || path === "~/") return "~";
  const rest = path.startsWith("~/") ? plainRelativePath(path.slice(2)) : null;
  return rest ? `~/${rest}` : null;
}

/** A session, workspace, worktree, or panel id: plain characters, at most 256 bytes. */
function isName(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    Buffer.byteLength(value, "utf8") <= MAX_PIN_NAME_BYTES &&
    // eslint-disable-next-line no-control-regex
    !/[\u0000-\u001f\u007f]/.test(value)
  );
}

/** A web page a pin may name: the rules a layout's `web` and a browser link follow. */
function isPinnableURL(value: unknown): value is string {
  if (typeof value !== "string" || Buffer.byteLength(value, "utf8") > MAX_PIN_URL_BYTES) {
    return false;
  }
  try {
    const url = new URL(value);
    return (
      (url.protocol === "http:" || url.protocol === "https:") &&
      !url.username &&
      !url.password &&
      !isLoopbackHost(url.hostname)
    );
  } catch {
    return false;
  }
}

/**
 * The route a pin may store, in its one canonical form, or a 400. Every field of the kind must be
 * present (`null` where the link leaves it out) and no other. Paths stay inside their root: a
 * workspace or session path is plain and relative, a home path is `~` or `~/…` (never absolute).
 */
export function validatePinRoute(value: unknown): PinRoute {
  const bad = (what: string): never => {
    throw new PinsError(400, `A ${what}`);
  };
  if (!isRecord(value) || typeof value.kind !== "string") return bad("pin names a pane route");
  const v = value;
  const has = (...keys: string[]): boolean => {
    const own = Object.keys(v);
    return own.length === keys.length + 1 && keys.every((key) => key in v);
  };
  const nullable = (field: unknown): field is string | null => field === null || isName(field);
  const line = (field: unknown): field is number | null =>
    field === null || (Number.isSafeInteger(field) && (field as number) > 0);
  const relative = (field: unknown): string | null =>
    typeof field === "string" && !field.startsWith("~") ? plainRelativePath(field) : null;
  switch (v.kind) {
    case "sessions":
      if (!has("workspace") || !nullable(v.workspace))
        bad("sessions pin names a workspace or null");
      return { kind: "sessions", workspace: v.workspace as string | null };
    case "session":
    case "thread":
      if (!has("id") || !isName(v.id)) bad(`${v.kind} pin names a session id`);
      return { kind: v.kind, id: v.id as string };
    case "file": {
      if (!line(v.line)) bad("file pin's line is a positive number or null");
      const ln = v.line as number | null;
      if (v.origin === "workspace") {
        const path = relative(v.path);
        if (
          !has("origin", "workspace", "worktree", "path", "line") ||
          !isName(v.workspace) ||
          !nullable(v.worktree) ||
          !path
        ) {
          bad("workspace file pin names a path inside the checkout");
        }
        return {
          kind: "file",
          origin: "workspace",
          workspace: v.workspace as string,
          worktree: v.worktree as string | null,
          path: path as string,
          line: ln,
        };
      }
      if (v.origin === "host") {
        const path = typeof v.path === "string" ? homePath(v.path) : null;
        if (!has("origin", "path", "line") || !path || path === "~") {
          bad("Home file pin names a path inside ~/");
        }
        return { kind: "file", origin: "host", path: path as string, line: ln };
      }
      if (v.origin === "session") {
        const path = relative(v.path);
        if (!has("origin", "session", "path", "line") || !isName(v.session) || !path) {
          bad("session file pin names a path inside the session's copy");
        }
        return {
          kind: "file",
          origin: "session",
          session: v.session as string,
          path: path as string,
          line: ln,
        };
      }
      return bad("file pin's origin is workspace, host, or session");
    }
    case "files": {
      if ("origin" in v) {
        const path = v.path === null ? "~" : typeof v.path === "string" ? homePath(v.path) : null;
        if (!has("origin", "path") || v.origin !== "host" || !path) {
          bad("Home folder pin names ~ or a path inside ~/");
        }
        return { kind: "files", origin: "host", path: path === "~" ? null : (path as string) };
      }
      const path = v.path === null ? "" : relative(v.path);
      if (!has("workspace", "path") || !isName(v.workspace) || path === null) {
        bad("workspace folder pin names a path inside the workspace");
      }
      return { kind: "files", workspace: v.workspace as string, path: path || null };
    }
    case "panel":
      if (!has("session", "id") || !isName(v.session) || !isName(v.id)) {
        bad("panel pin names a session and a panel id");
      }
      return { kind: "panel", session: v.session as string, id: v.id as string };
    case "browser":
      if (!has("url") || !isPinnableURL(v.url)) {
        bad("web page pin names an http or https URL that is not loopback, at most 2 KiB");
      }
      return { kind: "browser", url: v.url as string };
    case "godot":
      if (!has("project") || typeof v.project !== "string" || !GODOT_PROJECT_ID.test(v.project)) {
        bad("game pin names a Godot project id");
      }
      return { kind: "godot", project: v.project as string };
    default:
      return bad("pin names a pane route");
  }
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

/** One string per route, whatever order its fields were written in: two pins of one route match. */
export function pinRouteKey(route: PinRoute): string {
  const record = route as Record<string, unknown>;
  return JSON.stringify(
    Object.keys(record)
      .sort()
      .map((key) => [key, record[key]]),
  );
}

/** A stored pin with a route in canonical form, or undefined. */
function storedPin(value: Record<string, unknown>, target: unknown): Pin | undefined {
  if (typeof value.id !== "string" || !PIN_ID.test(value.id)) return undefined;
  if (typeof value.createdAt !== "number") return undefined;
  try {
    const route = validatePinRoute(target);
    if (pinRouteKey(route) !== pinRouteKey(target as PinRoute)) return undefined;
    const label = validatePinLabel(value.label);
    if (label !== value.label) return undefined;
    return {
      id: value.id,
      target: route,
      ...(label === undefined ? {} : { label }),
      createdAt: value.createdAt,
    };
  } catch {
    return undefined;
  }
}

/**
 * A version 1 pin as the route it opened: a Home or workspace folder is a `files` route, a file a
 * `file` route in the main checkout, a session a `session` route.
 */
function migratedV1Pin(value: unknown): Pin | undefined {
  if (!isRecord(value) || !isRecord(value.target)) return undefined;
  const { target, kind } = value;
  let route: unknown;
  if (target.origin === "session" && kind === "session" && Object.keys(target).length === 2) {
    route = { kind: "session", id: target.sessionId };
  } else if (target.origin === "host" && Object.keys(target).length === 2) {
    if (kind === "directory") {
      route = { kind: "files", origin: "host", path: target.path === "~" ? null : target.path };
    } else if (kind === "file") {
      route = { kind: "file", origin: "host", path: target.path, line: null };
    }
  } else if (target.origin === "workspace" && Object.keys(target).length === 3) {
    if (kind === "directory") {
      route = {
        kind: "files",
        workspace: target.workspaceId,
        path: target.path === "" ? null : target.path,
      };
    } else if (kind === "file") {
      route = {
        kind: "file",
        origin: "workspace",
        workspace: target.workspaceId,
        worktree: null,
        path: target.path,
        line: null,
      };
    }
  }
  return route === undefined ? undefined : storedPin(value, route);
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

  /** Saves a new pin last, or answers the saved pin with the same route. */
  add(target: PinRoute, label: string | undefined): PinsChange & { pin: Pin } {
    const record = this.read();
    const key = pinRouteKey(target);
    const existing = record.pins.find((pin) => pinRouteKey(pin.target) === key);
    if (existing)
      return { revision: record.revision, pins: record.pins, changed: false, pin: existing };
    if (record.pins.length >= MAX_PINS) {
      throw new PinsError(400, `A server keeps at most ${MAX_PINS} pins`);
    }
    const pin: Pin = {
      id: `pin_${randomBytes(9).toString("base64url")}`,
      target,
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
    if (!existsSync(this.path)) return { version: 2, revision: 0, pins: [] };
    try {
      const stat = lstatSync(this.path);
      if (!stat.isFile() || stat.isSymbolicLink()) throw Error();
      const value: unknown = JSON.parse(readFileSync(this.path, "utf8"));
      if (
        !isRecord(value) ||
        (value.version !== 1 && value.version !== 2) ||
        typeof value.revision !== "number" ||
        !Number.isSafeInteger(value.revision) ||
        value.revision < 0 ||
        !Array.isArray(value.pins) ||
        value.pins.length > MAX_PINS
      ) {
        throw Error();
      }
      // A Git or commit pin an earlier server saved is left out; the next change drops it on disk.
      const pins = value.pins
        .filter(
          (pin: unknown) =>
            !(
              isRecord(pin) &&
              isRecord(pin.target) &&
              UNPINNED_KINDS.has(pin.target.kind as string)
            ),
        )
        .map((pin: unknown) =>
          value.version === 1
            ? migratedV1Pin(pin)
            : isRecord(pin)
              ? storedPin(pin, pin.target)
              : undefined,
        );
      if (!pins.every((pin): pin is Pin => pin !== undefined)) throw Error();
      if (new Set(pins.map((pin) => pinRouteKey(pin.target))).size !== pins.length) throw Error();
      return { version: 2, revision: value.revision, pins };
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
