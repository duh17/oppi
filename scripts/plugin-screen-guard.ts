#!/usr/bin/env bun
// Plugin screens are generic: the app draws any built-in plugin's sidebar entry with one list
// screen, from the page's own words. This guard fails when an Apple `PluginScreen*` file names an
// entry: its id (`oppi.mcp`) or the id's last part as a word (`mcp`, in any case), comments
// included. The entries are those `protocol/screens.json` lists, the server's real sidebar.
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { basename, dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const roots = ["clients/apple/Oppi", "clients/apple/OppiCore"].map((root) => join(repoRoot, root));

function swiftFiles(root: string): string[] {
  if (!existsSync(root)) return [];
  return readdirSync(root, { withFileTypes: true }).flatMap((entry) => {
    const path = join(root, entry.name);
    if (entry.isDirectory()) return swiftFiles(path);
    return entry.name.startsWith("PluginScreen") && entry.name.endsWith(".swift") ? [path] : [];
  });
}

const fixture = JSON.parse(readFileSync(join(repoRoot, "protocol/screens.json"), "utf8")) as {
  serverInfo: { sidebar: { id: string }[] };
};
const ids = fixture.serverInfo.sidebar.map((entry) => entry.id);
const escape = (text: string): string => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const patterns = ids.flatMap((id) => [
  new RegExp(escape(id)),
  new RegExp(`\\b${escape(id.split(".").at(-1) ?? id)}\\b`, "i"),
]);

const hits: string[] = [];
const files = roots.flatMap(swiftFiles);
for (const file of files)
  readFileSync(file, "utf8")
    .split("\n")
    .forEach((line, index) => {
      if (patterns.some((pattern) => pattern.test(line)))
        hits.push(`${relative(repoRoot, file)}:${index + 1}: ${line.trim()}`);
    });

if (files.length === 0) {
  console.error("plugin-screen-guard: no PluginScreen* Swift files found");
  process.exit(1);
}
if (hits.length > 0) {
  console.error(
    `plugin-screen-guard: PluginScreen files must not name a sidebar entry (${ids.join(", ")}); ` +
      "draw it from the page instead:",
  );
  for (const hit of hits) console.error(`  ${hit}`);
  process.exit(1);
}
console.log(`plugin-screen-guard: ${files.map((file) => basename(file)).join(", ")} name no entry`);
