#!/usr/bin/env bun
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Every `SCREENSHOT_SCREEN` a UI or E2E test launches must resolve to a case of
 * the DEBUG preview switch (`ScreenshotPreviewView`) or the screens `OppiApp`
 * routes before it. A deleted or renamed preview otherwise fails only when
 * that test runs on a simulator: the app shows "Unknown screen" and the test
 * times out. Plain source scan, no simulator.
 *
 *   bun scripts/screenshot-screen-guard.ts
 */

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const apple = join(repoRoot, "clients/apple");
const previewSwitch = join(apple, "Oppi/App/ScreenshotPreviewView.swift");
const app = join(apple, "Oppi/App/OppiApp.swift");
const testRoots = ["OppiUITests", "OppiE2ETests"].map((dir) => join(apple, dir));

function swiftFiles(root: string): string[] {
  if (!existsSync(root)) return [];
  return readdirSync(root, { withFileTypes: true }).flatMap((entry) => {
    const path = join(root, entry.name);
    if (entry.isDirectory()) return swiftFiles(path);
    return entry.name.endsWith(".swift") ? [path] : [];
  });
}

/** The labels of the `switch ScreenshotPreviewConfig.screen` cases. */
function previewScreens(): Set<string> {
  const source = readFileSync(previewSwitch, "utf8");
  const start = source.indexOf("switch ScreenshotPreviewConfig.screen");
  const end = source.indexOf("default:", start);
  if (start < 0 || end < 0) {
    console.error(`Screenshot screen guard: no screen switch found in ${relative(repoRoot, previewSwitch)}.`);
    process.exit(1);
  }
  const screens = new Set<string>();
  for (const line of source.slice(start, end).split("\n")) {
    const label = line.match(/^\s*case\s+(.*):\s*$/);
    if (!label) continue;
    for (const name of label[1].matchAll(/"([^"]+)"/g)) screens.add(name[1]);
  }
  // OppiApp picks this one before ScreenshotPreviewView.
  for (const match of readFileSync(app, "utf8").matchAll(/ScreenshotPreviewConfig\.screen == "([^"]+)"/g)) {
    screens.add(match[1]);
  }
  return screens;
}

/**
 * The screens a test launches: `SCREENSHOT_SCREEN` assigned a literal, or a
 * literal handed to the launch helpers (`launch(screen:)`, `launchPreview`,
 * `launchScreen`). A test that passes a variable is not seen.
 */
function launchedScreens(): { screen: string; file: string }[] {
  const patterns = [
    /launchEnvironment\["SCREENSHOT_SCREEN"\]\s*=\s*"([^"]+)"/g,
    /\blaunch(?:Preview|Screen)?\(\s*(?:screen:\s*)?"([a-z0-9-]+)"/g,
  ];
  const launched: { screen: string; file: string }[] = [];
  for (const file of testRoots.flatMap(swiftFiles)) {
    const source = readFileSync(file, "utf8");
    for (const pattern of patterns) {
      for (const match of source.matchAll(pattern)) {
        launched.push({ screen: match[1], file: relative(repoRoot, file) });
      }
    }
  }
  return launched;
}

const screens = previewScreens();
const launched = launchedScreens();
const missing = launched.filter(({ screen }) => !screens.has(screen));

if (launched.length === 0) {
  console.error("Screenshot screen guard: found no launched screens; the scan patterns no longer match the tests.");
  process.exit(1);
}

if (missing.length === 0) {
  console.log(`Screenshot screen guard: PASS — ${new Set(launched.map((l) => l.screen)).size} launched screens resolve to a preview.`);
  process.exit(0);
}

console.log("Screenshot screen guard: FAIL — tests launch screens no preview case serves.\n");
for (const { screen, file } of missing) console.log(`- ${file}: SCREENSHOT_SCREEN=${screen}`);
console.log(`
A test that launches an unknown screen sees "Unknown screen" and times out.
Restore the case in ScreenshotPreviewView, or update the test with it.`);
process.exit(1);
