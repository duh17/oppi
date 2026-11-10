#!/usr/bin/env bun

/**
 * Generates the iOS app icon from one board description.
 *
 * The icon is a frozen Game of Life board whose live cells almost form a pi:
 * mostly monochrome, a little rough, with a few rare bright cells. Every cell
 * of every layer comes from LAYOUT below and lands on one grid, so layers
 * cannot drift apart. Roughness is drawn into the board on purpose: a gap in
 * the right leg, and one cell that has fallen off the bottom.
 *
 * Writes the Icon Composer document, the source layers with a flat preview,
 * the flat fallback PNG, and the README image:
 *
 *   bun clients/apple/icon-layers/generate.ts
 *
 * Needs Xcode's Icon Composer (for `ictool`) and `rsvg-convert`.
 */

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const CANVAS = 1024;
const GRID = 8;
const CELL = 85;
const GAP = 12;
const RADIUS = 23;
const PITCH = CELL + GAP;
/** Centers the 8x8 board on the canvas. */
const ORIGIN = (CANVAS - (GRID * PITCH - GAP)) / 2;

const LAYER_NAMES = ["scatter", "growth", "pi-mono", "warm-detail", "sparks"] as const;
type LayerName = (typeof LAYER_NAMES)[number];

/** Top and bottom colors of a vertical gradient that ends 70% down the canvas. */
type Gradient = readonly [top: string, bottom: string];
const GRADIENT_END = 0.7;

interface LayerStyle {
  description: string;
  /** Color of the cells in the layer's SVG. */
  fill: string;
  opacity: number;
  /** Icon Composer fill that replaces the SVG color in the rendered icon. */
  composerFill?: Gradient | "automatic";
  blendMode?: string;
}

const LAYERS: Record<LayerName, LayerStyle> = {
  scatter: {
    description: "quiet outer cells",
    fill: "#DDE4F2",
    opacity: 0.18,
    // The top stop is a dim slate, not black: black made the cells above the
    // bar read as holes punched in the background.
    composerFill: ["display-p3:0.17000,0.19000,0.24000,0.75000", "display-p3:0.18452,0.23905,0.24593,0.56449"],
  },
  growth: {
    description: "mid-depth cells that extend the pi rhythm",
    fill: "#E7ECF7",
    opacity: 0.42,
    composerFill: "automatic",
    blendMode: "lighten",
  },
  "pi-mono": { description: "main neutral pi cells", fill: "#EEF3FF", opacity: 0.92 },
  "warm-detail": {
    description: "tinted secondary cells inside the mark",
    fill: "#E5C8BA",
    opacity: 0.9,
    composerFill: ["extended-srgb:0.00000,0.53333,1.00000,1.00000", "display-p3:0.65245,0.68064,1.00000,1.00000"],
    blendMode: "overlay",
  },
  sparks: { description: "rare vivid cells", fill: "#F5A02C", opacity: 0.96 },
};

/**
 * One letter per kind of cell; `.` is empty. A letter may put a cell on more
 * than one layer: stacked cells sit exactly on top of each other and read as
 * one brighter cell.
 */
const CELL_KINDS: Record<string, { layers: readonly LayerName[]; fill?: string }> = {
  s: { layers: ["scatter"] },
  g: { layers: ["growth"] },
  G: { layers: ["scatter", "growth"] },
  p: { layers: ["pi-mono"] },
  P: { layers: ["growth", "pi-mono"] },
  w: { layers: ["warm-detail"] },
  W: { layers: ["growth", "warm-detail"] },
  "1": { layers: ["sparks"], fill: "#F5A02C" },
  "2": { layers: ["sparks"], fill: "#F05A2D" },
};

/**
 * The seed-42 roll, frozen. The pi occupies columns 1-6 and rows 1-6: a bar,
 * two legs, and a foot that kicks right. Columns 3-4 below the bar are the
 * gap between the legs and must stay empty. The right leg misses a cell.
 *
 * The last row is below the board: the cell there has fallen out of the
 * bottom edge, and it is the only one allowed to.
 */
const LAYOUT = [
  ". s s . . . . .",
  ". 1 2 w p p W .",
  "g . p . . p . .",
  "g . p . . . . .",
  "s . w . . P . .",
  ". . p . . w . .",
  ". . p . . p p .",
  ". s . . . . . G",
  ". . . . . g . .",
];

const MAX_SPARKS = 3;
const MAX_FALLEN_CELLS = 1;

interface Cell {
  column: number;
  row: number;
  layer: LayerName;
  fill: string;
}

function parseLayout(layout: readonly string[]): Cell[] {
  if (layout.length !== GRID + 1) throw new Error(`layout needs ${GRID} board rows and one row below the board`);
  const cells: Cell[] = [];
  let sparks = 0;
  let fallen = 0;
  layout.forEach((line, row) => {
    const letters = line.trim().split(/\s+/);
    if (letters.length !== GRID) throw new Error(`row ${row} needs ${GRID} cells`);
    letters.forEach((letter, column) => {
      if (letter === ".") return;
      const kind = CELL_KINDS[letter];
      if (!kind) throw new Error(`row ${row}, column ${column}: unknown cell "${letter}"`);
      if ((column === 3 || column === 4) && row >= 2 && row <= 6) {
        throw new Error(`row ${row}, column ${column}: the gap between the legs must stay empty`);
      }
      if (row === GRID) fallen += 1;
      if (kind.layers.includes("sparks")) sparks += 1;
      for (const layer of kind.layers) cells.push({ column, row, layer, fill: kind.fill ?? LAYERS[layer].fill });
    });
  });
  if (sparks < 1 || sparks > MAX_SPARKS) throw new Error(`expected 1-${MAX_SPARKS} sparks, found ${sparks}`);
  if (fallen > MAX_FALLEN_CELLS) throw new Error(`at most ${MAX_FALLEN_CELLS} cell may fall off the board`);
  return cells;
}

function rect(cell: Cell, fill = cell.fill): string {
  const x = ORIGIN + cell.column * PITCH;
  const y = ORIGIN + cell.row * PITCH;
  return `<rect x="${x}" y="${y}" width="${CELL}" height="${CELL}" rx="${RADIUS}" fill="${fill}"/>`;
}

const SVG_OPEN = `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${CANVAS} ${CANVAS}" width="${CANVAS}" height="${CANVAS}">`;

function layerFile(name: LayerName): string {
  return `${LAYER_NAMES.indexOf(name) + 1}-${name}.svg`;
}

function layerSvg(name: LayerName, cells: Cell[]): string {
  return [
    SVG_OPEN,
    `  <title>Oppi icon ${name}</title>`,
    `  <desc>${LAYERS[name].description}</desc>`,
    `  <g opacity="${LAYERS[name].opacity}">`,
    ...cells.filter((cell) => cell.layer === name).map((cell) => `    ${rect(cell)}`),
    "  </g>",
    "</svg>",
    "",
  ].join("\n");
}

/** Reads `space:r,g,b,a` or `space:gray,a`; the color space is ignored. */
function svgStop(offset: number, composerColor: string): string {
  const numbers = composerColor.slice(composerColor.indexOf(":") + 1).split(",").map(Number);
  const [r, g, b, a] = numbers.length === 2 ? [numbers[0], numbers[0], numbers[0], numbers[1]] : numbers;
  const channel = (value: number) => Math.round(Math.min(1, Math.max(0, value)) * 255);
  return `<stop offset="${offset}" stop-color="rgb(${channel(r)},${channel(g)},${channel(b)})" stop-opacity="${a}"/>`;
}

/**
 * A flat stand-in for the rendered icon: the layers on the background, with
 * each Icon Composer gradient fill drawn as a plain SVG gradient. No glass,
 * no blend modes.
 */
function previewSvg(cells: Cell[]): string {
  const gradients: string[] = [];
  const groups: string[] = [];
  for (const name of LAYER_NAMES) {
    const style = LAYERS[name];
    const gradient = Array.isArray(style.composerFill) ? (style.composerFill as Gradient) : undefined;
    if (gradient) {
      gradients.push(
        `    <linearGradient id="${name}" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="${CANVAS * GRADIENT_END}">`,
        `      ${svgStop(0, gradient[0])}`,
        `      ${svgStop(1, gradient[1])}`,
        "    </linearGradient>",
      );
    }
    groups.push(
      `  <g id="${name}" opacity="${gradient ? 1 : style.opacity}">`,
      ...cells
        .filter((cell) => cell.layer === name)
        .map((cell) => `    ${rect(cell, gradient ? `url(#${name})` : cell.fill)}`),
      "  </g>",
    );
  }
  return [
    SVG_OPEN,
    "  <title>Oppi icon preview</title>",
    "  <desc>All Icon Composer layers flattened onto the background, without Liquid Glass.</desc>",
    "  <defs>",
    '    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">',
    '      <stop offset="0" stop-color="#1B1B25"/>',
    '      <stop offset="1" stop-color="#0C0C12"/>',
    "    </linearGradient>",
    ...gradients,
    "  </defs>",
    `  <rect width="${CANVAS}" height="${CANVAS}" fill="url(#bg)"/>`,
    ...groups,
    "</svg>",
    "",
  ].join("\n");
}

function composerFill(fill: Gradient | "automatic") {
  if (fill === "automatic") return "automatic";
  return {
    "linear-gradient": [...fill],
    orientation: { start: { x: 0.5, y: 0 }, stop: { x: 0.5, y: GRADIENT_END } },
  };
}

function layerEntry(name: LayerName) {
  const style = LAYERS[name];
  return {
    ...(style.blendMode ? { "blend-mode": style.blendMode } : {}),
    ...(style.composerFill ? { fill: composerFill(style.composerFill) } : {}),
    glass: true,
    hidden: false,
    "image-name": layerFile(name),
    name,
    // Every layer is registered to the canvas; cell positions live in LAYOUT.
    position: { scale: 1, "translation-in-points": [0, 0] },
  };
}

function iconDocument() {
  return {
    fill: { "automatic-gradient": "srgb:0.06667,0.06667,0.09412,1.00000" },
    groups: [
      {
        layers: [layerEntry("scatter"), layerEntry("growth")],
        shadow: { kind: "neutral", opacity: 0.28 },
        translucency: { enabled: true, value: 0.48 },
      },
      {
        layers: [layerEntry("pi-mono")],
        shadow: { kind: "neutral", opacity: 0.46 },
        translucency: { enabled: true, value: 0.32 },
      },
      {
        layers: [layerEntry("warm-detail"), layerEntry("sparks")],
        shadow: { kind: "neutral", opacity: 0.36 },
        translucency: { enabled: false, value: 0 },
      },
    ],
    "supported-platforms": { circles: ["watchOS"], squares: "shared" },
  };
}

function meta(cells: Cell[]) {
  return {
    generator: "clients/apple/icon-layers/generate.ts",
    seed: 42,
    canvas: CANVAS,
    grid: { columns: GRID, rows: GRID, cell: CELL, gap: GAP, radius: RADIUS, origin: ORIGIN },
    layout: LAYOUT,
    layers: LAYER_NAMES.map((name) => ({
      file: layerFile(name),
      name,
      description: LAYERS[name].description,
      opacity: LAYERS[name].opacity,
      cells: cells.filter((cell) => cell.layer === name).map((cell) => `${cell.column},${cell.row}`),
    })),
  };
}

function json(value: unknown): string {
  return `${JSON.stringify(value, null, 2)}\n`;
}

function run(command: string, args: string[]): void {
  const result = spawnSync(command, args, { encoding: "utf8" });
  if (result.error || result.status !== 0) {
    throw new Error(`${command} failed: ${result.error?.message ?? result.stderr}`);
  }
}

function ictoolPath(): string {
  const developerDir = spawnSync("xcode-select", ["-p"], { encoding: "utf8" }).stdout.trim();
  const path = resolve(developerDir, "../Applications/Icon Composer.app/Contents/Executables/ictool");
  if (!existsSync(path)) throw new Error(`Icon Composer's ictool not found at ${path}`);
  return path;
}

/** Empties a generated directory so a renamed layer leaves nothing behind. */
function resetDirectory(path: string): void {
  mkdirSync(path, { recursive: true });
  for (const entry of readdirSync(path)) rmSync(join(path, entry), { recursive: true });
}

function main(): void {
  const repo = resolve(import.meta.dir, "../../..");
  const apple = join(repo, "clients/apple");
  const iconDocumentDir = join(apple, "Oppi/Resources/AppIcon.icon");
  const assetsDir = join(iconDocumentDir, "Assets");
  const sourceDir = join(apple, "icon-layers");
  const flatPng = join(apple, "Oppi/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png");
  const readmePng = join(repo, "docs/images/app-icon.png");

  const cells = parseLayout(LAYOUT);

  resetDirectory(assetsDir);
  for (const name of LAYER_NAMES) {
    const svg = layerSvg(name, cells);
    writeFileSync(join(assetsDir, layerFile(name)), svg);
    writeFileSync(join(sourceDir, layerFile(name)), svg);
  }
  writeFileSync(join(iconDocumentDir, "icon.json"), json(iconDocument()));
  writeFileSync(join(sourceDir, "meta.json"), json(meta(cells)));
  const previewPath = join(sourceDir, "preview-combined.svg");
  writeFileSync(previewPath, previewSvg(cells));

  // Flat fallback for systems that do not read the Icon Composer document.
  run("rsvg-convert", ["--width", String(CANVAS), "--height", String(CANVAS), "--output", flatPng, previewPath]);
  // The README shows the icon as the system draws it, at 128 pt.
  run(ictoolPath(), [
    iconDocumentDir,
    "--export-image",
    "--output-file",
    readmePng,
    "--platform",
    "iOS",
    "--rendition",
    "Default",
    "--width",
    "512",
    "--height",
    "512",
    "--scale",
    "1",
  ]);
  console.log(`Generated ${cells.length} cells on a ${GRID}x${GRID} grid.`);
}

main();
