#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const PACKED_JS_PREFIX = "package/dist/src/";
export const MOBILE_OUTPUT_GUIDE_PATH = "/server/mobile-output-guide";

export function sourceCandidatesForPackedJs(jsRelPath) {
  const stem = jsRelPath.replace(/\.js$/u, "");
  return [`${stem}.ts`, `${stem}.mts`, `${stem}.js`];
}

export function extractRegistryPaths(registrySource) {
  return [
    ...new Set([...registrySource.matchAll(/path:\s*"(\/[^"]+)"/g)].map((match) => match[1])),
  ];
}

export function checkPackContents({ jsRelPaths, sourceExists }) {
  const failures = [];
  for (const jsRelPath of jsRelPaths) {
    const hasSource = sourceCandidatesForPackedJs(jsRelPath).some((candidate) =>
      sourceExists(candidate),
    );
    if (!hasSource) {
      failures.push(`${jsRelPath}: packed JS has no matching server source`);
    }
  }
  return failures;
}

export function checkPackedRouteContents({ registrySource, distJsByRelativePath }) {
  const failures = [];
  const blob = Object.values(distJsByRelativePath).join("\n");
  const resourcesEntry = Object.entries(distJsByRelativePath).find(([relativePath]) =>
    relativePath.replaceAll("\\", "/").endsWith("routes/server-resources.js"),
  );

  if (!resourcesEntry) {
    failures.push("dist is missing routes/server-resources.js");
  } else if (!resourcesEntry[1].includes(MOBILE_OUTPUT_GUIDE_PATH)) {
    failures.push(`routes/server-resources.js does not include ${MOBILE_OUTPUT_GUIDE_PATH}`);
  }

  for (const routePath of extractRegistryPaths(registrySource)) {
    if (!blob.includes(routePath)) {
      failures.push(`packed dist is missing registry path ${routePath}`);
    }
  }

  return failures;
}

export function checkPackedRelativeImports(distJsByRelativePath) {
  const failures = [];
  for (const [relativePath, source] of Object.entries(distJsByRelativePath)) {
    const imports = source.matchAll(/(?:from\s*|import\s*\()\s*["'](\.{1,2}\/[^"']+\.js)["']/gu);
    for (const [, specifier] of imports) {
      const target = path.posix.normalize(
        path.posix.join(path.posix.dirname(relativePath), specifier),
      );
      if (!Object.hasOwn(distJsByRelativePath, target))
        failures.push(`${relativePath}: packed relative import is missing ${target}`);
    }
  }
  return failures;
}

// npm installs a published package's npm-shrinkwrap.json exactly. Without it, a
// fresh `npm i -g oppi-server` re-resolves Pi's transitive caret ranges, which is
// how 0.51.0 broke once pi-codemode 1.2.0 shipped. prepack copies it from
// package-lock.json, so it must still describe this package.json. npm-packlist
// (npm 11) packs it only when package.json#files lists it.
export function checkPackedShrinkwrap({ manifest, shrinkwrap }) {
  if (!shrinkwrap) {
    return [
      "npm-shrinkwrap.json is missing; installs would not get the tested dependency tree",
    ];
  }
  const failures = [];
  if (!manifest.files?.includes("npm-shrinkwrap.json")) {
    failures.push("package.json#files must list npm-shrinkwrap.json or npm pack omits it");
  }
  const root = shrinkwrap.packages?.[""] ?? {};
  if (root.version !== manifest.version) {
    failures.push(
      `npm-shrinkwrap.json root version ${root.version} does not match package.json ${manifest.version}`,
    );
  }
  const sorted = (deps) => JSON.stringify(Object.entries(deps ?? {}).sort());
  if (sorted(root.dependencies) !== sorted(manifest.dependencies)) {
    failures.push(
      "npm-shrinkwrap.json dependencies do not match package.json; run `npm install` in server/",
    );
  }
  return failures;
}

function readJsonIfExists(file) {
  return existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : undefined;
}

export function packedJsRelPathsFromTarListing(names) {
  return names
    .filter(
      (name) => name.startsWith(PACKED_JS_PREFIX) && name.endsWith(".js") && !name.endsWith("/"),
    )
    .map((name) => name.slice(PACKED_JS_PREFIX.length));
}

export function readDistJsByRelativePath(distDir) {
  const out = {};
  const walk = (dir) => {
    for (const name of readdirSync(dir)) {
      const full = path.join(dir, name);
      const st = statSync(full);
      if (st.isDirectory()) {
        walk(full);
        continue;
      }
      if (!name.endsWith(".js")) continue;
      out[path.relative(distDir, full).replaceAll("\\", "/")] = readFileSync(full, "utf8");
    }
  };
  if (existsSync(distDir)) walk(distDir);
  return out;
}

function listJsRelPaths(dir) {
  return Object.keys(readDistJsByRelativePath(dir));
}

function parseArgs(argv) {
  const args = { tarball: undefined };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    const value = argv[i + 1];
    if (flag === "--tarball" && value) {
      args.tarball = value;
      i += 1;
      continue;
    }
    throw new Error(
      flag === "--tarball" ? "--tarball requires a path" : `Unknown argument: ${flag}`,
    );
  }
  return args;
}

function extractTarball(tarball) {
  const root = mkdtempSync(path.join(tmpdir(), "oppi-pack-contents-"));
  const result = spawnSync("tar", ["-xzf", tarball, "-C", root], { encoding: "utf8" });
  if (result.status !== 0) {
    rmSync(root, { recursive: true, force: true });
    throw new Error(result.stderr?.trim() || `tar failed for ${tarball}`);
  }
  return root;
}

function runCli() {
  const serverDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const { tarball } = parseArgs(process.argv.slice(2));
  const srcDir = path.join(serverDir, "src");
  let extractRoot;
  let distSrcDir = path.join(serverDir, "dist", "src");
  // Without --tarball (prepack), npm packs server/ as-is and always includes
  // npm-shrinkwrap.json when present.
  let packageDir = serverDir;
  let jsRelPaths;

  try {
    if (tarball) {
      extractRoot = extractTarball(path.resolve(tarball));
      packageDir = path.join(extractRoot, "package");
      distSrcDir = path.join(packageDir, "dist", "src");
      jsRelPaths = packedJsRelPathsFromTarListing(
        spawnSync("tar", ["-tzf", path.resolve(tarball)], { encoding: "utf8" })
          .stdout.split("\n")
          .filter(Boolean),
      );
    } else {
      jsRelPaths = listJsRelPaths(distSrcDir);
    }

    const distJsByRelativePath = readDistJsByRelativePath(path.join(distSrcDir, ".."));
    const failures = [
      ...checkPackContents({
        jsRelPaths,
        sourceExists: (rel) => existsSync(path.join(srcDir, rel)),
      }),
      ...checkPackedRouteContents({
        registrySource: readFileSync(path.join(srcDir, "routes", "registry.ts"), "utf8"),
        distJsByRelativePath,
      }),
      ...checkPackedRelativeImports(distJsByRelativePath),
      ...checkPackedShrinkwrap({
        manifest: JSON.parse(readFileSync(path.join(packageDir, "package.json"), "utf8")),
        shrinkwrap: readJsonIfExists(path.join(packageDir, "npm-shrinkwrap.json")),
      }),
    ];

    if (failures.length > 0) {
      console.error("npm pack contents guard failed:");
      for (const failure of failures) console.error(`  - ${failure}`);
      console.error(
        "Pack with `npm pack --ignore-scripts=false` so prepack clean-builds dist and writes npm-shrinkwrap.json. Stale dist is how 0.47.3 omitted /server/mobile-output-guide.",
      );
      process.exitCode = 1;
      return;
    }

    console.log(
      `npm pack contents match server source (${jsRelPaths.length} JS files, includes ${MOBILE_OUTPUT_GUIDE_PATH} and npm-shrinkwrap.json).`,
    );
  } finally {
    if (extractRoot) rmSync(extractRoot, { recursive: true, force: true });
  }
}

const cliPath = process.argv[1];
if (
  cliPath &&
  realpathSync(fileURLToPath(import.meta.url)) === realpathSync(path.resolve(cliPath))
) {
  try {
    runCli();
  } catch (error) {
    console.error(
      `npm pack contents guard failed: ${error instanceof Error ? error.message : String(error)}`,
    );
    process.exitCode = 1;
  }
}
