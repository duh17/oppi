/**
 * Pi code that `@earendil-works/pi-coding-agent` ships but does not export from its package
 * root, read from Pi's installed `dist/`. Oppi loads such code, text, and constants through
 * here instead of copying them: a copy keeps the old behaviour without a sound when Pi changes,
 * while a load from here fails naming the export that moved, and the tests that reach each use
 * fail on the Pi update that moved it.
 */
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

/** The file Pi's package root resolves to, for reading Pi's `package.json` or its dependencies. */
export const PI_PACKAGE_ENTRY = fileURLToPath(
  import.meta.resolve("@earendil-works/pi-coding-agent"),
);
const PI_DIST = dirname(PI_PACKAGE_ENTRY);

/**
 * `names` from Pi's `dist/<path>`; the same module instance Pi's own imports use. Always
 * `import()`, never `require()`: a require hook (tsx) compiles Pi's ESM to CommonJS, whose
 * nested requires then hit packages that export only `import`.
 */
export async function importPiDist<K extends string>(
  path: string,
  names: readonly K[],
): Promise<Record<K, unknown>> {
  const module = (await import(pathToFileURL(join(PI_DIST, path)).href)) as Record<string, unknown>;
  const missing = names.filter((name) => module[name] === undefined);
  if (missing.length > 0)
    throw new Error(
      `Pi's dist/${path} no longer exports ${missing.join(", ")}; update its use in Oppi`,
    );
  return Object.fromEntries(names.map((name) => [name, module[name]])) as Record<K, unknown>;
}
