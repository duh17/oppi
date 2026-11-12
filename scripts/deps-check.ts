#!/usr/bin/env bun
/**
 * Weekly dependency and vulnerability report for the whole repo, as one Markdown document.
 *
 *   bun scripts/deps-check.ts [--out <file>]     report to stdout (and <file>)
 *
 * Read-only: it never edits files or installs anything. It needs network access to the npm
 * registry, api.osv.dev, GitHub (`gh` signed in), nodejs.org, go.dev, and ziglang.org; a source it
 * cannot reach is listed under "Gaps" instead of failing the run. Exit 0 with a report even when
 * issues exist; nonzero only when the script itself breaks.
 *
 * Sources scanned: every tracked package.json (npm audit + OSV for lockfile projects, OSV on the
 * newest version matching each range for lockfile-less ones), clients/apple Package.resolved and
 * the project.yml pins, the vendored GhosttyVt / TailscaleKit build pins, GitHub Actions in
 * .github/workflows, and the pinned toolchains (bundled Node, Go, Zig, Xcode, gitleaks).
 * Coverage is in the "Coverage" and "Gaps" sections of the report.
 */
import { execFile, spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const run = promisify(execFile);
const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const STALE_MS = 365 * 24 * 3600 * 1000;

// ── types ───────────────────────────────────────────────────────────────────

export type Bump = "current" | "patch" | "minor" | "major" | "ahead" | "unknown";
export type Vuln = {
  id: string;
  aliases: string[];
  severity: string;
  eco: string;
  pkg: string;
  version: string;
  fixed: string[];
  scope: "runtime" | "dev-only" | "n/a";
  source: string; // project that pulls it in
  summary: string;
};
type OutdatedRow = {
  source: string;
  name: string;
  current: string;
  latest: string;
  bump: Bump;
  scope: string;
  note: string;
  stale: string;
};
type Action = { rank: 1 | 2 | 3; text: string };

const gaps: string[] = [];
const coverage: string[] = [];
const vulns: Vuln[] = [];
const outdated: OutdatedRow[] = [];
const inventory: string[][] = [];

// ── helpers ─────────────────────────────────────────────────────────────────

export function parseVer(v: string): number[] | undefined {
  const m = /^v?(\d+)\.(\d+)(?:\.(\d+))?$/.exec(v.trim());
  return m ? [Number(m[1]), Number(m[2]), Number(m[3] ?? 0)] : undefined;
}

/** How far `latest` is ahead of `current`; 0.x minors are flagged by the caller via `breaking0x`. */
export function bump(current: string, latest: string): Bump {
  const c = parseVer(current);
  const l = parseVer(latest);
  if (!c || !l) return "unknown";
  if (l[0] !== c[0]) return l[0] > c[0] ? "major" : "ahead";
  if (l[1] !== c[1]) return l[1] > c[1] ? "minor" : "ahead";
  if (l[2] !== c[2]) return l[2] > c[2] ? "patch" : "ahead";
  return "current";
}

/** Base upstream tag of a fork pin tagged `<upstream-tag>-oppi.N`; undefined for any other tag. */
export function forkBaseTag(tag: string): string | undefined {
  return /^(.+)-oppi\.\d+$/.exec(tag)?.[1];
}

/** Fork status against upstream's latest tag: "rebase due" when the base trails, "unknown" when a tag is not numeric. */
export function forkStatus(baseTag: string, upstreamLatest: string): "rebase due" | "up to date" | "unknown" {
  const b = bump(baseTag, upstreamLatest);
  return b === "unknown" ? "unknown" : b === "current" || b === "ahead" ? "up to date" : "rebase due";
}

const cmpVer = (a: number[], b: number[]) => a[0] - b[0] || a[1] - b[1] || a[2] - b[2];

async function pool<T, R>(items: T[], size: number, fn: (x: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(size, items.length) }, async () => {
      while (next < items.length) {
        const i = next++;
        out[i] = await fn(items[i]);
      }
    }),
  );
  return out;
}

async function http(url: string, init?: RequestInit): Promise<any> {
  const res = await fetch(url, { ...init, signal: AbortSignal.timeout(45_000) });
  if (!res.ok) throw new Error(`${url} -> HTTP ${res.status}`);
  return res.json();
}

async function gh(path: string): Promise<any> {
  const { stdout } = await run("gh", ["api", path], { maxBuffer: 64 * 1024 * 1024, timeout: 45_000 });
  return JSON.parse(stdout);
}

async function guarded<T>(label: string, fn: () => Promise<T>): Promise<T | undefined> {
  try {
    return await fn();
  } catch (e) {
    gaps.push(`${label}: ${(e as Error).message.split("\n")[0]}`);
    return undefined;
  }
}

const sevRank: Record<string, number> = { CRITICAL: 4, HIGH: 3, MODERATE: 2, MEDIUM: 2, LOW: 1, UNKNOWN: 0 };
const sevOf = (s: string) => sevRank[s.toUpperCase()] ?? 0;

// ── OSV ─────────────────────────────────────────────────────────────────────

type OsvQuery = { eco: string; name: string; version?: string; commit?: string; meta: { source: string; scope: Vuln["scope"] } };
const osvDetailCache = new Map<string, any>();

async function osvScan(queries: OsvQuery[]): Promise<void> {
  const chunks: OsvQuery[][] = [];
  for (let i = 0; i < queries.length; i += 500) chunks.push(queries.slice(i, i + 500));
  for (const chunk of chunks) {
    const body = {
      queries: chunk.map((q) =>
        q.commit ? { commit: q.commit } : { package: { ecosystem: q.eco, name: q.name }, version: q.version },
      ),
    };
    const res = await http("https://api.osv.dev/v1/querybatch", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    const hits: { q: OsvQuery; id: string }[] = [];
    (res.results as { vulns?: { id: string }[] }[]).forEach((r, i) => {
      for (const v of r.vulns ?? []) hits.push({ q: chunk[i], id: v.id });
    });
    const ids = [...new Set(hits.map((h) => h.id))].filter((id) => !osvDetailCache.has(id));
    await pool(ids, 8, async (id) => osvDetailCache.set(id, await http(`https://api.osv.dev/v1/vulns/${id}`)));
    for (const { q, id } of hits) {
      const d = osvDetailCache.get(id);
      if (d.withdrawn) continue;
      const fixed = new Set<string>();
      for (const a of d.affected ?? []) {
        if (a.package?.name && q.name && a.package.name !== q.name && !q.commit) continue;
        for (const r of a.ranges ?? []) for (const e of r.events ?? []) if (e.fixed) fixed.add(e.fixed);
      }
      vulns.push({
        id,
        aliases: d.aliases ?? [],
        severity: String(d.database_specific?.severity ?? "UNKNOWN").toUpperCase(),
        eco: q.commit ? "commit" : q.eco,
        pkg: q.name,
        version: q.version ?? q.commit?.slice(0, 7) ?? "",
        fixed: [...fixed],
        scope: q.meta.scope,
        source: q.meta.source,
        summary: d.summary ?? "",
      });
    }
  }
}

// ── npm ─────────────────────────────────────────────────────────────────────

type NpmProject = { dir: string; pkg: any; lock?: any };

function npmProjects(): NpmProject[] {
  const files = spawnSync("git", ["ls-files", "*package.json"], { cwd: root, encoding: "utf8" })
    .stdout.split("\n")
    .filter(Boolean);
  return files.map((f) => {
    const dir = dirname(f);
    const lockPath = join(root, dir, "package-lock.json");
    return {
      dir,
      pkg: JSON.parse(readFileSync(join(root, f), "utf8")),
      lock: existsSync(lockPath) ? JSON.parse(readFileSync(lockPath, "utf8")) : undefined,
    };
  });
}

const declaredDeps = (p: any) => ({
  runtime: (p.dependencies ?? {}) as Record<string, string>,
  dev: (p.devDependencies ?? {}) as Record<string, string>,
  optional: (p.optionalDependencies ?? {}) as Record<string, string>,
});

/** name@version -> runtime when any lockfile path reaching it is not dev-only. */
function lockPackages(lock: any): Map<string, { name: string; version: string; dev: boolean }> {
  const out = new Map<string, { name: string; version: string; dev: boolean }>();
  for (const [path, info] of Object.entries<any>(lock.packages ?? {})) {
    if (!path.includes("node_modules/") || !info.version || info.link) continue;
    const name = path.slice(path.lastIndexOf("node_modules/") + "node_modules/".length);
    const key = `${name}@${info.version}`;
    const dev = Boolean(info.dev);
    const prev = out.get(key);
    out.set(key, { name, version: info.version, dev: prev ? prev.dev && dev : dev });
  }
  return out;
}

async function npmView(name: string, range?: string): Promise<string | undefined> {
  const { stdout } = await run("npm", ["view", range ? `${name}@${range}` : name, "version", "--json"], { timeout: 45_000 });
  const v = JSON.parse(stdout);
  return Array.isArray(v) ? v[v.length - 1] : v;
}

async function npmScan(): Promise<void> {
  const projects = npmProjects();
  const osvQueries: OsvQuery[] = [];
  const auditVulns: Vuln[] = [];
  const registryCache = new Map<string, Promise<any>>();
  const registry = (name: string) => {
    if (!registryCache.has(name)) registryCache.set(name, http(`https://registry.npmjs.org/${name.replace("/", "%2f")}`));
    return registryCache.get(name)!;
  };

  for (const p of projects) {
    const d = declaredDeps(p.pkg);
    const n = Object.keys(d.runtime).length + Object.keys(d.dev).length + Object.keys(d.optional).length;
    inventory.push([
      `\`${p.dir}/package.json\``,
      p.pkg.name ?? "",
      p.lock ? `lockfile (${lockPackages(p.lock).size} packages)` : "no lockfile",
      `${Object.keys(d.runtime).length} runtime / ${Object.keys(d.dev).length} dev / ${Object.keys(d.optional).length} optional` +
        (p.pkg.engines?.node ? `; node ${p.pkg.engines.node}` : "") +
        (n === 0 ? "; peer-only" : ""),
    ]);
    if (n === 0) continue;
    const overrides = new Set(Object.keys(p.pkg.overrides ?? {}));
    const direct: { name: string; range: string; scope: string; current?: string }[] = [];
    for (const [scope, deps] of Object.entries(d)) {
      for (const [name, range] of Object.entries(deps)) direct.push({ name, range, scope });
    }

    let installed: Map<string, { name: string; version: string; dev: boolean }>;
    if (p.lock) {
      installed = lockPackages(p.lock);
      for (const x of direct) {
        const hit = [...installed.values()].find((v) => v.name === x.name && !v.version.includes("-x"));
        // The top-level entry is the one the project resolves; nested copies share the name.
        x.current = p.lock.packages?.[`node_modules/${x.name}`]?.version ?? hit?.version;
      }
      coverage.push(`${p.dir}: npm audit + OSV on ${installed.size} locked packages; outdated on ${direct.length} direct deps`);
      const audit = await guarded(`npm audit ${p.dir}`, async () => {
        // npm audit exits 1 when it finds issues; the JSON is still on stdout.
        const r = spawnSync("npm", ["audit", "--json"], { cwd: join(root, p.dir), encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
        const j = JSON.parse(r.stdout);
        if (j.error) throw new Error(j.error.summary ?? "npm audit failed");
        return j;
      });
      for (const v of Object.values<any>(audit?.vulnerabilities ?? {})) {
        for (const via of v.via ?? []) {
          if (typeof via === "string") continue;
          const id = String(via.url ?? "").split("/").pop() || String(via.source);
          const nodePaths: string[] = v.nodes ?? [];
          const dev = nodePaths.length > 0 && nodePaths.every((np) => p.lock.packages?.[np]?.dev);
          const fa = v.fixAvailable;
          auditVulns.push({
            id,
            aliases: [],
            severity: String(via.severity ?? v.severity).toUpperCase(),
            eco: "npm",
            pkg: via.name ?? v.name,
            version: p.lock.packages?.[nodePaths[0]]?.version ?? "",
            fixed: fa && typeof fa === "object" ? [`${fa.name}@${fa.version}${fa.isSemVerMajor ? " (major)" : ""}`] : [],
            scope: dev ? "dev-only" : "runtime",
            source: p.dir,
            summary: via.title ?? "",
          });
        }
      }
      for (const v of installed.values()) {
        osvQueries.push({ eco: "npm", name: v.name, version: v.version, meta: { source: p.dir, scope: v.dev ? "dev-only" : "runtime" } });
      }
    } else {
      installed = new Map();
      coverage.push(`${p.dir}: no lockfile; OSV + outdated on the newest version matching each declared range (npm audit needs a lockfile)`);
      await pool(direct, 6, async (x) => {
        const exact = parseVer(x.range) ? x.range : undefined;
        x.current = exact ?? (await guarded(`npm view ${x.name}@${x.range}`, () => npmView(x.name, x.range)));
        if (x.current) {
          osvQueries.push({
            eco: "npm",
            name: x.name,
            version: x.current,
            meta: { source: p.dir, scope: x.scope === "dev" ? "dev-only" : "runtime" },
          });
        }
      });
    }

    await pool(direct, 6, async (x) => {
      // `npm:real@range` aliases resolve against the real package's registry entry.
      const real = x.range.startsWith("npm:") ? x.range.slice(4, x.range.lastIndexOf("@")) : x.name;
      const doc = await guarded(`registry ${real}`, () => registry(real));
      if (!doc || !x.current) return;
      const latest: string = doc["dist-tags"]?.latest;
      const b = bump(x.current, latest);
      const t = doc.time?.[latest];
      const ageStale = doc.time?.modified && Date.now() - Date.parse(doc.time.modified) > STALE_MS;
      const deprecated = doc.versions?.[latest]?.deprecated;
      const notes: string[] = [];
      if (overrides.has(x.name)) notes.push("also pinned in `overrides`");
      if (/^[~^]/.test(x.range) === false && parseVer(x.range)) notes.push("exact pin (repo convention)");
      if (deprecated) notes.push(`deprecated: ${String(deprecated).slice(0, 80)}`);
      if (x.range === "*") return;
      if (b === "current" || b === "ahead" || b === "unknown") return;
      outdated.push({
        source: `${p.dir} (${x.scope})`,
        name: x.name,
        current: x.current,
        latest,
        bump: b,
        scope: x.scope,
        note: notes.join("; "),
        stale: ageStale ? `no registry change since ${doc.time.modified.slice(0, 10)}` : t ? "" : "",
      });
    });
  }

  await guarded("OSV npm", () => osvScan(osvQueries));
  // npm audit findings OSV did not report (same id) are kept; they carry fixAvailable data OSV lacks.
  const osvIds = new Set(vulns.map((v) => `${v.source}:${v.id}:${v.pkg}`));
  for (const a of auditVulns) {
    const same = vulns.find((v) => v.source === a.source && (v.id === a.id || v.aliases.includes(a.id)) && v.pkg === a.pkg);
    if (same) {
      if (a.fixed.length) same.fixed = [...new Set([...same.fixed, ...a.fixed])];
      if (same.severity === "UNKNOWN") same.severity = a.severity;
    } else if (!osvIds.has(`${a.source}:${a.id}:${a.pkg}`)) vulns.push(a);
  }
}

// ── Swift packages ──────────────────────────────────────────────────────────

export type SwiftDecl = { name: string; url: string; rule: string; value: string; comment: string };

/** Entries under `packages:` in project.yml, with the comment block nearest above each. */
export function parseProjectYmlPackages(text: string): SwiftDecl[] {
  const out: SwiftDecl[] = [];
  let inPackages = false;
  let comment: string[] = [];
  let cur: SwiftDecl | undefined;
  let lastBlock = "";
  for (const line of text.split("\n")) {
    if (/^packages:/.test(line)) {
      inPackages = true;
      continue;
    }
    if (!inPackages) continue;
    if (/^\S/.test(line)) break;
    const c = /^\s+#\s?(.*)$/.exec(line);
    if (c) {
      comment.push(c[1]);
      continue;
    }
    const name = /^ {2}([\w.-]+):\s*$/.exec(line);
    if (name) {
      if (comment.length) lastBlock = comment.join(" ");
      comment = [];
      cur = { name: name[1], url: "", rule: "", value: "", comment: lastBlock };
      out.push(cur);
      continue;
    }
    const kv = /^ {4}(url|from|exactVersion|revision|branch|upToNextMajorVersion):\s*"?([^"\s]+)"?/.exec(line);
    if (kv && cur) {
      if (kv[1] === "url") cur.url = kv[2];
      else {
        cur.rule = kv[1];
        cur.value = kv[2];
      }
    }
  }
  return out;
}

const repoOf = (url: string) => /github\.com[/:]([^/]+\/[^/.]+?)(?:\.git)?\/?$/.exec(url)?.[1];

async function latestTag(repo: string): Promise<{ tag: string; ver: number[] } | undefined> {
  const tags: { name: string }[] = await gh(`repos/${repo}/tags?per_page=100`);
  const vers = tags
    .map((t) => ({ tag: t.name, ver: parseVer(t.name) }))
    .filter((t): t is { tag: string; ver: number[] } => Boolean(t.ver) && /^v?\d+\.\d+(\.\d+)?$/.test(t.tag));
  vers.sort((a, b) => cmpVer(b.ver, a.ver));
  return vers[0];
}

async function repoHealth(repo: string): Promise<string> {
  const r = await gh(`repos/${repo}`);
  const notes: string[] = [];
  if (r.archived) notes.push("ARCHIVED upstream");
  if (r.pushed_at && Date.now() - Date.parse(r.pushed_at) > STALE_MS) notes.push(`stale: last push ${r.pushed_at.slice(0, 10)}`);
  return notes.join("; ");
}

async function swiftScan(): Promise<void> {
  const base = "clients/apple";
  const yml = readFileSync(join(root, base, "project.yml"), "utf8");
  const decls = parseProjectYmlPackages(yml);
  const resolvedPath = join(root, base, "Oppi.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved");
  const resolved = JSON.parse(readFileSync(resolvedPath, "utf8")) as {
    pins: { identity: string; location: string; state: { version?: string; revision: string; branch?: string } }[];
  };
  const declByUrl = new Map(decls.map((d) => [repoOf(d.url) ?? d.url, d]));
  inventory.push([
    `\`${base}/project.yml\` + \`Package.resolved\``,
    "Swift packages",
    `${decls.length} declared, ${resolved.pins.length} resolved (incl. transitive)`,
    "exact/revision pins listed in Outdated",
  ]);

  const queries: OsvQuery[] = resolved.pins.map((p) => {
    const name = p.location.replace(/^https:\/\//, "").replace(/\.git$/, "");
    return p.state.version
      ? { eco: "SwiftURL", name, version: p.state.version, meta: { source: "swift", scope: "runtime" } }
      : { eco: "SwiftURL", name, commit: p.state.revision, meta: { source: "swift", scope: "runtime" } };
  });
  coverage.push(`swift: OSV (SwiftURL) on ${queries.length} resolved pins (commit query for revision pins); latest tag + repo health via gh for each`);
  await guarded("OSV SwiftURL", () => osvScan(queries));

  await pool(resolved.pins, 6, async (p) => {
    const repo = repoOf(p.location);
    if (!repo) return gaps.push(`swift ${p.identity}: not a GitHub URL (${p.location}); no latest-version lookup`);
    const decl = declByUrl.get(repo);
    const direct = Boolean(decl);
    const health = (await guarded(`gh repo ${repo}`, () => repoHealth(repo))) ?? "";
    const forkBase = p.state.version ? forkBaseTag(p.state.version) : undefined;
    if (forkBase) {
      // Fork pinned as `<upstream-tag>-oppi.N`: compare its base tag with the fork's GitHub parent.
      const parent = await guarded(`gh parent ${repo}`, async () => (await gh(`repos/${repo}`)).parent?.full_name as string | undefined);
      if (!parent) return gaps.push(`swift fork ${p.identity}: no GitHub parent repo; cannot find upstream`);
      const lt = await guarded(`gh tags ${parent}`, () => latestTag(parent));
      if (!lt) return gaps.push(`swift fork ${p.identity}: no release tag found on upstream ${parent}`);
      forks.push({ name: p.identity, pinned: p.state.version!, upstream: parent, upstreamLatest: lt.tag, status: forkStatus(forkBase, lt.tag) });
      return;
    }
    const pinned = decl && decl.rule !== "from";
    const note = [
      direct ? `direct (${decl!.rule} ${decl!.value.slice(0, 12)})` : "transitive",
      pinned && decl!.comment ? `pin reason: ${decl!.comment.slice(0, 200)}` : pinned ? "exact pin, no reason in project.yml" : "",
    ]
      .filter(Boolean)
      .join("; ");
    if (p.state.version) {
      const lt = await guarded(`gh tags ${repo}`, () => latestTag(repo));
      if (!lt) return;
      const b = bump(p.state.version, lt.tag);
      if (b !== "current" && b !== "ahead" && b !== "unknown") {
        outdated.push({ source: "swift", name: p.identity, current: p.state.version, latest: lt.tag.replace(/^v/, ""), bump: b, scope: direct ? "direct" : "transitive", note, stale: health });
      } else if (health) {
        outdated.push({ source: "swift", name: p.identity, current: p.state.version, latest: lt.tag.replace(/^v/, ""), bump: "current", scope: direct ? "direct" : "transitive", note, stale: health });
      }
    } else {
      // Revision pin: report how many commits the default branch is ahead.
      const ahead = await guarded(`gh compare ${repo}`, async () => {
        const c = await gh(`repos/${repo}/compare/${p.state.revision}...HEAD`);
        return `${c.ahead_by} commits behind default branch`;
      });
      outdated.push({ source: "swift", name: p.identity, current: p.state.revision.slice(0, 7), latest: "HEAD", bump: "unknown", scope: direct ? "direct" : "transitive", note: `${note}; ${ahead ?? ""}`, stale: health });
    }
  });
}

// ── vendored builds, toolchains, workflows ─────────────────────────────────

function shVar(text: string, name: string): string | undefined {
  return new RegExp(`^${name}="([^"]+)"`, "m").exec(text)?.[1];
}

type GoReq = { name: string; version: string; override?: boolean };

/** `module@version` entries of the GO_MODULE_FIXES array in build-tailscalekit.sh (the build's `go get` overrides). */
export function parseGoModuleFixes(script: string): { name: string; version: string }[] {
  const body = /^GO_MODULE_FIXES=\(([^)]*)\)/m.exec(script)?.[1] ?? "";
  return body
    .split("\n")
    .map((l) => l.replace(/#.*/, "").trim())
    .filter(Boolean)
    .map((l) => /^([\w./~-]+)@v([\w.+-]+)$/.exec(l))
    .filter((m): m is RegExpExecArray => !!m)
    .map((m) => ({ name: m[1], version: m[2] }));
}

/** Versions the build resolves: declared requirements with each override replacing (or adding) its module. */
export function applyGoModuleFixes(reqs: GoReq[], fixes: { name: string; version: string }[]): GoReq[] {
  const out: GoReq[] = reqs.map((r) => ({ ...r }));
  for (const f of fixes) {
    const hit = out.find((r) => r.name === f.name);
    if (hit) Object.assign(hit, { version: f.version, override: true });
    else out.push({ ...f, override: true });
  }
  return out;
}

async function vendorScan(): Promise<void> {
  const scripts = join(root, "clients/apple/scripts");
  const ghostty = readFileSync(join(scripts, "build-ghostty-vt.sh"), "utf8");
  const ts = readFileSync(join(scripts, "build-tailscalekit.sh"), "utf8");
  const ghosttyCommit = shVar(ghostty, "COMMIT")!;
  const zig = shVar(ghostty, "ZIG_VERSION")!;
  const tsCommit = shVar(ts, "LIBTAILSCALE_COMMIT")!;
  const tsComment = /# [0-9a-f]{7} = (libtailscale [\d.]+ \(tailscale\.com v[\d.]+\))/.exec(ts)?.[1] ?? "";
  inventory.push(
    ["`clients/apple/Vendor/GhosttyVt` (gitignored, built by `scripts/build-ghostty-vt.sh`)", "ghostty-org/ghostty", `commit ${ghosttyCommit.slice(0, 7)}`, `built with Zig ${zig} (downloaded, SHA-256 checked)`],
    ["`clients/apple/Vendor/TailscaleKit` (gitignored, built by `scripts/build-tailscalekit.sh`)", "tailscale/libtailscale", `commit ${tsCommit.slice(0, 7)}`, tsComment],
  );

  // GhosttyVt
  await guarded("ghostty health", async () => {
    const c = await gh(`repos/ghostty-org/ghostty/compare/${ghosttyCommit}...HEAD`);
    outdated.push({ source: "vendor", name: "GhosttyVt (ghostty)", current: ghosttyCommit.slice(0, 7), latest: "HEAD", bump: "unknown", scope: "vendored", note: `commit pin; ${c.ahead_by} commits behind default branch`, stale: await repoHealth("ghostty-org/ghostty") });
  });
  // TailscaleKit: latest libtailscale tag, plus the Go modules it builds from.
  await guarded("libtailscale tags", async () => {
    const lt = await latestTag("tailscale/libtailscale");
    const cur = /libtailscale ([\d.]+)/.exec(tsComment)?.[1];
    if (lt && cur && bump(cur, lt.tag) !== "current") {
      outdated.push({ source: "vendor", name: "TailscaleKit (libtailscale)", current: cur, latest: lt.tag.replace(/^v/, ""), bump: bump(cur, lt.tag), scope: "vendored", note: "commit pin, bump deliberately (see script)", stale: "" });
    }
  });
  await guarded("libtailscale go.mod", async () => {
    const f = await gh(`repos/tailscale/libtailscale/contents/go.mod?ref=${tsCommit}`);
    const mod = Buffer.from(f.content, "base64").toString("utf8");
    const declared = [...mod.matchAll(/^\s*([\w./~-]+)\s+v([\w.+-]+)(?:\s|$)/gm)].map((m) => ({ name: m[1], version: m[2] })).filter((r) => r.name.includes("."));
    const fixes = parseGoModuleFixes(ts);
    const reqs = applyGoModuleFixes(declared, fixes);
    const changed = reqs.filter((r) => r.override).map((r) => `${r.name} ${declared.find((d) => d.name === r.name)?.version ?? "(not declared)"} → ${r.version}`);
    coverage.push(`TailscaleKit: OSV (Go) on ${reqs.length} go.mod requirements of libtailscale@${tsCommit.slice(0, 7)} (as declared; MVS may select higher), with ${fixes.length} \`go get\` overrides from build-tailscalekit.sh GO_MODULE_FIXES applied: ${changed.join("; ") || "none"}`);
    for (const r of reqs.filter((r) => r.override)) inventory.push(["`build-tailscalekit.sh` GO_MODULE_FIXES", `Go module override (${r.name})`, `v${r.version}`, "version from override, not libtailscale go.mod"]);
    await osvScan(reqs.map((r) => ({ eco: "Go", name: r.name, version: r.version, meta: { source: "vendor:TailscaleKit", scope: "runtime" as const } })));
  });
  await guarded("OSV ghostty commit", () =>
    osvScan([{ eco: "GIT", name: "ghostty", commit: ghosttyCommit, meta: { source: "vendor:GhosttyVt", scope: "runtime" } }]),
  );
}

async function toolchainScan(): Promise<void> {
  const notes: string[] = [];
  const bunSrc = readFileSync(join(root, "clients/apple/scripts/bundle-mac-server-bun.ts"), "utf8");
  const pinnedBun = /PINNED_BUN_VERSION = "([\d.]+)"/.exec(bunSrc)?.[1];
  const goVer = /go(\d+\.\d+\.\d+)\.darwin/.exec(readFileSync(join(root, "clients/apple/ci_scripts/ci_post_clone.sh"), "utf8"))?.[1];
  const xcode = readFileSync(join(root, "clients/apple/scripts/xcode-toolchain.txt"), "utf8").trim();
  const ymlXcode = /xcodeVersion:\s*"([\d.]+)"/.exec(readFileSync(join(root, "clients/apple/project.yml"), "utf8"))?.[1];
  const wf = readFileSync(join(root, ".github/workflows/hygiene.yml"), "utf8");
  const gitleaks = /GITLEAKS_VERSION:\s*([\d.]+)/.exec(wf)?.[1];
  const zig = shVar(readFileSync(join(root, "clients/apple/scripts/build-ghostty-vt.sh"), "utf8"), "ZIG_VERSION");
  const dockerNode = /^FROM node:(\S+)/m.exec(readFileSync(join(root, "server/Dockerfile"), "utf8"))?.[1];
  const installNode = /OPPI_NODE_DIST=\S*latest-(v\d+)\.x/.exec(readFileSync(join(root, "install.sh"), "utf8"))?.[1];

  inventory.push(
    ["`clients/apple/scripts/bundle-mac-server-bun.ts` + `server/.bun-version`", "Bun (bundled in Mac app, zip SHA-256 pinned)", `v${pinnedBun}`, "downloaded from GitHub releases at build time"],
    ["`clients/apple/ci_scripts/ci_post_clone.sh`", "Go toolchain (Xcode Cloud, downloads go.dev tarball)", `go${goVer}`, ""],
    ["`clients/apple/scripts/build-ghostty-vt.sh`", "Zig (downloaded from ziglang.org, SHA-256 checked)", zig ?? "", ""],
    ["`clients/apple/scripts/xcode-toolchain.txt` + `project.yml`", "Xcode", `${xcode.split("/").pop()}; project.yml xcodeVersion ${ymlXcode}`, "SWIFT_VERSION 6.0"],
    ["`server/Dockerfile`", "Node base image", `node:${dockerNode} (floating tag)`, "also apt packages, unpinned"],
    ["`install.sh`", "Node for installs", `latest-${installNode}.x (floating)`, "downloaded from nodejs.org"],
    ["`.github/workflows/hygiene.yml`", "gitleaks binary", gitleaks ?? "", "via gitleaks-action"],
    ["`server/package.json`, `relay/package.json`", "Node engines", ">=22.19.0", "CI Node/Bun versions: none pinned in workflows"],
  );

  await guarded("bun releases", async () => {
    const release: { tag_name: string } = await http("https://api.github.com/repos/oven-sh/bun/releases/latest");
    const latest = release.tag_name.replace(/^bun-v/, "");
    if (pinnedBun && bump(pinnedBun, latest) !== "current" && bump(pinnedBun, latest) !== "ahead") {
      outdated.push({ source: "toolchain", name: "Bun (bundled in Mac app)", current: pinnedBun, latest, bump: bump(pinnedBun, latest), scope: "runtime (Mac app)", note: "update server/.bun-version, PINNED_BUN_VERSION, and PINNED_BUN_SHA256 together", stale: "" });
    }
  });
  await guarded("endoflife node", async () => {
    const cycles: { cycle: string; eol: string | boolean; lts: string | boolean }[] = await http("https://endoflife.date/api/nodejs.json");
    for (const [label, major] of [["server Docker base", dockerNode?.split("-")[0]], ["installer Node", installNode?.slice(1)], ["engines floor", "22"]] as const) {
      const c = cycles.find((x) => x.cycle === major);
      if (c && c.eol !== false && Date.parse(String(c.eol)) < Date.now() + 90 * 86400_000) {
        notes.push(`Node ${major} (${label}) end-of-life ${c.eol}`);
      }
    }
  });
  await guarded("go.dev releases", async () => {
    const rel: { version: string; stable: boolean }[] = await http("https://go.dev/dl/?mode=json");
    const latest = rel.find((r) => r.stable)?.version.slice(2);
    if (latest && goVer && bump(goVer, latest) !== "current" && bump(goVer, latest) !== "ahead") {
      outdated.push({ source: "toolchain", name: "Go (Xcode Cloud build)", current: goVer, latest, bump: bump(goVer, latest), scope: "build-time", note: "libtailscale needs go >= 1.27.1", stale: "" });
    }
    await osvScan([{ eco: "Go", name: "stdlib", version: goVer!, meta: { source: "toolchain:Go", scope: "runtime" } }]);
    coverage.push(`Go stdlib ${goVer}: OSV (stdlib advisories apply to the TailscaleKit binary)`);
  });
  await guarded("zig releases", async () => {
    const idx = await http("https://ziglang.org/download/index.json");
    const stable = Object.keys(idx).filter((k) => parseVer(k)).sort((a, b) => cmpVer(parseVer(b)!, parseVer(a)!))[0];
    if (stable && zig && bump(zig, stable) !== "current" && bump(zig, stable) !== "ahead") {
      outdated.push({ source: "toolchain", name: "Zig (GhosttyVt build)", current: zig, latest: stable, bump: bump(zig, stable), scope: "build-time", note: "changing it changes BUILD_ID and forces a rebuild; Ghostty tracks a specific Zig", stale: "" });
    }
  });
  await guarded("gitleaks release", async () => {
    const r = await gh("repos/gitleaks/gitleaks/releases/latest");
    const latest = String(r.tag_name).replace(/^v/, "");
    if (gitleaks && bump(gitleaks, latest) !== "current") outdated.push({ source: "toolchain", name: "gitleaks (CI)", current: gitleaks, latest, bump: bump(gitleaks, latest), scope: "CI", note: "GITLEAKS_VERSION in hygiene.yml", stale: "" });
  });
  notes.push(`Xcode ${xcode.split("/").pop()?.replace(/\.app$/, "")}: pinned by the repo; this script cannot see the newest Xcode (check developer.apple.com/news/releases).`);
  toolchainNotes.push(...notes);
}
const toolchainNotes: string[] = [];
type ForkRow = { name: string; pinned: string; upstream: string; upstreamLatest: string; status: "rebase due" | "up to date" | "unknown" };
const forks: ForkRow[] = [];

async function actionsScan(): Promise<void> {
  const dir = join(root, ".github/workflows");
  const files = spawnSync("git", ["ls-files", ".github/workflows"], { cwd: root, encoding: "utf8" }).stdout.split("\n").filter(Boolean);
  const uses = new Map<string, { sha: string; tag: string; file: string }>();
  for (const f of files) {
    for (const m of readFileSync(join(root, f), "utf8").matchAll(/uses:\s*([\w.-]+\/[\w.-]+)(?:\/[\w./-]+)?@(\S+)(?:\s+#\s*(\S+))?/g)) {
      uses.set(m[1], { sha: m[2], tag: m[3] ?? m[2], file: f });
    }
  }
  void dir;
  coverage.push(`GitHub Actions: ${uses.size} actions, latest release via gh`);
  for (const [repo, u] of uses) {
    inventory.push([`\`${u.file}\``, `action ${repo}`, `${u.tag} (${u.sha.length === 40 ? "SHA-pinned" : "tag-pinned"})`, ""]);
    await guarded(`action ${repo}`, async () => {
      const rel = await gh(`repos/${repo}/releases/latest`);
      const health = await repoHealth(repo);
      const b = bump(u.tag, rel.tag_name);
      if (b !== "current" && b !== "ahead") outdated.push({ source: "actions", name: repo, current: u.tag, latest: rel.tag_name, bump: b, scope: "CI", note: u.sha.length === 40 ? "SHA-pinned: update SHA and comment together" : "", stale: health });
      else if (health) outdated.push({ source: "actions", name: repo, current: u.tag, latest: rel.tag_name, bump: "current", scope: "CI", note: "", stale: health });
    });
  }
}

// ── report ──────────────────────────────────────────────────────────────────

const cell = (s: string) => s.replace(/\|/g, "\\|").replace(/\n/g, " ");
const table = (head: string[], rows: string[][]) =>
  rows.length ? [`| ${head.join(" | ")} |`, `| ${head.map(() => "---").join(" | ")} |`, ...rows.map((r) => `| ${r.map(cell).join(" | ")} |`)].join("\n") : "_none_";

function buildActions(): Action[] {
  const out: Action[] = [];
  const grouped = new Map<string, Vuln[]>();
  for (const v of vulns) {
    const k = `${v.source}|${v.pkg}@${v.version}`;
    grouped.set(k, [...(grouped.get(k) ?? []), v]);
  }
  for (const [k, vs] of [...grouped].sort((a, b) => Math.max(...b[1].map((v) => sevOf(v.severity))) - Math.max(...a[1].map((v) => sevOf(v.severity))) || (a[1][0].scope === "runtime" ? -1 : 1))) {
    const top = vs.reduce((a, b) => (sevOf(b.severity) > sevOf(a.severity) ? b : a));
    const fixed = [...new Set(vs.flatMap((v) => v.fixed))].join(", ") || "no fix listed";
    out.push({ rank: 1, text: `**${top.severity} ${top.scope}**: ${k.split("|")[1]} in ${top.source} (${vs.map((v) => v.id).join(", ")}) → ${fixed}` });
  }
  const safe = outdated.filter((o) => (o.bump === "patch" || o.bump === "minor") && !/pin reason|overrides|deprecated/.test(o.note));
  const zeroX = (o: OutdatedRow) => o.bump === "minor" && parseVer(o.current)?.[0] === 0;
  const batch = [...new Set(safe.filter((o) => !zeroX(o) && !/security releases/.test(o.note)).map((o) => `${o.name} ${o.current}→${o.latest}`))];
  if (batch.length) out.push({ rank: 2, text: `Batch ${batch.length} patch/minor bumps: ${batch.join(", ")}` });
  for (const o of outdated.filter((x) => /security releases/.test(x.note))) out.push({ rank: 1, text: `**Toolchain security releases**: ${o.name} ${o.current}→${o.latest} — ${o.note}` });
  for (const o of outdated) {
    if (o.bump === "major") out.push({ rank: 3, text: `Decide major bump: ${o.name} ${o.current}→${o.latest} (${o.source})${o.note ? ` — ${o.note}` : ""}` });
    else if (safe.includes(o) && zeroX(o)) out.push({ rank: 3, text: `Decide 0.x minor (can break): ${o.name} ${o.current}→${o.latest} (${o.source})` });
    else if ((o.bump === "patch" || o.bump === "minor" || o.bump === "unknown") && /pin reason|overrides/.test(o.note))
      out.push({ rank: 3, text: `Pinned on purpose, revisit: ${o.name} ${o.current}→${o.latest} (${o.source}) — ${o.note.slice(0, 160)}` });
    if (o.stale) out.push({ rank: 3, text: `Upstream health: ${o.name} — ${o.stale}` });
  }
  for (const f of forks) {
    const what = `${f.name} ${f.pinned} (upstream ${f.upstream} latest ${f.upstreamLatest})`;
    out.push({ rank: 3, text: f.status === "rebase due" ? `Fork rebase due: ${what}` : f.status === "up to date" ? `Fork up to date: ${what}` : `Fork not comparable (non-numeric tag): ${what}` });
  }
  for (const n of toolchainNotes) out.push({ rank: 3, text: n });
  return out;
}

function report(): string {
  const date = new Date().toISOString().slice(0, 10);
  const sorted = [...vulns].sort((a, b) => sevOf(b.severity) - sevOf(a.severity) || (a.scope === "runtime" ? -1 : 1));
  const actions = buildActions();
  const order: Record<Bump, number> = { major: 0, minor: 1, patch: 2, unknown: 3, current: 4, ahead: 5 };
  const bySource = [...outdated].sort((a, b) => a.source.localeCompare(b.source) || order[a.bump] - order[b.bump] || a.name.localeCompare(b.name));
  const sec = (title: string, body: string) => `## ${title}\n\n${body}\n`;
  const rank = (r: number, title: string) => {
    const items = actions.filter((a) => a.rank === r);
    return items.length ? `**${title}**\n\n${items.map((a, i) => `${i + 1}. ${a.text}`).join("\n")}` : `**${title}**\n\n_nothing_`;
  };
  return [
    `# Oppi dependency report — ${date}\n`,
    sec("Do this week", [rank(1, "1. Security fixes"), rank(2, "2. Safe patch/minor bumps to batch"), rank(3, "3. Needs a decision (majors, pinned items, upstream health, toolchains)")].join("\n\n")),
    sec(
      `Vulnerabilities (${vulns.length})`,
      "Matched by version, not reachability: a Go stdlib or x/net advisory may sit in code TailscaleKit never calls. Severity UNKNOWN means the advisory carries no GHSA-style rating (all Go advisories).\n\n" +
      table(["Severity", "Scope", "Package", "Version", "Fixed in", "Advisory", "Source", "Summary"], sorted.map((v) => [v.severity, v.scope, v.pkg, v.version, v.fixed.join(", ") || "—", [v.id, ...v.aliases.filter((a) => a.startsWith("CVE")).slice(0, 1)].join(" / "), v.source, v.summary.slice(0, 90)])),
    ),
    sec(
      `Outdated and upstream health (${outdated.length})`,
      table(["Source", "Package", "Current", "Latest", "Bump", "Notes", "Upstream"], bySource.map((o) => [o.source, o.name, o.current, o.latest, o.bump === "current" ? "—" : o.bump, o.note, o.stale])),
    ),
    sec("Inventory", table(["Where", "What", "Version / state", "Notes"], inventory)),
    sec("Coverage", coverage.map((c) => `- ${c}`).join("\n")),
    sec("Gaps", gaps.length ? gaps.map((g) => `- ${g}`).join("\n") : "_none in this run_"),
  ].join("\n");
}

async function main() {
  const outIdx = process.argv.indexOf("--out");
  const out = outIdx > 0 ? process.argv[outIdx + 1] : undefined;
  await guarded("npm", npmScan);
  await guarded("swift", swiftScan);
  await guarded("vendor", vendorScan);
  await guarded("toolchains", toolchainScan);
  await guarded("actions", actionsScan);
  // Duplicate advisories (same package, same id, from the same source) collapse to one row.
  const seen = new Set<string>();
  vulns.splice(0, vulns.length, ...vulns.filter((v) => {
    const k = `${v.source}|${v.pkg}@${v.version}|${v.id}`;
    return seen.has(k) ? false : (seen.add(k), true);
  }));
  const text = report();
  if (out) writeFileSync(out, text);
  process.stdout.write(text);
}

if (import.meta.main) await main();
