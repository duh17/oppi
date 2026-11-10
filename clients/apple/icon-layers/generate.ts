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
 * Each cell is a keycap, and no two are alike: SEED gives every cell its own
 * bevel, highlight, tint and engraving. RICHNESS says how much of that shows.
 *
 * Writes the Icon Composer document, the source layers with a flat preview,
 * the flat fallback PNG, and the README image:
 *
 *   bun clients/apple/icon-layers/generate.ts
 *
 * To try another richness without touching the repo, give it and a scratch
 * directory; only the Icon Composer document is written there:
 *
 *   bun clients/apple/icon-layers/generate.ts 3 /tmp/richest.icon
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

const SEED = 42;
/** How much per-cell character shows: 1 rich, 2 richer, 3 richest. */
const RICHNESS = 2;
type Richness = 1 | 2 | 3;

interface Cell {
  column: number;
  row: number;
  layer: LayerName;
  fill: string;
  /** The frontmost layer of the board cell this one is stacked in. */
  top: LayerName;
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
      const top = kind.layers[kind.layers.length - 1];
      for (const layer of kind.layers) cells.push({ column, row, layer, fill: kind.fill ?? LAYERS[layer].fill, top });
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

// --- Cell detail -----------------------------------------------------------
//
// The detail is drawn over the cells as marks: translucent light and dark
// shapes in cell coordinates (0 to CELL). They never change which cells exist
// or what color a cell is.

const LIGHT = "#FFFFFF";
const DARK = "#0B0C12";
/** Faint washes that lean a neutral cell cool or warm. */
const COOL = "#7FB2FF";
const WARM = "#FFC68F";
/** Marks fade with the cell they sit on, so quiet cells stay quiet. */
const MARK_STRENGTH: Record<LayerName, number> = {
  scatter: 0.3,
  growth: 0.5,
  "pi-mono": 1,
  "warm-detail": 1,
  sparks: 1,
};

/** Directions the top-face highlight can fall from, as gradient vectors. */
const SHEENS = [
  [0.5, 0, 0.5, 1],
  [0, 0, 0.6, 1],
  [1, 0, 0.4, 1],
  [0.2, 0, 0.8, 1],
  [0.8, 0, 0.2, 1],
] as const;

/** Gradients the marks use; each runs over the shape that references it. */
const MARK_DEFS = [
  '<radialGradient id="glow" cx="0.5" cy="0.5" r="0.5">',
  `  <stop offset="0" stop-color="${LIGHT}" stop-opacity="0.85"/>`,
  `  <stop offset="1" stop-color="${LIGHT}" stop-opacity="0"/>`,
  "</radialGradient>",
  ...SHEENS.flatMap(([x1, y1, x2, y2], index) => [
    `<linearGradient id="sheen-${index}" x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}">`,
    `  <stop offset="0" stop-color="${LIGHT}" stop-opacity="0.5"/>`,
    `  <stop offset="0.75" stop-color="${LIGHT}" stop-opacity="0"/>`,
    "</linearGradient>",
  ]),
];

/**
 * Engravings on a 3x3 patch of micro-pixels: Game of Life still lifes,
 * oscillators and a glider, plus a few fragments.
 */
const ENGRAVINGS: readonly (readonly (readonly [number, number])[])[] = [
  [[1, 0], [2, 1], [0, 2], [1, 2], [2, 2]], // glider
  [[0, 1], [1, 1], [2, 1]], // blinker
  [[0, 0], [1, 0], [0, 1], [1, 1]], // block
  [[1, 0], [0, 1], [2, 1], [1, 2]], // tub
  [[0, 0], [1, 0], [0, 1], [2, 1], [1, 2]], // boat
  [[0, 0], [1, 0], [0, 1]], // corner
  [[0, 0], [1, 1]], // pair
  [[1, 1]], // lone cell
];
/** Micro-pixels sit on a 5x5 grid centered on the top face. */
const MICRO = 9;
const MICRO_PITCH = 11;
const MICRO_GRID = 5;

/** A small seeded generator (mulberry32), one independent stream per cell. */
function cellRandom(cell: Cell): () => number {
  let state = (SEED * 73856093) ^ (cell.column * 19349663) ^ (cell.row * 83492791);
  return () => {
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function n(value: number): number {
  return Math.round(value * 10) / 10;
}

function roundedPath(x: number, y: number, size: number, radius: number): string {
  const side = n(size - 2 * radius);
  const r = n(radius);
  return `M${n(x + radius)} ${n(y)}h${side}a${r} ${r} 0 0 1 ${r} ${r}v${side}a${r} ${r} 0 0 1 -${r} ${r}h-${side}a${r} ${r} 0 0 1 -${r} -${r}v-${side}a${r} ${r} 0 0 1 ${r} -${r}z`;
}

function shape(tag: string, attributes: Record<string, string | number>): string {
  const text = Object.entries(attributes)
    .map(([name, value]) => `${name}="${typeof value === "number" ? n(value) : value}"`)
    .join(" ");
  return `<${tag} ${text}/>`;
}

/**
 * The marks for one cell. Every roll is made in the same order at every
 * richness, so a cell keeps its character and only its intensity changes.
 */
function cellMarks(cell: Cell, richness: Richness): string[] {
  const next = cellRandom(cell);
  const between = (low: number, high: number) => low + (high - low) * next();
  const pick = (count: number) => Math.floor(next() * count);
  const level = richness - 1;
  const spark = cell.top === "sparks";
  const neutral = cell.top !== "sparks" && cell.top !== "warm-detail";
  const marks: string[] = [];

  // The keycap: a top face inside a shaded lip. Bevel depth, the lift that
  // thickens the bottom lip, and a slight sideways lean differ per cell.
  const spread = [0.5, 0.8, 1][level];
  const bevel = 8.5 + between(-2, 2) * spread;
  const lift = 3 + between(-1.5, 1.5) * spread;
  const lean = between(-1.5, 1.5) * spread;
  const lipOpacity = 0.2 + between(-0.06, 0.06) * spread;
  const face = { x: bevel + lean, y: bevel - lift + 1, size: CELL - 2 * bevel, radius: RADIUS - bevel + 1 };
  const onFace = { x: face.x, y: face.y, width: face.size, height: face.size, rx: face.radius };

  // Rolled before anything is drawn, so the draws below never shift a roll.
  const glow = { x: between(-5, 5), y: between(-5, 5) };
  const apex = { x: between(0.35, 0.65), y: between(0.35, 0.65) };
  const sheen = pick(SHEENS.length);
  const glint = { x: between(0.22, 0.78), y: between(0.14, 0.4), rx: between(9, 15), ry: between(5, 8) };
  const shade = between(-1, 1);
  const wash = { color: next() < 0.5 ? COOL : WARM, amount: next() };
  const engraving = { roll: next(), kind: pick(ENGRAVINGS.length), turns: pick(4), column: pick(3), row: pick(3) };
  const ghosts = [0, 1].map(() => ({ column: pick(MICRO_GRID), row: pick(MICRO_GRID) }));
  const ring = { roll: next(), inset: between(4, 9) };
  const scan = { roll: next(), top: next() < 0.5, lines: 2 + pick(3) };
  const wear = [0, 1, 2].map(() => ({
    x: between(0.15, 0.85),
    y: between(0.15, 0.85),
    length: between(0, 12),
    angle: between(-70, 70),
  }));

  if (spark) {
    marks.push(shape("rect", { x: 4 + glow.x, y: 1 + glow.y, width: 77, height: 77, rx: 19, fill: "url(#glow)" }));
  }
  marks.push(
    shape("path", {
      "fill-rule": "evenodd",
      fill: DARK,
      "fill-opacity": lipOpacity,
      d: roundedPath(2, 2, CELL - 4, RADIUS - 2) + roundedPath(face.x, face.y, face.size, face.radius),
    }),
  );

  // A per-cell brightness shift, and on neutral cells a faint cool or warm wash.
  const shadeOpacity = Math.abs(shade) * [0.05, 0.08, 0.11][level];
  marks.push(shape("rect", { ...onFace, fill: shade < 0 ? DARK : LIGHT, "fill-opacity": shadeOpacity }));
  if (neutral) {
    marks.push(shape("rect", { ...onFace, fill: wash.color, "fill-opacity": wash.amount * [0.05, 0.08, 0.11][level] }));
  }

  marks.push(shape("rect", { ...onFace, fill: `url(#sheen-${sheen})`, opacity: 0.5 }));

  if (spark) {
    // Sparks are cut like gems: four facets meet at an off-center apex.
    const inset = 6;
    const left = face.x + inset;
    const top = face.y + inset;
    const right = face.x + face.size - inset;
    const bottom = face.y + face.size - inset;
    const ax = n(left + (right - left) * apex.x);
    const ay = n(top + (bottom - top) * apex.y);
    const facet = (x1: number, y1: number, x2: number, y2: number, fill: string, opacity: number) =>
      shape("path", {
        d: `M${n(x1)} ${n(y1)}L${n(x2)} ${n(y2)}L${ax} ${ay}z`,
        fill,
        "fill-opacity": opacity * [0.7, 1, 1.3][level],
      });
    marks.push(
      facet(left, top, right, top, LIGHT, 0.26),
      facet(left, top, left, bottom, LIGHT, 0.08),
      facet(right, top, right, bottom, DARK, 0.03),
      facet(left, bottom, right, bottom, DARK, 0.16),
    );
  } else {
    const center = { x: face.x + face.size / 2, y: face.y + face.size / 2 };
    const micro = (column: number, row: number, fill: string, opacity: number) =>
      shape("rect", {
        x: center.x + (column - MICRO_GRID / 2) * MICRO_PITCH + (MICRO_PITCH - MICRO) / 2,
        y: center.y + (row - MICRO_GRID / 2) * MICRO_PITCH + (MICRO_PITCH - MICRO) / 2,
        width: MICRO,
        height: MICRO,
        rx: 2,
        fill,
        "fill-opacity": opacity,
      });

    // An engraved Game of Life pattern, turned and placed differently per cell.
    if (engraving.roll < [0.55, 0.85, 1][level]) {
      for (let [column, row] of ENGRAVINGS[engraving.kind]) {
        for (let turn = 0; turn < engraving.turns; turn += 1) [column, row] = [2 - row, column];
        marks.push(micro(column + engraving.column, row + engraving.row, DARK, [0.11, 0.16, 0.21][level]));
      }
    }
    // Cells of an earlier generation, still faintly lit.
    for (const ghost of ghosts.slice(0, level)) marks.push(micro(ghost.column, ghost.row, LIGHT, 0.3));

    if (ring.roll < [0, 0.35, 0.6][level]) {
      marks.push(
        shape("rect", {
          x: face.x + ring.inset,
          y: face.y + ring.inset,
          width: face.size - 2 * ring.inset,
          height: face.size - 2 * ring.inset,
          rx: Math.max(3, face.radius - ring.inset),
          fill: "none",
          stroke: DARK,
          "stroke-opacity": 0.13,
          "stroke-width": 2,
        }),
      );
    }
    if (scan.roll < [0, 0.3, 0.55][level]) {
      const start = scan.top ? face.y + 9 : face.y + face.size - 9 - (scan.lines - 1) * 5 - 2;
      for (let line = 0; line < scan.lines; line += 1) {
        marks.push(
          shape("rect", { x: face.x + 9, y: start + line * 5, width: face.size - 18, height: 2, fill: DARK, "fill-opacity": 0.12 }),
        );
      }
    }
  }

  // Wear: specks and short scratches that catch the light.
  for (const mark of wear.slice(0, [0, 1, 3][level])) {
    const x = face.x + face.size * mark.x;
    const y = face.y + face.size * mark.y;
    const radians = (mark.angle * Math.PI) / 180;
    marks.push(
      shape("path", {
        d: `M${n(x)} ${n(y)}l${n(Math.cos(radians) * mark.length)} ${n(Math.sin(radians) * mark.length)}`,
        stroke: LIGHT,
        "stroke-opacity": 0.28,
        "stroke-width": 1.5,
        "stroke-linecap": "round",
        fill: "none",
      }),
    );
  }

  // A small bright glint where the light catches the face.
  marks.push(
    shape("ellipse", {
      cx: face.x + face.size * glint.x,
      cy: face.y + face.size * glint.y,
      rx: glint.rx,
      ry: glint.ry,
      fill: "url(#glow)",
      opacity: [0.3, 0.45, 0.6][level],
    }),
  );
  return marks;
}

/** One group of marks per board cell, moved to the cell and faded to its strength. */
function markGroups(cells: Cell[], richness: Richness): string[] {
  return cells
    .filter((cell) => cell.layer === cell.top)
    .map((cell) => {
      const x = ORIGIN + cell.column * PITCH;
      const y = ORIGIN + cell.row * PITCH;
      const marks = cellMarks(cell, richness).join("");
      return `<g transform="translate(${x} ${y})" opacity="${MARK_STRENGTH[cell.top]}">${marks}</g>`;
    });
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

const DETAIL_FILE = `${LAYER_NAMES.length + 1}-detail.svg`;

/**
 * The marks live in their own layer above the cells. Icon Composer replaces
 * the color of a filled layer, so shading drawn into such a layer would be
 * lost; a separate layer also keeps each cell's glass rim clean.
 */
function detailSvg(marks: string[]): string {
  return [
    SVG_OPEN,
    "  <title>Oppi icon detail</title>",
    "  <desc>keycap shading and per-cell engraving drawn over the cells</desc>",
    "  <defs>",
    ...MARK_DEFS.map((line) => `    ${line}`),
    "  </defs>",
    ...marks.map((mark) => `  ${mark}`),
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
function previewSvg(cells: Cell[], marks: string[]): string {
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
  groups.push('  <g id="detail">', ...marks.map((mark) => `    ${mark}`), "  </g>");
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
    ...MARK_DEFS.map((line) => `    ${line}`),
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

// Every layer is registered to the canvas; cell positions live in LAYOUT.
const REGISTERED = { scale: 1, "translation-in-points": [0, 0] };

function layerEntry(name: LayerName) {
  const style = LAYERS[name];
  return {
    ...(style.blendMode ? { "blend-mode": style.blendMode } : {}),
    ...(style.composerFill ? { fill: composerFill(style.composerFill) } : {}),
    glass: true,
    hidden: false,
    "image-name": layerFile(name),
    name,
    position: REGISTERED,
  };
}

function iconDocument() {
  return {
    fill: { "automatic-gradient": "srgb:0.06667,0.06667,0.09412,1.00000" },
    // The first group is the frontmost.
    groups: [
      {
        // Not glass: the marks are shading on the cells, not objects of their own.
        layers: [{ glass: false, hidden: false, "image-name": DETAIL_FILE, name: "detail", position: REGISTERED }],
        shadow: { kind: "neutral", opacity: 0 },
        translucency: { enabled: false, value: 0 },
      },
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

function meta(cells: Cell[], richness: Richness) {
  return {
    generator: "clients/apple/icon-layers/generate.ts",
    seed: SEED,
    richness,
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
  const [richnessArgument, scratchDir] = process.argv.slice(2);
  const richness = Number(richnessArgument ?? RICHNESS) as Richness;
  if (![1, 2, 3].includes(richness)) throw new Error(`richness must be 1, 2 or 3, not "${richnessArgument}"`);

  const repo = resolve(import.meta.dir, "../../..");
  const apple = join(repo, "clients/apple");
  const iconDocumentDir = scratchDir ? resolve(scratchDir) : join(apple, "Oppi/Resources/AppIcon.icon");
  const assetsDir = join(iconDocumentDir, "Assets");
  const sourceDir = join(apple, "icon-layers");
  const flatPng = join(apple, "Oppi/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png");
  const readmePng = join(repo, "docs/images/app-icon.png");

  const cells = parseLayout(LAYOUT);
  const marks = markGroups(cells, richness);
  const files = new Map(LAYER_NAMES.map((name) => [layerFile(name), layerSvg(name, cells)]));
  files.set(DETAIL_FILE, detailSvg(marks));

  resetDirectory(assetsDir);
  for (const [file, svg] of files) writeFileSync(join(assetsDir, file), svg);
  writeFileSync(join(iconDocumentDir, "icon.json"), json(iconDocument()));
  if (scratchDir) {
    console.log(`Wrote the richness ${richness} icon to ${iconDocumentDir}.`);
    return;
  }

  for (const [file, svg] of files) writeFileSync(join(sourceDir, file), svg);
  writeFileSync(join(sourceDir, "meta.json"), json(meta(cells, richness)));
  const previewPath = join(sourceDir, "preview-combined.svg");
  writeFileSync(previewPath, previewSvg(cells, marks));

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
