// The window an iPad simulator opens the app in, and the keyboard it shows.
//
// SpringBoard keeps the app's last window size per bundle id in its FrontBoard store
// (`data/Library/FrontBoard/applicationState.db`, key `SBApplicationLastWindowSizePerDisplayOrdinalKey`).
// It outlives uninstalling the app, so a slot whose last run left a small floating window opens every
// later run in that window: compact width, so the tests that need regular width skip or take the
// phone path and pass without checking the iPad layout. The same holds for a keyboard left floating:
// `KeyboardIsFloating` in `data/Library/Preferences/com.apple.keyboard.preferences.plist` keeps the
// keyboard undocked, so a test that types into a bar under the keyboard finds no docked one. Both
// stores are only safe to edit while the device is shut down; `prepareSimulator` does that before it
// boots an iPad slot.

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";

const WINDOW_SIZE_KEY = "SBApplicationLastWindowSizePerDisplayOrdinalKey";
/** The keyboard's own preference domain; the offsets it floats at are written beside the flag. */
const KEYBOARD_PREFS = "data/Library/Preferences/com.apple.keyboard.preferences.plist";
const FLOATING_KEYBOARD_KEYS = ["KeyboardIsFloating", "KeyboardFloatingPersistentHorizontalOffset", "KeyboardFloatingPersistentVerticalOffset"];
const SQLITE3 = "/usr/bin/sqlite3";
const PLUTIL = "/usr/bin/plutil";

export type PersistedWindow = {
  /** The remembered window, in points. */
  width: number;
  height: number;
  /** The display the window was sized against. */
  displayWidth: number;
  displayHeight: number;
};

export function frontBoardStorePath(homeDir: string, udid: string): string {
  return join(homeDir, "Library/Developer/CoreSimulator/Devices", udid, "data/Library/FrontBoard/applicationState.db");
}

export function keyboardPreferencesPath(homeDir: string, udid: string): string {
  return join(homeDir, "Library/Developer/CoreSimulator/Devices", udid, KEYBOARD_PREFS);
}

/** Whether `deviceType` is an iPad: its windows can float, an iPhone's cannot. */
export function isPadDeviceType(deviceType: string): boolean {
  return /\.iPad-/.test(deviceType);
}

/** A window smaller than its display is a floating one; a full-screen window fills it. */
export function isCompactWindow(window: PersistedWindow): boolean {
  return window.width < window.displayWidth - 1 || window.height < window.displayHeight - 1;
}

function sqlLiteral(value: string): string {
  return `'${value.replaceAll("'", "''")}'`;
}

/** The store's own rows hold the values; the macOS `sqlite3` reads them, so no SQLite binding is needed. */
function runSqlite(storePath: string, sql: string, readonly: boolean): string {
  const result = spawnSync(SQLITE3, [...(readonly ? ["-readonly"] : []), storePath, sql], { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(`sqlite3 failed on ${storePath}: ${result.stderr.trim() || `exit ${result.status}`}`);
  }
  return result.stdout;
}

function decodePlist(blob: Buffer): unknown {
  const result = spawnSync(PLUTIL, ["-convert", "json", "-o", "-", "-"], { input: blob });
  if (result.status !== 0) {
    throw new Error(`plutil could not read the stored window: ${result.stderr.toString().trim()}`);
  }
  return JSON.parse(result.stdout.toString());
}

type Size = { Width: number; Height: number };

const ROW_WHERE = (bundleId: string): string =>
  `key = (SELECT id FROM key_tab WHERE key = ${sqlLiteral(WINDOW_SIZE_KEY)})
     AND application_identifier = (SELECT id FROM application_identifier_tab WHERE application_identifier = ${sqlLiteral(bundleId)})`;

/**
 * The window SpringBoard remembers for `bundleId`, or null when it remembers none (a slot that never
 * ran the app, or whose store is not there yet). A read-only open is safe on a booted device; the
 * answer is what the device had last written.
 */
export function readPersistedWindow(storePath: string, bundleId: string): PersistedWindow | null {
  if (!existsSync(storePath)) {
    return null;
  }
  const hex = runSqlite(storePath, `SELECT hex(value) FROM kvs WHERE ${ROW_WHERE(bundleId)}`, true).trim();
  if (!hex) {
    return null;
  }
  const display = (decodePlist(Buffer.from(hex, "hex")) as { first?: { size?: Size; referenceBounds?: Size } }).first;
  if (!display?.size || !display.referenceBounds) {
    return null;
  }
  return {
    width: display.size.Width,
    height: display.size.Height,
    displayWidth: display.referenceBounds.Width,
    displayHeight: display.referenceBounds.Height,
  };
}

/**
 * Makes SpringBoard forget the remembered window of `bundleId`, so the next launch opens full size.
 * The device must be shut down: a booted SpringBoard holds the store open and writes its own copy
 * back. Returns whether a row was removed.
 */
export function forgetPersistedWindow(storePath: string, bundleId: string): boolean {
  if (!existsSync(storePath)) {
    return false;
  }
  const out = runSqlite(
    storePath,
    // The store is in WAL mode; fold the delete into the main file so a copy of it is whole.
    `DELETE FROM kvs WHERE ${ROW_WHERE(bundleId)}; SELECT changes(); PRAGMA wal_checkpoint(TRUNCATE);`,
    false,
  );
  return Number(out.split("\n")[0]) > 0;
}

/**
 * Whether the slot's keyboard preferences remember a floating (undocked) keyboard. It outlives an
 * uninstall, so a slot whose last run left the keyboard floating keeps it floating; the flag is also
 * the only trace, since a docked keyboard removes the offsets beside it. Read key by key:
 * `plutil -convert json` refuses a domain that holds a value JSON has no form for.
 */
export function floatingKeyboardRemembered(prefsPath: string): boolean {
  if (!existsSync(prefsPath)) {
    return false;
  }
  const result = spawnSync(PLUTIL, ["-extract", "KeyboardIsFloating", "raw", "-o", "-", prefsPath], { encoding: "utf8" });
  // A domain without the key is a docked keyboard, not an error.
  return result.status === 0 && result.stdout.trim() === "true";
}

/**
 * Makes the slot forget the floating keyboard, so the next boot docks it. The device must be shut
 * down: a booted keyd holds its domain in memory and writes its own copy back. Returns whether the
 * file had a floating keyboard to forget.
 */
export function forgetFloatingKeyboard(prefsPath: string): boolean {
  const remembered = floatingKeyboardRemembered(prefsPath);
  // One key at a time: plutil stops at a key the file does not have, and the offsets are optional.
  for (const key of FLOATING_KEYBOARD_KEYS) spawnSync(PLUTIL, ["-remove", key, prefsPath], { encoding: "utf8" });
  return remembered;
}
