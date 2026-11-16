#!/usr/bin/env node
// Load a build's built-in plugins the way its server does, under the runtime running this script,
// and fail when any of them would not load. copy-plugins.mjs runs it under Node and, where it is
// installed, Bun: the server runs on either, and they resolve a plugin's imports differently.
//
// It checks two things:
// - `oppi/v1` does not resolve from a built plugin's folder. The plugin host hands plugin code its
//   own `oppi/v1` (jiti's virtual modules), but jiti imports a built plugin's `.js` natively first
//   and uses its own loader only when that import fails. A runtime that resolves `oppi/v1` itself
//   gives the plugin a second `oppi/v1`, with its own Chord: a screen contract declared there is
//   not one the host's Chord knows, and the plugin fails to load (or loads on other module state).
//   Which packages the build reaches changes when its node_modules is cloned in, so a full load
//   here could pass while the running server fails; resolution does not depend on that.
// - every built-in plugin loads: the durable harness reports no plugin with a load error.
import { createRequire } from "node:module";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const buildRoot = resolve(process.argv[2] ?? "dist");
const pluginsDir = join(buildRoot, "plugins");
const runtime = process.versions.bun ? `Bun ${process.versions.bun}` : `Node ${process.version}`;
// The names only the plugin host provides; real packages resolve to the build's own copies.
const HOST_ONLY = ["oppi/v1", "oppi/v1/schema"];

const problems = [];
const builtIns = JSON.parse(readFileSync(join(pluginsDir, "package.json"), "utf8")).chord.plugins;
for (const specifier of HOST_ONLY) {
  const resolved = new Map();
  for (const listed of builtIns) {
    try {
      const path = createRequire(join(pluginsDir, listed, "server.js")).resolve(specifier);
      resolved.set(path, [...(resolved.get(path) ?? []), listed]);
    } catch {
      // Unresolvable: jiti falls back to its loader, which hands over the host's module.
    }
  }
  for (const [path, plugins] of resolved)
    problems.push(`${specifier} resolves to ${path} from ${plugins.join(", ")}`);
}

// No owner plugins or packages: an empty agent dir and data dir of its own.
const scratch = mkdtempSync(join(tmpdir(), "oppi-plugin-check-"));
process.env.PI_CODING_AGENT_DIR = join(scratch, "agent");
try {
  const { DurableHarness } = await import(
    pathToFileURL(join(buildRoot, "src", "durable-harness.js")).href
  );
  const harness = new DurableHarness(join(scratch, "data"));
  try {
    await harness.ensureShared();
    for (const plugin of harness.listPlugins().plugins)
      if (plugin.loadError) problems.push(`${plugin.name}: ${plugin.loadError}`);
  } finally {
    await harness.closeAll();
  }
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

if (problems.length > 0) {
  console.error(`check-built-plugins (${runtime}): ${problems.join("; ")}`);
  process.exit(1);
}
console.error(`check-built-plugins (${runtime}): ${builtIns.length} built-in plugins load`);
