/**
 * Finds GDScript in a release's packs that uses an API the device engine does not have.
 *
 * Oppi's iOS engine is built with `deprecated=no` (engine/godot/build.sh), so what Godot's class
 * reference marks deprecated is compiled out there, while desktop Godot keeps it: a game that runs
 * clean on the Mac can fail to parse on the device (`Image.create` is the classic). The list comes
 * from the pinned Godot's class reference (`godot-deprecated-api.generated.ts`).
 *
 * This reads the scripts of a pack, never runs them: text (`.gd`) and binary token (`.gdc`, also
 * zstd-compressed) scripts, in `.pck` packs (directory not encrypted, not sparse) and ZIP packs.
 * Later packs replace files in earlier ones, as on the device. A use is a name match, not type
 * analysis, so a hit can be a false positive:
 * - `Class.name` counts when that class's `name` is deprecated.
 * - `x.name` counts when every API called `name` is deprecated (`unique`).
 * - A bare name counts for a deprecated class or a deprecated global function or constant.
 * Names after `$`, `%` and `/` are node names, never APIs.
 */
import * as fs from "node:fs/promises";
import { inflateRawSync, zstdDecompressSync } from "node:zlib";

import {
  GODOT_DEPRECATED_API,
  GODOT_DEPRECATED_SOURCE,
  GODOT_TOKENIZER,
  type GodotDeprecatedApi,
} from "./godot-deprecated-api.generated.js";

export interface DeprecatedApiUse {
  /** `res://` path of the script as written (`.gd`, also for a binary `.gdc`). */
  file: string;
  line: number;
  api: GodotDeprecatedApi;
}

const qualified = new Map<string, GodotDeprecatedApi>();
const unique = new Map<string, GodotDeprecatedApi>();
const bare = new Map<string, GodotDeprecatedApi>();
for (const api of GODOT_DEPRECATED_API) {
  qualified.set(`${api.class}.${api.name}`, api);
  if (api.kind === "class" || api.class.startsWith("@")) bare.set(api.name, api);
  else if (api.unique && !unique.has(api.name)) unique.set(api.name, api);
}

/** What the server logs for a use: what was used, why it matters, and the reference's note. */
export function deprecatedApiMessage(api: GodotDeprecatedApi): string {
  const name =
    api.kind === "class" || api.class.startsWith("@") ? api.name : `${api.class}.${api.name}`;
  const written = api.kind === "method" ? `${name}()` : name;
  const note = api.note ? ` Class reference: "${api.note}"` : "";
  return (
    `${written} is deprecated in Godot ${GODOT_DEPRECATED_SOURCE}; the device engine leaves ` +
    `deprecated APIs out, so this script may fail on the device.${note}`
  );
}

/** Every use in the scripts of `packs` (base first), by file and line; one per API per line. */
export async function findDeprecatedApiUses(packs: readonly string[]): Promise<DeprecatedApiUse[]> {
  const scripts = new Map<string, PackedScript>();
  for (const pack of packs) await listScripts(pack, scripts);
  const uses: DeprecatedApiUse[] = [];
  for (const [path, script] of [...scripts].sort(([a], [b]) => a.localeCompare(b))) {
    const bytes = await readScript(script);
    const tokens = path.endsWith(".gdc") ? binaryTokens(bytes) : textTokens(bytes.toString("utf8"));
    if (!tokens) continue;
    const file = path.replace(/\.gdc$/, ".gd");
    const seen = new Set<string>();
    for (const { line, api } of matchTokens(tokens)) {
      const key = `${line}\0${api.class}.${api.name}`;
      if (seen.has(key)) continue;
      seen.add(key);
      uses.push({ file, line, api });
    }
  }
  return uses;
}

// --- Matching -------------------------------------------------------------------------------------

interface Token {
  kind: "id" | "period" | "nodePath" | "other";
  /** An identifier's name; empty for the other kinds. */
  name: string;
  line: number;
}

function* matchTokens(tokens: Token[]): Generator<{ line: number; api: GodotDeprecatedApi }> {
  for (const [i, token] of tokens.entries()) {
    if (token.kind !== "id") continue;
    const before = tokens[i - 1];
    if (before?.kind === "nodePath") continue;
    let api: GodotDeprecatedApi | undefined;
    if (before?.kind === "period") {
      const owner = tokens[i - 2];
      api =
        (owner?.kind === "id" ? qualified.get(`${owner.name}.${token.name}`) : undefined) ??
        unique.get(token.name);
    } else api = bare.get(token.name);
    if (api) yield { line: token.line, api };
  }
}

// --- Text GDScript ----------------------------------------------------------------------------------

const ID_START = /[\p{L}_]/u;
const ID_PART = /[\p{L}\p{N}_]/u;
const NUMBER_PART = /[0-9A-Za-z_]/;
const DIGIT = /[0-9]/;

const mark = (kind: Token["kind"], line: number): Token => ({ kind, name: "", line });

/** Identifiers, periods and node-path marks of a `.gd`, skipping comments and strings. */
function textTokens(code: string): Token[] {
  const tokens: Token[] = [];
  let line = 1;
  let i = 0;
  const n = code.length;
  while (i < n) {
    const c = code.charAt(i);
    const next = code.charAt(i + 1);
    if (c === "\n") {
      line += 1;
      i += 1;
    } else if (c === "#") {
      while (i < n && code.charAt(i) !== "\n") i += 1;
    } else if (c === '"' || c === "'" || ("r&^".includes(c) && (next === '"' || next === "'"))) {
      // A string, raw string, StringName or NodePath literal, maybe triple-quoted.
      const start = c === '"' || c === "'" ? i : i + 1;
      const quote = code.charAt(start);
      const close = code.startsWith(quote.repeat(3), start) ? quote.repeat(3) : quote;
      let k = start + close.length;
      while (k < n && !code.startsWith(close, k)) {
        if (code.charAt(k) === "\\") k += 1;
        if (code.charAt(k) === "\n") line += 1;
        k += 1;
      }
      tokens.push(mark("other", line));
      i = k + close.length;
    } else if (DIGIT.test(c) || (c === "." && DIGIT.test(next))) {
      let k = i + 1;
      while (
        k < n &&
        (NUMBER_PART.test(code.charAt(k)) ||
          (code.charAt(k) === "." && /[0-9eE]/.test(code.charAt(k + 1))))
      )
        k += 1;
      tokens.push(mark("other", line));
      i = k;
    } else if (ID_START.test(c) || c === "@") {
      let k = i + 1;
      while (k < n && ID_PART.test(code.charAt(k))) k += 1;
      // `@export` is an annotation, never an API.
      tokens.push(c === "@" ? mark("other", line) : { kind: "id", name: code.slice(i, k), line });
      i = k;
    } else if (c === ".") {
      let k = i + 1;
      while (code.charAt(k) === ".") k += 1;
      tokens.push(mark(k === i + 1 ? "period" : "other", line));
      i = k;
    } else {
      if (c === "$" || c === "%" || c === "/") tokens.push(mark("nodePath", line));
      else if (!/\s|\\/.test(c)) tokens.push(mark("other", line));
      i += 1;
    }
  }
  return tokens;
}

// --- Binary GDScript (GDScriptTokenizerBuffer) ---------------------------------------------------

// The token layout of tokenizer version `GODOT_TOKENIZER.version`.
const TOKEN_BYTE_MASK = 0x80;
const TOKEN_MASK = 0x7f;
const TOKEN_BITS = 8;

/** The tokens of a `.gdc`; undefined for another tokenizer version, which the device refuses too. */
function binaryTokens(file: Buffer): Token[] | undefined {
  if (file.length < 12 || file.toString("latin1", 0, 4) !== "GDSC") return undefined;
  if (file.readUInt32LE(4) !== GODOT_TOKENIZER.version) return undefined;
  const body =
    file.readUInt32LE(8) === 0 ? file.subarray(12) : zstdDecompressSync(file.subarray(12));
  const identifierCount = body.readUInt32LE(0);
  const constantCount = body.readUInt32LE(4);
  const lineCount = body.readUInt32LE(8);
  const tokenCount = body.readUInt32LE(12);
  let at = 16;
  const identifiers: string[] = [];
  for (let i = 0; i < identifierCount; i += 1) {
    const length = body.readUInt32LE(at);
    at += 4;
    const codePoints: number[] = [];
    for (let j = 0; j < length; j += 1, at += 4) {
      // UTF-32, every byte XORed with 0xb6.
      codePoints.push((body.readUInt32LE(at) ^ 0xb6b6b6b6) >>> 0);
    }
    identifiers.push(String.fromCodePoint(...codePoints));
  }
  for (let i = 0; i < constantCount; i += 1) at = skipVariant(body, at);
  at += lineCount * 16; // Token lines, then token columns: each token carries its line too.
  const nodePath = new Set<number>(GODOT_TOKENIZER.nodePath);
  const tokens: Token[] = [];
  for (let i = 0; i < tokenCount; i += 1) {
    const wide = (body.readUInt8(at) & TOKEN_BYTE_MASK) !== 0;
    const raw = wide ? body.readUInt32LE(at) : body.readUInt8(at);
    at += wide ? 4 : 1;
    const line = body.readUInt32LE(at);
    at += 4;
    const type = raw & TOKEN_MASK;
    if (type === GODOT_TOKENIZER.identifier)
      tokens.push({ kind: "id", name: identifiers[raw >>> TOKEN_BITS] ?? "", line });
    else if (type === GODOT_TOKENIZER.period) tokens.push(mark("period", line));
    else if (nodePath.has(type)) tokens.push(mark("nodePath", line));
    else tokens.push(mark("other", line));
  }
  return tokens;
}

/** Past one literal as `encode_variant` writes it: the only types a script literal has. */
function skipVariant(body: Buffer, at: number): number {
  const header = body.readUInt32LE(at);
  at += 4;
  const wide = (header & (1 << 16)) !== 0;
  const string = (): void => {
    const length = body.readUInt32LE(at);
    at += 4 + length + ((4 - (length % 4)) % 4);
  };
  switch (header & 0xff) {
    case 0: // NIL
      return at;
    case 1: // BOOL
      return at + 4;
    case 2: // INT
    case 3: // FLOAT
      return at + (wide ? 8 : 4);
    case 4: // STRING
    case 21: // STRING_NAME
      string();
      return at;
    case 22: {
      // NODE_PATH: name count | 0x80000000, subname count, flags, then the strings.
      const names = body.readUInt32LE(at) & 0x7fffffff;
      let subnames = body.readUInt32LE(at + 4);
      if (body.readUInt32LE(at + 8) & 2) subnames += 1;
      at += 12;
      for (let i = 0; i < names + subnames; i += 1) string();
      return at;
    }
    default:
      throw new Error(`Unexpected literal type ${header & 0xff} in a binary script`);
  }
}

// --- Packs ------------------------------------------------------------------------------------------

interface PackedScript {
  pack: string;
  offset: number;
  size: number;
  /** A ZIP entry compressed with deflate; `size` is then the compressed size. */
  deflated?: boolean;
}

const PACK_DIR_ENCRYPTED = 1;
const PACK_SPARSE_BUNDLE = 4;
const PACK_FILE_ENCRYPTED = 1;
const PACK_FILE_REMOVAL = 2;
const PACK_FILE_DELTA = 4;
const SCRIPT = /\.gdc?$/;

const resPath = (path: string): string =>
  `res://${path.replace(/\0+$/, "").replace(/^res:\/\//, "")}`;

async function listScripts(pack: string, into: Map<string, PackedScript>): Promise<void> {
  const handle = await fs.open(pack, "r");
  try {
    const read = async (offset: number, length: number): Promise<Buffer> => {
      const buffer = Buffer.alloc(length);
      const { bytesRead } = await handle.read(buffer, 0, length, offset);
      if (bytesRead !== length) throw new Error("The pack ends early");
      return buffer;
    };
    const magic = (await read(0, 4)).toString("latin1");
    if (magic === "GDPC") await listPck(pack, read, into);
    else await listZip(pack, read, (await handle.stat()).size, into);
  } finally {
    await handle.close();
  }
}

type Read = (offset: number, length: number) => Promise<Buffer>;

async function listPck(pack: string, read: Read, into: Map<string, PackedScript>): Promise<void> {
  const header = await read(0, 40);
  const version = header.readUInt32LE(4);
  const flags = header.readUInt32LE(20);
  // An encrypted directory needs the game's key; a sparse bundle keeps files in other packs.
  if (flags & (PACK_DIR_ENCRYPTED | PACK_SPARSE_BUNDLE)) return;
  const fileBase = Number(header.readBigUInt64LE(24));
  // Version 2 has 16 reserved words after the file base, then the directory; 3 and 4 an offset.
  let at = version === 2 ? 32 + 64 : Number(header.readBigUInt64LE(32));
  const count = (await read(at, 4)).readUInt32LE(0);
  at += 4;
  for (let i = 0; i < count; i += 1) {
    const length = (await read(at, 4)).readUInt32LE(0);
    const entry = await read(at + 4, length + 36);
    at += 4 + length + 36;
    const path = resPath(entry.toString("utf8", 0, length));
    const fileFlags = entry.readUInt32LE(length + 32);
    if (!SCRIPT.test(path)) continue;
    // A removal or a delta replaces the earlier file with something this cannot read.
    if (fileFlags & (PACK_FILE_ENCRYPTED | PACK_FILE_REMOVAL | PACK_FILE_DELTA)) {
      into.delete(path);
      continue;
    }
    into.set(path, {
      pack,
      offset: fileBase + Number(entry.readBigUInt64LE(length)),
      size: Number(entry.readBigUInt64LE(length + 8)),
    });
  }
}

async function listZip(
  pack: string,
  read: Read,
  size: number,
  into: Map<string, PackedScript>,
): Promise<void> {
  // The end-of-central-directory record: the last 22 bytes, or before a comment of up to 64 KB.
  const tailLength = Math.min(size, 22 + 0xffff);
  const tail = await read(size - tailLength, tailLength);
  const end = tail.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06]));
  if (end < 0) return;
  const count = tail.readUInt16LE(end + 10);
  const directory = await read(tail.readUInt32LE(end + 16), tail.readUInt32LE(end + 12));
  let at = 0;
  for (let i = 0; i < count; i += 1) {
    const method = directory.readUInt16LE(at + 10);
    const compressedSize = directory.readUInt32LE(at + 20);
    const nameLength = directory.readUInt16LE(at + 28);
    const extraLength = directory.readUInt16LE(at + 30);
    const commentLength = directory.readUInt16LE(at + 32);
    const local = directory.readUInt32LE(at + 42);
    const path = resPath(directory.toString("utf8", at + 46, at + 46 + nameLength));
    at += 46 + nameLength + extraLength + commentLength;
    if (!SCRIPT.test(path) || (method !== 0 && method !== 8)) continue;
    const localHeader = await read(local, 30);
    into.set(path, {
      pack,
      offset: local + 30 + localHeader.readUInt16LE(26) + localHeader.readUInt16LE(28),
      size: compressedSize,
      deflated: method === 8,
    });
  }
}

async function readScript(script: PackedScript): Promise<Buffer> {
  const handle = await fs.open(script.pack, "r");
  try {
    const buffer = Buffer.alloc(script.size);
    await handle.read(buffer, 0, script.size, script.offset);
    return script.deflated ? inflateRawSync(buffer) : buffer;
  } finally {
    await handle.close();
  }
}
