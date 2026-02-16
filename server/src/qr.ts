/**
 * Minimal QR code encoder for terminal display.
 * Byte mode, EC level M, versions 1–40. Zero external dependencies.
 * ISO/IEC 18004 compliant subset.
 */

// ── GF(256) Arithmetic ──────────────────────────────────────────────
// Irreducible polynomial: x^8 + x^4 + x^3 + x^2 + 1 (0x11D)

const GF_EXP = new Uint8Array(512);
const GF_LOG = new Uint8Array(256);

{
  let x = 1;
  for (let i = 0; i < 255; i++) {
    GF_EXP[i] = x;
    GF_LOG[x] = i;
    x = (x << 1) ^ (x >= 128 ? 0x11d : 0);
  }
  for (let i = 255; i < 512; i++) GF_EXP[i] = GF_EXP[i - 255];
}

function gfMul(a: number, b: number): number {
  return a === 0 || b === 0 ? 0 : GF_EXP[GF_LOG[a] + GF_LOG[b]];
}

// ── Reed-Solomon ────────────────────────────────────────────────────

function rsGeneratorPoly(n: number): Uint8Array {
  let g = new Uint8Array([1]);
  for (let i = 0; i < n; i++) {
    const next = new Uint8Array(g.length + 1);
    const ai = GF_EXP[i];
    next[0] = g[0];
    for (let j = 1; j < g.length; j++) next[j] = g[j] ^ gfMul(g[j - 1], ai);
    next[g.length] = gfMul(g[g.length - 1], ai);
    g = next;
  }
  return g;
}

function rsEncode(data: Uint8Array, ecCount: number): Uint8Array {
  const gen = rsGeneratorPoly(ecCount);
  const buf = new Uint8Array(data.length + ecCount);
  buf.set(data);
  for (let i = 0; i < data.length; i++) {
    const coef = buf[i];
    if (coef !== 0) {
      for (let j = 0; j < gen.length; j++) buf[i + j] ^= gfMul(gen[j], coef);
    }
  }
  return buf.slice(data.length);
}

// ── EC Table (Level M) ─────────────────────────────────────────────
// [ecPerBlock, g1Blocks, g1DataCW, g2Blocks, g2DataCW]

const EC_M: readonly number[][] = [
  /*v0*/ [],
  /*v1 */ [10, 1, 16, 0, 0],
  /*v2 */ [16, 1, 28, 0, 0],
  /*v3 */ [26, 1, 44, 0, 0],
  /*v4 */ [18, 2, 32, 0, 0],
  /*v5 */ [24, 2, 43, 0, 0],
  /*v6 */ [16, 4, 27, 0, 0],
  /*v7 */ [18, 4, 31, 0, 0],
  /*v8 */ [22, 2, 38, 2, 39],
  /*v9 */ [22, 3, 36, 2, 37],
  /*v10*/ [26, 4, 43, 1, 44],
  /*v11*/ [30, 1, 50, 4, 51],
  /*v12*/ [22, 6, 36, 2, 37],
  /*v13*/ [22, 8, 37, 1, 38],
  /*v14*/ [24, 4, 40, 5, 41],
  /*v15*/ [24, 5, 41, 5, 42],
  /*v16*/ [28, 7, 45, 3, 46],
  /*v17*/ [28, 10, 46, 1, 47],
  /*v18*/ [26, 9, 43, 4, 44],
  /*v19*/ [26, 3, 44, 11, 45],
  /*v20*/ [26, 3, 41, 13, 42],
  /*v21*/ [26, 17, 42, 0, 0],
  /*v22*/ [28, 17, 46, 0, 0],
  /*v23*/ [28, 4, 47, 14, 48],
  /*v24*/ [28, 6, 45, 14, 46],
  /*v25*/ [28, 8, 47, 13, 48],
  /*v26*/ [28, 19, 46, 4, 47],
  /*v27*/ [28, 22, 45, 3, 46],
  /*v28*/ [30, 3, 45, 23, 46],
  /*v29*/ [30, 21, 45, 7, 46],
  /*v30*/ [30, 19, 47, 10, 48],
  /*v31*/ [30, 2, 46, 29, 47],
  /*v32*/ [30, 10, 46, 23, 47],
  /*v33*/ [30, 14, 46, 21, 47],
  /*v34*/ [30, 14, 46, 23, 47],
  /*v35*/ [30, 12, 47, 26, 48],
  /*v36*/ [30, 6, 47, 34, 48],
  /*v37*/ [30, 29, 46, 14, 47],
  /*v38*/ [30, 13, 46, 32, 47],
  /*v39*/ [30, 40, 47, 7, 48],
  /*v40*/ [30, 18, 47, 31, 48],
];

// ── Geometry ────────────────────────────────────────────────────────

function alignmentPositions(version: number): number[] {
  if (version < 2) return [];
  const last = 4 * version + 10;
  const count = 2 + Math.floor(version / 7);
  if (count === 2) return [6, last];
  let step = Math.ceil((last - 6) / (count - 1));
  if (step % 2 !== 0) step++;
  const r = [6];
  for (let i = count - 2; i >= 1; i--) r.push(last - i * step);
  r.push(last);
  return r;
}

/** Count modules available for data (including remainder bits). */
function dataModuleCount(version: number): number {
  const size = 4 * version + 17;
  let n = size * size;
  n -= 192; // 3 finder + separator (8×8 each)
  n -= 2 * (size - 16); // timing patterns
  n -= 31; // format info (15×2 + dark module)
  if (version >= 7) n -= 36; // version info (18×2)
  if (version >= 2) {
    const pos = alignmentPositions(version);
    const c = pos.length;
    n -= (c * c - 3) * 25; // alignment patterns (skip 3 at finder corners)
    n += (c - 2) * 2 * 5; // add back timing/alignment overlaps
  }
  return n;
}

function totalCodewords(version: number): number {
  return Math.floor(dataModuleCount(version) / 8);
}

// ── Data Encoding ───────────────────────────────────────────────────

function selectVersion(byteLen: number): number {
  for (let v = 1; v <= 40; v++) {
    const [, g1b, g1d, g2b, g2d] = EC_M[v];
    const dataCW = g1b * g1d + g2b * g2d;
    const countBits = v <= 9 ? 8 : 16;
    if (byteLen * 8 + 4 + countBits <= dataCW * 8) return v;
  }
  throw new Error(`Data too large for QR: ${byteLen} bytes`);
}

/** Encode input into the final interleaved codeword stream (data + EC). */
function encodeData(
  input: Uint8Array,
  version: number,
): Uint8Array {
  const [ecPerBlock, g1b, g1d, g2b, g2d] = EC_M[version];
  const totalDataCW = g1b * g1d + g2b * g2d;
  const countBits = version <= 9 ? 8 : 16;

  // Build bit stream
  const bits: number[] = [];
  const pushBits = (val: number, len: number) => {
    for (let i = len - 1; i >= 0; i--) bits.push((val >> i) & 1);
  };
  pushBits(0b0100, 4); // byte mode
  pushBits(input.length, countBits);
  for (const b of input) pushBits(b, 8);
  // Terminator (up to 4 zero bits)
  const termLen = Math.min(4, totalDataCW * 8 - bits.length);
  for (let i = 0; i < termLen; i++) bits.push(0);
  // Pad to byte boundary
  while (bits.length % 8 !== 0) bits.push(0);
  // Pad with 0xEC, 0x11
  let padIdx = 0;
  while (bits.length < totalDataCW * 8) {
    pushBits(padIdx % 2 === 0 ? 0xec : 0x11, 8);
    padIdx++;
  }

  // Convert to codewords
  const codewords = new Uint8Array(totalDataCW);
  for (let i = 0; i < totalDataCW; i++) {
    let byte = 0;
    for (let b = 0; b < 8; b++) byte = (byte << 1) | bits[i * 8 + b];
    codewords[i] = byte;
  }

  // Split into blocks and compute EC
  const dataBlocks: Uint8Array[] = [];
  const ecBlocks: Uint8Array[] = [];
  let offset = 0;
  for (let g = 0; g < 2; g++) {
    const count = g === 0 ? g1b : g2b;
    const size = g === 0 ? g1d : g2d;
    for (let i = 0; i < count; i++) {
      const block = codewords.slice(offset, offset + size);
      dataBlocks.push(block);
      ecBlocks.push(rsEncode(block, ecPerBlock));
      offset += size;
    }
  }

  // Interleave data codewords
  const result: number[] = [];
  const maxDataLen = Math.max(g1d, g2d || 0);
  for (let i = 0; i < maxDataLen; i++) {
    for (const block of dataBlocks) {
      if (i < block.length) result.push(block[i]);
    }
  }
  // Interleave EC codewords
  for (let i = 0; i < ecPerBlock; i++) {
    for (const block of ecBlocks) result.push(block[i]);
  }

  return new Uint8Array(result);
}

// ── Matrix Construction ─────────────────────────────────────────────

interface QRMatrix {
  size: number;
  modules: boolean[][]; // true = dark
  reserved: boolean[][]; // true = function pattern (not maskable)
}

function createMatrix(version: number): QRMatrix {
  const size = 4 * version + 17;
  const modules = Array.from({ length: size }, () => new Array<boolean>(size).fill(false));
  const reserved = Array.from({ length: size }, () => new Array<boolean>(size).fill(false));
  return { size, modules, reserved };
}

function setModule(m: QRMatrix, row: number, col: number, dark: boolean, reserve: boolean): void {
  m.modules[row][col] = dark;
  if (reserve) m.reserved[row][col] = true;
}

function placeFinderPattern(m: QRMatrix, row: number, col: number): void {
  for (let r = -1; r <= 7; r++) {
    for (let c = -1; c <= 7; c++) {
      const rr = row + r;
      const cc = col + c;
      if (rr < 0 || rr >= m.size || cc < 0 || cc >= m.size) continue;
      const dark =
        (r >= 0 && r <= 6 && (c === 0 || c === 6)) ||
        (c >= 0 && c <= 6 && (r === 0 || r === 6)) ||
        (r >= 2 && r <= 4 && c >= 2 && c <= 4);
      setModule(m, rr, cc, dark, true);
    }
  }
}

function placeAlignmentPattern(m: QRMatrix, row: number, col: number): void {
  for (let r = -2; r <= 2; r++) {
    for (let c = -2; c <= 2; c++) {
      const dark = Math.abs(r) === 2 || Math.abs(c) === 2 || (r === 0 && c === 0);
      setModule(m, row + r, col + c, dark, true);
    }
  }
}

function placeFunctionPatterns(m: QRMatrix, version: number): void {
  const s = m.size;

  // Finder patterns
  placeFinderPattern(m, 0, 0);
  placeFinderPattern(m, 0, s - 7);
  placeFinderPattern(m, s - 7, 0);

  // Timing patterns
  for (let i = 8; i < s - 8; i++) {
    const dark = i % 2 === 0;
    setModule(m, 6, i, dark, true);
    setModule(m, i, 6, dark, true);
  }

  // Dark module
  setModule(m, 4 * version + 9, 8, true, true);

  // Alignment patterns
  if (version >= 2) {
    const pos = alignmentPositions(version);
    const last = pos.length - 1;
    for (let ri = 0; ri <= last; ri++) {
      for (let ci = 0; ci <= last; ci++) {
        // Skip if overlapping with finder patterns
        if (ri === 0 && ci === 0) continue;
        if (ri === 0 && ci === last) continue;
        if (ri === last && ci === 0) continue;
        placeAlignmentPattern(m, pos[ri], pos[ci]);
      }
    }
  }

  // Reserve format info areas (filled later)
  // Near top-left finder
  for (let i = 0; i <= 8; i++) {
    if (i !== 6) m.reserved[8][i] = true; // row 8
    if (i !== 6) m.reserved[i][8] = true; // col 8
  }
  // Near top-right finder
  for (let i = 0; i < 8; i++) m.reserved[8][s - 1 - i] = true;
  // Near bottom-left finder
  for (let i = 0; i < 7; i++) m.reserved[s - 1 - i][8] = true;

  // Reserve version info areas (v7+)
  if (version >= 7) {
    for (let i = 0; i < 6; i++) {
      for (let j = 0; j < 3; j++) {
        m.reserved[i][s - 11 + j] = true; // top-right
        m.reserved[s - 11 + j][i] = true; // bottom-left
      }
    }
  }
}

function placeDataBits(m: QRMatrix, stream: Uint8Array, version: number): void {
  const s = m.size;
  const totalBits = totalCodewords(version) * 8 + (dataModuleCount(version) % 8);
  let bitIdx = 0;

  // Zigzag: 2-column strips from right to left, skipping col 6
  let col = s - 1;
  while (col >= 0) {
    if (col === 6) col--; // skip timing column
    const goingUp = ((s - 1 - col) >> 1) % 2 === 0;
    for (let r = 0; r < s; r++) {
      const row = goingUp ? s - 1 - r : r;
      for (let dc = 0; dc <= 1; dc++) {
        const c = col - dc;
        if (c < 0) continue;
        if (m.reserved[row][c]) continue;
        if (bitIdx < totalBits) {
          const byteIdx = Math.floor(bitIdx / 8);
          const bitPos = 7 - (bitIdx % 8);
          const dark = byteIdx < stream.length ? ((stream[byteIdx] >> bitPos) & 1) === 1 : false;
          m.modules[row][c] = dark;
        }
        bitIdx++;
      }
    }
    col -= 2;
  }
}

// ── Masking ─────────────────────────────────────────────────────────

type MaskFn = (row: number, col: number) => boolean;

const MASK_FNS: MaskFn[] = [
  (r, c) => (r + c) % 2 === 0,
  (r) => r % 2 === 0,
  (_r, c) => c % 3 === 0,
  (r, c) => (r + c) % 3 === 0,
  (r, c) => (Math.floor(r / 2) + Math.floor(c / 3)) % 2 === 0,
  (r, c) => ((r * c) % 2) + ((r * c) % 3) === 0,
  (r, c) => (((r * c) % 2) + ((r * c) % 3)) % 2 === 0,
  (r, c) => (((r + c) % 2) + ((r * c) % 3)) % 2 === 0,
];

function applyMask(m: QRMatrix, maskId: number): void {
  const fn = MASK_FNS[maskId];
  for (let r = 0; r < m.size; r++) {
    for (let c = 0; c < m.size; c++) {
      if (!m.reserved[r][c] && fn(r, c)) {
        m.modules[r][c] = !m.modules[r][c];
      }
    }
  }
}

function penaltyScore(m: QRMatrix): number {
  const s = m.size;
  let score = 0;

  // Rule 1: Runs of 5+ same-color modules in row/column
  for (let r = 0; r < s; r++) {
    let runLen = 1;
    for (let c = 1; c < s; c++) {
      if (m.modules[r][c] === m.modules[r][c - 1]) {
        runLen++;
      } else {
        if (runLen >= 5) score += 3 + (runLen - 5);
        runLen = 1;
      }
    }
    if (runLen >= 5) score += 3 + (runLen - 5);
  }
  for (let c = 0; c < s; c++) {
    let runLen = 1;
    for (let r = 1; r < s; r++) {
      if (m.modules[r][c] === m.modules[r - 1][c]) {
        runLen++;
      } else {
        if (runLen >= 5) score += 3 + (runLen - 5);
        runLen = 1;
      }
    }
    if (runLen >= 5) score += 3 + (runLen - 5);
  }

  // Rule 2: 2×2 blocks of same color
  for (let r = 0; r < s - 1; r++) {
    for (let c = 0; c < s - 1; c++) {
      const v = m.modules[r][c];
      if (v === m.modules[r][c + 1] && v === m.modules[r + 1][c] && v === m.modules[r + 1][c + 1])
        score += 3;
    }
  }

  // Rule 3: Finder-like patterns (1011101 + 4 light on either side)
  const pat1 = [true, false, true, true, true, false, true, false, false, false, false];
  const pat2 = [false, false, false, false, true, false, true, true, true, false, true];
  for (let r = 0; r < s; r++) {
    for (let c = 0; c <= s - 11; c++) {
      let match1 = true;
      let match2 = true;
      for (let k = 0; k < 11; k++) {
        if (m.modules[r][c + k] !== pat1[k]) match1 = false;
        if (m.modules[r][c + k] !== pat2[k]) match2 = false;
        if (!match1 && !match2) break;
      }
      if (match1) score += 40;
      if (match2) score += 40;
    }
  }
  for (let c = 0; c < s; c++) {
    for (let r = 0; r <= s - 11; r++) {
      let match1 = true;
      let match2 = true;
      for (let k = 0; k < 11; k++) {
        if (m.modules[r + k][c] !== pat1[k]) match1 = false;
        if (m.modules[r + k][c] !== pat2[k]) match2 = false;
        if (!match1 && !match2) break;
      }
      if (match1) score += 40;
      if (match2) score += 40;
    }
  }

  // Rule 4: Proportion of dark modules
  let darkCount = 0;
  for (let r = 0; r < s; r++) {
    for (let c = 0; c < s; c++) {
      if (m.modules[r][c]) darkCount++;
    }
  }
  const pct = (darkCount * 100) / (s * s);
  const prev5 = Math.floor(pct / 5) * 5;
  const next5 = prev5 + 5;
  score += Math.min(Math.abs(prev5 - 50), Math.abs(next5 - 50)) * 2; // ×10/5 = ×2

  return score;
}

// ── Format / Version Info ───────────────────────────────────────────

function formatInfoBits(maskId: number): number {
  // EC level M = 00, mask 3 bits
  const data = (0b00 << 3) | maskId;
  let bch = data << 10;
  for (let i = 4; i >= 0; i--) {
    if (bch & (1 << (i + 10))) bch ^= 0x537 << i;
  }
  return ((data << 10) | bch) ^ 0x5412;
}

function writeFormatInfo(m: QRMatrix, maskId: number): void {
  const bits = formatInfoBits(maskId);
  const s = m.size;

  // Near top-left: row 8 (bits 0–7) and col 8 (bits 8–14)
  const rowPositions = [0, 1, 2, 3, 4, 5, 7, 8]; // col positions in row 8
  const colPositions = [8, 8, 8, 8, 8, 8, 8]; // row positions in col 8
  const colRows = [7, 5, 4, 3, 2, 1, 0]; // row indices for col 8

  for (let i = 0; i < 8; i++) {
    const dark = ((bits >> i) & 1) === 1;
    m.modules[8][rowPositions[i]] = dark;
  }
  for (let i = 0; i < 7; i++) {
    const dark = ((bits >> (i + 8)) & 1) === 1;
    m.modules[colRows[i]][8] = dark;
  }

  // Mirrored: row 8 near top-right, col 8 near bottom-left
  for (let i = 0; i < 7; i++) {
    const dark = ((bits >> i) & 1) === 1;
    m.modules[s - 1 - i][8] = dark;
  }
  for (let i = 0; i < 8; i++) {
    const dark = ((bits >> (i + 7)) & 1) === 1;
    m.modules[8][s - 8 + i] = dark;
  }
}

function versionInfoBits(version: number): number {
  let bch = version << 12;
  for (let i = 5; i >= 0; i--) {
    if (bch & (1 << (i + 12))) bch ^= 0x1f25 << i;
  }
  return (version << 12) | bch;
}

function writeVersionInfo(m: QRMatrix, version: number): void {
  if (version < 7) return;
  const bits = versionInfoBits(version);
  const s = m.size;
  for (let i = 0; i < 18; i++) {
    const dark = ((bits >> i) & 1) === 1;
    const row = Math.floor(i / 3);
    const col = s - 11 + (i % 3);
    m.modules[row][col] = dark; // top-right
    m.modules[col][row] = dark; // bottom-left (transposed)
  }
}

// ── Public API ──────────────────────────────────────────────────────

/** Encode data into a QR code boolean matrix. true = dark module. */
export function encode(data: string | Uint8Array): boolean[][] {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  const version = selectVersion(bytes.length);
  const stream = encodeData(bytes, version);

  const m = createMatrix(version);
  placeFunctionPatterns(m, version);
  placeDataBits(m, stream, version);

  // Try all 8 masks, pick lowest penalty
  let bestMask = 0;
  let bestScore = Infinity;
  for (let mask = 0; mask < 8; mask++) {
    // Clone modules for testing
    const saved = m.modules.map((row) => [...row]);
    applyMask(m, mask);
    writeFormatInfo(m, mask);
    writeVersionInfo(m, version);
    const score = penaltyScore(m);
    if (score < bestScore) {
      bestScore = score;
      bestMask = mask;
    }
    // Restore
    m.modules = saved;
  }

  // Apply the winning mask
  applyMask(m, bestMask);
  writeFormatInfo(m, bestMask);
  writeVersionInfo(m, version);

  return m.modules;
}

/**
 * Render QR code as a terminal string using Unicode half-block characters.
 * Each character cell represents 2 vertical modules.
 * Includes a 1-module quiet zone.
 */
export function renderTerminal(data: string | Uint8Array): string {
  const matrix = encode(data);
  const n = matrix.length;
  const lines: string[] = [];

  // Helper: get module value with quiet zone (false = light outside bounds)
  const get = (r: number, c: number): boolean =>
    r >= 0 && r < n && c >= 0 && c < n && matrix[r][c];

  // Process 2 rows at a time, using half-block characters
  // ▀ = top dark, bottom light  (U+2580)
  // ▄ = top light, bottom dark  (U+2584)
  // █ = both dark               (U+2588)
  //   = both light              (space)
  const qz = 1; // quiet zone modules
  for (let r = -qz; r < n + qz; r += 2) {
    let line = "";
    for (let c = -qz; c < n + qz; c++) {
      const top = get(r, c);
      const bot = get(r + 1, c);
      if (top && bot) line += "█";
      else if (top) line += "▀";
      else if (bot) line += "▄";
      else line += " ";
    }
    lines.push(line);
  }

  return lines.join("\n");
}
