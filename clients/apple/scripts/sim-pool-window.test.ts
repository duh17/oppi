import { afterEach, describe, expect, setDefaultTimeout, test } from "bun:test";
import { Database } from "bun:sqlite";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { APP_BUNDLE_ID, loadConfig, prepareSimulator } from "./sim-pool-ops";
import { CommandSession } from "./sim-pool-supervise";
import { SUBPROCESS_TEST_TIMEOUT_MS } from "./sim-pool-test-support";
import {
  floatingKeyboardRemembered,
  forgetFloatingKeyboard,
  forgetPersistedWindow,
  frontBoardStorePath,
  isCompactWindow,
  isPadDeviceType,
  keyboardPreferencesPath,
  readPersistedWindow,
} from "./sim-pool-window";

setDefaultTimeout(SUBPROCESS_TEST_TIMEOUT_MS);

const scriptDir = import.meta.dir;
const temps: string[] = [];
afterEach(() => {
  for (const dir of temps.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const IPAD = "com.apple.CoreSimulator.SimDeviceType.iPad-mini-A17-Pro";
const IPHONE = "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro";
const UDID = "PAD-SLOT";

/** What SpringBoard stores for a window: the remembered size and the display it was sized against. */
function windowBlob(size: { Width: number; Height: number }): Uint8Array {
  const json = JSON.stringify({
    first: { size, referenceBounds: { X: 0, Y: 0, Width: 744, Height: 1133 }, positionIsSystemManaged: size.Width === 744 },
  });
  const result = Bun.spawnSync(["/usr/bin/plutil", "-convert", "binary1", "-o", "-", "-"], { stdin: Buffer.from(json) });
  if (result.exitCode !== 0) throw new Error(result.stderr.toString());
  return new Uint8Array(result.stdout);
}

/** A FrontBoard store like the device's: the app's remembered window next to another app's unrelated row. */
function makeStore(home: string, size: { Width: number; Height: number } | null): string {
  const path = frontBoardStorePath(home, UDID);
  mkdirSync(dirname(path), { recursive: true });
  const db = new Database(path);
  db.run("PRAGMA journal_mode = WAL");
  db.run("CREATE TABLE key_tab (id INTEGER PRIMARY KEY, key TEXT NOT NULL, UNIQUE(key))");
  db.run("CREATE TABLE application_identifier_tab (id INTEGER PRIMARY KEY, application_identifier TEXT NOT NULL, UNIQUE(application_identifier))");
  db.run(
    "CREATE TABLE kvs (id INTEGER PRIMARY KEY, application_identifier INT REFERENCES application_identifier_tab(id), key INT REFERENCES key_tab(id), value BLOB, UNIQUE(application_identifier, key))",
  );
  db.run("INSERT INTO key_tab VALUES (1, 'SBApplicationLastWindowSizePerDisplayOrdinalKey'), (2, '_SBScenes')");
  db.run(`INSERT INTO application_identifier_tab VALUES (1, '${APP_BUNDLE_ID}'), (2, 'com.apple.mobilesafari')`);
  if (size) db.query("INSERT INTO kvs (application_identifier, key, value) VALUES (1, 1, ?)").run(windowBlob(size));
  db.query("INSERT INTO kvs (application_identifier, key, value) VALUES (1, 2, ?)").run(new Uint8Array([1]));
  db.query("INSERT INTO kvs (application_identifier, key, value) VALUES (2, 1, ?)").run(windowBlob({ Width: 300, Height: 300 }));
  db.close();
  return path;
}

function tempHome(): string {
  const home = mkdtempSync(join(tmpdir(), "oppi-sim-window-"));
  temps.push(home);
  return home;
}

/** The keyboard's preference domain as the device writes it: binary plist, no floating keys when docked. */
function makeKeyboardPrefs(home: string, floating: boolean): string {
  const path = keyboardPreferencesPath(home, UDID);
  mkdirSync(dirname(path), { recursive: true });
  const prefs = {
    AutomaticMinimizationEnabled: true,
    ...(floating
      ? {
          KeyboardFloatingPersistentHorizontalOffset: 0.27,
          KeyboardFloatingPersistentVerticalOffset: 0.28,
          KeyboardIsFloating: true,
        }
      : {}),
    KeyboardsCurrentAndNext: ["en_US@sw=QWERTY;hw=Automatic"],
  };
  const result = Bun.spawnSync(["/usr/bin/plutil", "-convert", "binary1", "-o", "-", "-"], { stdin: Buffer.from(JSON.stringify(prefs)) });
  if (result.exitCode !== 0) throw new Error(result.stderr.toString());
  writeFileSync(path, result.stdout);
  return path;
}

describe("remembered window", () => {
  test("a window smaller than its display is compact; one that fills it is not", () => {
    const display = { displayWidth: 744, displayHeight: 1133 };
    expect(isCompactWindow({ width: 570, height: 486, ...display })).toBe(true);
    expect(isCompactWindow({ width: 744, height: 600, ...display })).toBe(true);
    expect(isCompactWindow({ width: 744, height: 1133, ...display })).toBe(false);
  });

  test("only iPad device types float their windows", () => {
    expect(isPadDeviceType(IPAD)).toBe(true);
    expect(isPadDeviceType("com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB")).toBe(true);
    expect(isPadDeviceType(IPHONE)).toBe(false);
    expect(isPadDeviceType("com.apple.CoreSimulator.SimDeviceType.iPhone-Duo")).toBe(false);
  });

  test("reads the app's window and forgets only that row", () => {
    const home = tempHome();
    const store = makeStore(home, { Width: 570, Height: 486 });

    expect(readPersistedWindow(store, APP_BUNDLE_ID)).toEqual({ width: 570, height: 486, displayWidth: 744, displayHeight: 1133 });
    expect(forgetPersistedWindow(store, APP_BUNDLE_ID)).toBe(true);
    expect(readPersistedWindow(store, APP_BUNDLE_ID)).toBeNull();
    // The app's scene row and another app's window stay.
    expect(readPersistedWindow(store, "com.apple.mobilesafari")).not.toBeNull();
    const db = new Database(store, { readonly: true });
    expect(db.query("SELECT count(*) AS n FROM kvs").get()).toEqual({ n: 2 });
    db.close();
    expect(forgetPersistedWindow(store, APP_BUNDLE_ID)).toBe(false);
  });

  test("a slot that never ran the app remembers no window", () => {
    const home = tempHome();
    expect(readPersistedWindow(frontBoardStorePath(home, "NEW-SLOT"), APP_BUNDLE_ID)).toBeNull();
    expect(readPersistedWindow(makeStore(home, null), APP_BUNDLE_ID)).toBeNull();
  });
});

describe("remembered floating keyboard", () => {
  test("forgets the floating flag and its offsets, and keeps the rest of the domain", () => {
    const prefs = makeKeyboardPrefs(tempHome(), true);

    expect(floatingKeyboardRemembered(prefs)).toBe(true);
    expect(forgetFloatingKeyboard(prefs)).toBe(true);
    expect(floatingKeyboardRemembered(prefs)).toBe(false);
    const kept = spawnSync("/usr/bin/plutil", ["-convert", "json", "-o", "-", prefs], { encoding: "utf8" });
    expect(JSON.parse(kept.stdout)).toEqual({
      AutomaticMinimizationEnabled: true,
      KeyboardsCurrentAndNext: ["en_US@sw=QWERTY;hw=Automatic"],
    });
    expect(forgetFloatingKeyboard(prefs)).toBe(false);
  });

  test("a slot with no keyboard file, or a docked keyboard, remembers none", () => {
    const home = tempHome();
    expect(floatingKeyboardRemembered(keyboardPreferencesPath(home, "NEW-SLOT"))).toBe(false);
    expect(floatingKeyboardRemembered(makeKeyboardPrefs(home, false))).toBe(false);
  });
});

/** `prepareSimulator` on a booted slot, against a fake simctl that logs what it was asked. */
async function prepareBootedSlot(deviceType: string, size: { Width: number; Height: number }, floatingKeyboard = false) {
  const root = tempHome();
  const home = join(root, "home");
  const store = makeStore(home, size);
  const keyboard = makeKeyboardPrefs(home, floatingKeyboard);
  const bin = join(root, "bin");
  mkdirSync(bin);
  writeFileSync(
    join(root, "devices.json"),
    JSON.stringify({
      devices: { runtime: [{ udid: UDID, name: "Oppi-Pool-6", state: "Booted", isAvailable: true, deviceTypeIdentifier: deviceType }] },
    }),
  );
  writeFileSync(
    join(bin, "xcrun"),
    `#!/bin/bash
set -euo pipefail
echo "$1 $2" >> "$OPPI_FAKE_ROOT/calls.log"
case "$1 $2" in
'simctl list') /bin/cat "$OPPI_FAKE_ROOT/devices.json" ;;
'simctl spawn' | 'simctl bootstatus' | 'simctl shutdown' | 'simctl boot') exit 0 ;;
*) echo "unexpected fake call: $*" >&2; exit 99 ;;
esac
`,
    { mode: 0o755 },
  );
  const keys = ["PATH", "OPPI_FAKE_ROOT"] as const;
  const prior = Object.fromEntries(keys.map((key) => [key, process.env[key]]));
  process.env.PATH = `${bin}:/usr/bin:/bin`;
  process.env.OPPI_FAKE_ROOT = root;
  const session = new CommandSession();
  try {
    const config = loadConfig(
      {
        ...process.env,
        HOME: home,
        OPPI_ROOT: root,
        OPPI_SIM_DEVICE_TYPE: deviceType,
        OPPI_SIM_POOL_LOCK_DIR: join(root, "locks"),
        OPPI_SIM_SLIM: "0",
      },
      root,
      scriptDir,
    );
    await prepareSimulator(session, config, UDID, "normal");
  } finally {
    await session.dispose();
    for (const key of keys) {
      if (prior[key] === undefined) delete process.env[key];
      else process.env[key] = prior[key];
    }
  }
  const calls = existsSync(join(root, "calls.log")) ? readFileSync(join(root, "calls.log"), "utf8").split("\n") : [];
  return { calls, remembered: readPersistedWindow(store, APP_BUNDLE_ID), keyboardFloating: floatingKeyboardRemembered(keyboard) };
}

describe("prepareSimulator and the remembered window", () => {
  test("an iPad slot that remembers a floating window is recycled and boots without it", async () => {
    const { calls, remembered } = await prepareBootedSlot(IPAD, { Width: 570, Height: 486 });

    expect(calls).toContain("simctl shutdown");
    expect(calls).toContain("simctl boot");
    expect(calls.indexOf("simctl shutdown")).toBeLessThan(calls.indexOf("simctl boot"));
    expect(remembered).toBeNull();
  });

  test("an iPad slot whose window fills the display is reused as it is", async () => {
    const { calls, remembered } = await prepareBootedSlot(IPAD, { Width: 744, Height: 1133 });

    expect(calls).not.toContain("simctl shutdown");
    expect(calls).not.toContain("simctl boot");
    expect(remembered).not.toBeNull();
  });

  test("an iPhone slot is left alone", async () => {
    const { calls, remembered } = await prepareBootedSlot(IPHONE, { Width: 570, Height: 486 });

    expect(calls).not.toContain("simctl shutdown");
    expect(remembered).not.toBeNull();
  });

  test("an iPad slot whose keyboard is floating is recycled and boots with it docked", async () => {
    const { calls, remembered, keyboardFloating } = await prepareBootedSlot(IPAD, { Width: 744, Height: 1133 }, true);

    expect(calls).toContain("simctl shutdown");
    expect(calls.indexOf("simctl shutdown")).toBeLessThan(calls.indexOf("simctl boot"));
    expect(keyboardFloating).toBe(false);
    // The boot forgets the app's remembered window too, whatever size it was.
    expect(remembered).toBeNull();
  });

  test("an iPhone slot keeps its keyboard preferences", async () => {
    const { calls, keyboardFloating } = await prepareBootedSlot(IPHONE, { Width: 744, Height: 1133 }, true);

    expect(calls).not.toContain("simctl shutdown");
    expect(keyboardFloating).toBe(true);
  });
});
