/**
 * Directory listings in Node's order, so a listing does not depend on the runtime.
 *
 * Node's `fs.readdir` sorts what it returns (libuv `scandir` with `alphasort`, in the C locale:
 * byte order of the UTF-8 name). Bun's `readdir` returns directory order, which differs per
 * filesystem and per run. Wherever order reaches the user or decides a "last one wins" outcome,
 * list through here. `opendir` is unsorted on Node too; sort what it yields.
 */
import { readdirSync } from "node:fs";

/**
 * Byte order of the UTF-8 encodings, without encoding: UTF-16 code units match it except that a
 * surrogate (a code point above U+FFFF, lead byte F0+) sorts after every other unit, including
 * U+E000 to U+FFFF.
 */
export function compareDirEntryNames(a: string, b: string): number {
  if (a === b) return 0;
  const shared = Math.min(a.length, b.length);
  for (let i = 0; i < shared; i++) {
    const x = a.charCodeAt(i);
    const y = b.charCodeAt(i);
    if (x === y) continue;
    const xSurrogate = x >= 0xd800 && x <= 0xdfff;
    const ySurrogate = y >= 0xd800 && y <= 0xdfff;
    if (xSurrogate !== ySurrogate) return xSurrogate ? 1 : -1;
    return x < y ? -1 : 1;
  }
  return a.length < b.length ? -1 : 1;
}

/** `readdirSync(dir)` in Node's order. Throws as `readdirSync` does. */
export function readdirSyncSorted(dir: string): string[] {
  return readdirSync(dir).sort(compareDirEntryNames);
}
