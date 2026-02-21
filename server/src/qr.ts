/**
 * QR code encoder for terminal display. Zero external dependencies.
 *
 * Core encoder adapted from Project Nayuki's QR Code generator (MIT License).
 * https://www.nayuki.io/page/qr-code-generator-library
 * Copyright (c) Project Nayuki. All rights reserved.
 *
 * Terminal renderer uses Unicode half-block characters (▀▄█ ) to display
 * two module rows per terminal line.
 */

// ── Helpers ─────────────────────────────────────────────────────────

function appendBits(val: number, len: number, bb: number[]): void {
  if (len < 0 || len > 31 || val >>> len !== 0) throw new RangeError("Value out of range");
  for (let i = len - 1; i >= 0; i--) bb.push((val >>> i) & 1);
}

function getBit(x: number, i: number): boolean {
  return ((x >>> i) & 1) !== 0;
}

// ── Reed-Solomon over GF(2^8) ──────────────────────────────────────

function rsMul(x: number, y: number): number {
  // Russian peasant multiplication in GF(2^8/0x11D)
  let z = 0;
  for (let i = 7; i >= 0; i--) {
    z = (z << 1) ^ ((z >>> 7) * 0x11d);
    z ^= ((y >>> i) & 1) * x;
  }
  return z;
}

function rsComputeDivisor(degree: number): number[] {
  const result: number[] = [];
  for (let i = 0; i < degree - 1; i++) result.push(0);
  result.push(1);
  let root = 1;
  for (let i = 0; i < degree; i++) {
    for (let j = 0; j < result.length; j++) {
      result[j] = rsMul(result[j], root);
      if (j + 1 < result.length) result[j] ^= result[j + 1];
    }
    root = rsMul(root, 0x02);
  }
  return result;
}

function rsComputeRemainder(data: readonly number[], divisor: readonly number[]): number[] {
  const result = divisor.map(() => 0);
  for (const b of data) {
    const shifted = result.shift();
    const factor = b ^ (shifted ?? 0);
    result.push(0);
    divisor.forEach((coef, i) => (result[i] ^= rsMul(coef, factor)));
  }
  return result;
}

// ── ECC level ───────────────────────────────────────────────────────

interface EccLevel {
  ordinal: number;
  formatBits: number;
}

const ECC_LOW: EccLevel = { ordinal: 0, formatBits: 1 };
const ECC_MEDIUM: EccLevel = { ordinal: 1, formatBits: 0 };

// ── Segment mode ────────────────────────────────────────────────────

interface Mode {
  modeBits: number;
  numCharCountBits(ver: number): number;
}

const MODE_BYTE: Mode = {
  modeBits: 0x4,
  numCharCountBits(ver: number): number {
    return [8, 16, 16][Math.floor((ver + 7) / 17)];
  },
};

// ── Capacity tables ─────────────────────────────────────────────────

const ECC_CODEWORDS_PER_BLOCK: number[][] = [
  [
    -1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30,
    30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30,
  ],
  [
    -1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28,
    28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28,
  ],
  [
    -1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30,
    30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30,
  ],
  [
    -1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30,
    30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30,
  ],
];

const NUM_ERROR_CORRECTION_BLOCKS: number[][] = [
  [
    -1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14,
    15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25,
  ],
  [
    -1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23,
    25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49,
  ],
  [
    -1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34,
    34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68,
  ],
  [
    -1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35,
    37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81,
  ],
];

function getNumRawDataModules(ver: number): number {
  let result = (16 * ver + 128) * ver + 64;
  if (ver >= 2) {
    const numAlign = Math.floor(ver / 7) + 2;
    result -= (25 * numAlign - 10) * numAlign - 55;
    if (ver >= 7) result -= 36;
  }
  return result;
}

function getNumDataCodewords(ver: number, ecl: EccLevel): number {
  return (
    Math.floor(getNumRawDataModules(ver) / 8) -
    ECC_CODEWORDS_PER_BLOCK[ecl.ordinal][ver] * NUM_ERROR_CORRECTION_BLOCKS[ecl.ordinal][ver]
  );
}

// ── UTF-8 encoding ──────────────────────────────────────────────────

function toUtf8Bytes(str: string): number[] {
  const s = encodeURI(str);
  const result: number[] = [];
  for (let i = 0; i < s.length; i++) {
    if (s.charAt(i) !== "%") {
      result.push(s.charCodeAt(i));
    } else {
      result.push(parseInt(s.substring(i + 1, i + 3), 16));
      i += 2;
    }
  }
  return result;
}

// ── QR Code generation ──────────────────────────────────────────────

/**
 * Encode data into a QR code module matrix.
 * Returns a 2D boolean array where `true` = dark module.
 * Uses byte mode, error correction level L (to minimize size for large payloads).
 */
export function encode(data: string | Uint8Array): boolean[][] {
  const bytes = typeof data === "string" ? toUtf8Bytes(data) : Array.from(data);
  const ecl = ECC_LOW;

  // Build bit stream for byte-mode segment
  const bb: number[] = [];
  appendBits(MODE_BYTE.modeBits, 4, bb);

  // Find minimum version
  let version = 1;
  let dataCapacityBits: number;
  for (; ; version++) {
    if (version > 40) throw new RangeError("Data too long");
    dataCapacityBits = getNumDataCodewords(version, ecl) * 8;
    const ccBits = MODE_BYTE.numCharCountBits(version);
    const totalBits = 4 + ccBits + bytes.length * 8;
    if (totalBits <= dataCapacityBits) break;
  }

  // Try to boost ECC level without increasing version
  let finalEcl = ecl;
  for (const candidate of [ECC_MEDIUM] as EccLevel[]) {
    const ccBits = MODE_BYTE.numCharCountBits(version);
    const totalBits = 4 + ccBits + bytes.length * 8;
    if (totalBits <= getNumDataCodewords(version, candidate) * 8) {
      finalEcl = candidate;
    }
  }

  // Re-encode with final ECL
  dataCapacityBits = getNumDataCodewords(version, finalEcl) * 8;
  const bits: number[] = [];
  appendBits(MODE_BYTE.modeBits, 4, bits);
  appendBits(bytes.length, MODE_BYTE.numCharCountBits(version), bits);
  for (const b of bytes) appendBits(b, 8, bits);

  // Terminator + byte padding
  appendBits(0, Math.min(4, dataCapacityBits - bits.length), bits);
  appendBits(0, (8 - (bits.length % 8)) % 8, bits);
  for (let padByte = 0xec; bits.length < dataCapacityBits; padByte ^= 0xec ^ 0x11) {
    appendBits(padByte, 8, bits);
  }

  // Pack bits into bytes
  const dataCodewords: number[] = new Array(Math.ceil(bits.length / 8)).fill(0);
  bits.forEach((b, i) => (dataCodewords[i >>> 3] |= b << (7 - (i & 7))));

  return buildQrCode(version, finalEcl, dataCodewords);
}

function buildQrCode(version: number, ecl: EccLevel, dataCodewords: number[]): boolean[][] {
  const size = version * 4 + 17;

  // Initialize grids
  const modules: boolean[][] = [];
  const isFunction: boolean[][] = [];
  for (let i = 0; i < size; i++) {
    modules.push(new Array(size).fill(false));
    isFunction.push(new Array(size).fill(false));
  }

  const setFn = (x: number, y: number, dark: boolean): void => {
    modules[y][x] = dark;
    isFunction[y][x] = true;
  };

  // ── Draw function patterns ──

  // Timing patterns
  for (let i = 0; i < size; i++) {
    setFn(6, i, i % 2 === 0);
    setFn(i, 6, i % 2 === 0);
  }

  // Finder patterns
  const drawFinder = (cx: number, cy: number): void => {
    for (let dy = -4; dy <= 4; dy++) {
      for (let dx = -4; dx <= 4; dx++) {
        const dist = Math.max(Math.abs(dx), Math.abs(dy));
        const xx = cx + dx,
          yy = cy + dy;
        if (0 <= xx && xx < size && 0 <= yy && yy < size) {
          setFn(xx, yy, dist !== 2 && dist !== 4);
        }
      }
    }
  };
  drawFinder(3, 3);
  drawFinder(size - 4, 3);
  drawFinder(3, size - 4);

  // Alignment patterns
  const alignPos = getAlignmentPositions(version, size);
  const numAlign = alignPos.length;
  for (let i = 0; i < numAlign; i++) {
    for (let j = 0; j < numAlign; j++) {
      if (
        (i === 0 && j === 0) ||
        (i === 0 && j === numAlign - 1) ||
        (i === numAlign - 1 && j === 0)
      )
        continue;
      for (let dy = -2; dy <= 2; dy++) {
        for (let dx = -2; dx <= 2; dx++) {
          setFn(alignPos[i] + dx, alignPos[j] + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
        }
      }
    }
  }

  // Format bits (dummy mask=0, overwritten later)
  drawFormatBits(modules, isFunction, size, ecl, 0);

  // Version bits
  if (version >= 7) {
    let rem = version;
    for (let i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1f25);
    const vBits = (version << 12) | rem;
    for (let i = 0; i < 18; i++) {
      const color = getBit(vBits, i);
      const a = size - 11 + (i % 3);
      const b = Math.floor(i / 3);
      setFn(a, b, color);
      setFn(b, a, color);
    }
  }

  // ── ECC + interleave ──

  const numBlocks = NUM_ERROR_CORRECTION_BLOCKS[ecl.ordinal][version];
  const blockEccLen = ECC_CODEWORDS_PER_BLOCK[ecl.ordinal][version];
  const rawCodewords = Math.floor(getNumRawDataModules(version) / 8);
  const numShortBlocks = numBlocks - (rawCodewords % numBlocks);
  const shortBlockLen = Math.floor(rawCodewords / numBlocks);

  const rsDiv = rsComputeDivisor(blockEccLen);
  const blocks: number[][] = [];
  for (let i = 0, k = 0; i < numBlocks; i++) {
    const dat = dataCodewords.slice(
      k,
      k + shortBlockLen - blockEccLen + (i < numShortBlocks ? 0 : 1),
    );
    k += dat.length;
    const ecc = rsComputeRemainder(dat, rsDiv);
    if (i < numShortBlocks) dat.push(0);
    blocks.push(dat.concat(ecc));
  }

  const allCodewords: number[] = [];
  for (let i = 0; i < blocks[0].length; i++) {
    blocks.forEach((block, j) => {
      if (i !== shortBlockLen - blockEccLen || j >= numShortBlocks) {
        allCodewords.push(block[i]);
      }
    });
  }

  // ── Draw codewords ──

  let bitIdx = 0;
  for (let right = size - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    for (let vert = 0; vert < size; vert++) {
      for (let j = 0; j < 2; j++) {
        const x = right - j;
        const upward = ((right + 1) & 2) === 0;
        const y = upward ? size - 1 - vert : vert;
        if (!isFunction[y][x] && bitIdx < allCodewords.length * 8) {
          modules[y][x] = getBit(allCodewords[bitIdx >>> 3], 7 - (bitIdx & 7));
          bitIdx++;
        }
      }
    }
  }

  // ── Masking ──

  let bestMask = 0;
  let minPenalty = Infinity;
  for (let m = 0; m < 8; m++) {
    applyMask(modules, isFunction, size, m);
    drawFormatBits(modules, isFunction, size, ecl, m);
    const penalty = getPenaltyScore(modules, size);
    if (penalty < minPenalty) {
      bestMask = m;
      minPenalty = penalty;
    }
    applyMask(modules, isFunction, size, m); // undo
  }

  applyMask(modules, isFunction, size, bestMask);
  drawFormatBits(modules, isFunction, size, ecl, bestMask);

  return modules;
}

// ── Pattern helpers ─────────────────────────────────────────────────

function getAlignmentPositions(version: number, size: number): number[] {
  if (version === 1) return [];
  const numAlign = Math.floor(version / 7) + 2;
  const step = Math.floor((version * 8 + numAlign * 3 + 5) / (numAlign * 4 - 4)) * 2;
  const result = [6];
  for (let pos = size - 7; result.length < numAlign; pos -= step) {
    result.splice(1, 0, pos);
  }
  return result;
}

function drawFormatBits(
  modules: boolean[][],
  isFunction: boolean[][],
  size: number,
  ecl: EccLevel,
  mask: number,
): void {
  const data = (ecl.formatBits << 3) | mask;
  let rem = data;
  for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
  const bits = ((data << 10) | rem) ^ 0x5412;

  const set = (x: number, y: number, dark: boolean): void => {
    modules[y][x] = dark;
    isFunction[y][x] = true;
  };

  // First copy
  for (let i = 0; i <= 5; i++) set(8, i, getBit(bits, i));
  set(8, 7, getBit(bits, 6));
  set(8, 8, getBit(bits, 7));
  set(7, 8, getBit(bits, 8));
  for (let i = 9; i < 15; i++) set(14 - i, 8, getBit(bits, i));

  // Second copy
  for (let i = 0; i < 8; i++) set(size - 1 - i, 8, getBit(bits, i));
  for (let i = 8; i < 15; i++) set(8, size - 15 + i, getBit(bits, i));
  set(8, size - 8, true); // Always dark
}

function applyMask(
  modules: boolean[][],
  isFunction: boolean[][],
  size: number,
  mask: number,
): void {
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let invert: boolean;
      switch (mask) {
        case 0:
          invert = (x + y) % 2 === 0;
          break;
        case 1:
          invert = y % 2 === 0;
          break;
        case 2:
          invert = x % 3 === 0;
          break;
        case 3:
          invert = (x + y) % 3 === 0;
          break;
        case 4:
          invert = (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0;
          break;
        case 5:
          invert = ((x * y) % 2) + ((x * y) % 3) === 0;
          break;
        case 6:
          invert = (((x * y) % 2) + ((x * y) % 3)) % 2 === 0;
          break;
        case 7:
          invert = (((x + y) % 2) + ((x * y) % 3)) % 2 === 0;
          break;
        default:
          throw new Error("Unreachable");
      }
      if (!isFunction[y][x] && invert) modules[y][x] = !modules[y][x];
    }
  }
}

// ── Penalty scoring ─────────────────────────────────────────────────

const PENALTY_N1 = 3;
const PENALTY_N2 = 3;
const PENALTY_N3 = 40;
const PENALTY_N4 = 10;

function getPenaltyScore(modules: boolean[][], size: number): number {
  let result = 0;

  // Adjacent modules in row
  for (let y = 0; y < size; y++) {
    let runColor = false;
    let runX = 0;
    const runHistory = [0, 0, 0, 0, 0, 0, 0];
    for (let x = 0; x < size; x++) {
      if (modules[y][x] === runColor) {
        runX++;
        if (runX === 5) result += PENALTY_N1;
        else if (runX > 5) result++;
      } else {
        finderPenaltyAddHistory(runX, runHistory, size);
        if (!runColor) result += finderPenaltyCountPatterns(runHistory, size) * PENALTY_N3;
        runColor = modules[y][x];
        runX = 1;
      }
    }
    result += finderPenaltyTerminateAndCount(runColor, runX, runHistory, size) * PENALTY_N3;
  }

  // Adjacent modules in column
  for (let x = 0; x < size; x++) {
    let runColor = false;
    let runY = 0;
    const runHistory = [0, 0, 0, 0, 0, 0, 0];
    for (let y = 0; y < size; y++) {
      if (modules[y][x] === runColor) {
        runY++;
        if (runY === 5) result += PENALTY_N1;
        else if (runY > 5) result++;
      } else {
        finderPenaltyAddHistory(runY, runHistory, size);
        if (!runColor) result += finderPenaltyCountPatterns(runHistory, size) * PENALTY_N3;
        runColor = modules[y][x];
        runY = 1;
      }
    }
    result += finderPenaltyTerminateAndCount(runColor, runY, runHistory, size) * PENALTY_N3;
  }

  // 2×2 blocks
  for (let y = 0; y < size - 1; y++) {
    for (let x = 0; x < size - 1; x++) {
      const c = modules[y][x];
      if (c === modules[y][x + 1] && c === modules[y + 1][x] && c === modules[y + 1][x + 1]) {
        result += PENALTY_N2;
      }
    }
  }

  // Dark/light balance
  let dark = 0;
  for (const row of modules) dark = row.reduce((s, c) => s + (c ? 1 : 0), dark);
  const total = size * size;
  const k = Math.ceil(Math.abs(dark * 20 - total * 10) / total) - 1;
  result += k * PENALTY_N4;

  return result;
}

function finderPenaltyCountPatterns(runHistory: number[], _size: number): number {
  const n = runHistory[1];
  const core =
    n > 0 &&
    runHistory[2] === n &&
    runHistory[3] === n * 3 &&
    runHistory[4] === n &&
    runHistory[5] === n;
  return (
    (core && runHistory[0] >= n * 4 && runHistory[6] >= n ? 1 : 0) +
    (core && runHistory[6] >= n * 4 && runHistory[0] >= n ? 1 : 0)
  );
}

function finderPenaltyTerminateAndCount(
  currentRunColor: boolean,
  currentRunLength: number,
  runHistory: number[],
  size: number,
): number {
  if (currentRunColor) {
    finderPenaltyAddHistory(currentRunLength, runHistory, size);
    currentRunLength = 0;
  }
  currentRunLength += size;
  finderPenaltyAddHistory(currentRunLength, runHistory, size);
  return finderPenaltyCountPatterns(runHistory, size);
}

function finderPenaltyAddHistory(
  currentRunLength: number,
  runHistory: number[],
  size: number,
): void {
  if (runHistory[0] === 0) currentRunLength += size;
  runHistory.pop();
  runHistory.unshift(currentRunLength);
}

// ── Terminal rendering ──────────────────────────────────────────────

/**
 * Render QR code as a terminal string using Unicode half-block characters.
 * Includes a 4-module quiet zone as required by the QR spec.
 */
export function renderTerminal(data: string | Uint8Array): string {
  const matrix = encode(data);
  const size = matrix.length;
  const border = 4;
  const total = size + border * 2;

  // Build padded matrix with quiet zone (false = light)
  const padded: boolean[][] = [];
  for (let y = 0; y < total; y++) {
    const row: boolean[] = [];
    for (let x = 0; x < total; x++) {
      const mx = x - border;
      const my = y - border;
      row.push(mx >= 0 && mx < size && my >= 0 && my < size ? matrix[my][mx] : false);
    }
    padded.push(row);
  }

  // Render two rows per line using half-block characters
  const UPPER = "\u2580"; // ▀
  const LOWER = "\u2584"; // ▄
  const FULL = "\u2588"; // █
  const EMPTY = " ";

  const lines: string[] = [];
  for (let y = 0; y < total; y += 2) {
    let line = "";
    for (let x = 0; x < total; x++) {
      const top = padded[y][x];
      const bot = y + 1 < total ? padded[y + 1][x] : false;
      if (top && bot) line += FULL;
      else if (top && !bot) line += UPPER;
      else if (!top && bot) line += LOWER;
      else line += EMPTY;
    }
    lines.push(line);
  }

  return lines.join("\n");
}
