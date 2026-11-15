/**
 * `godot_export`: builds a discovered game with the host's Godot, outside the Godot pane.
 *
 * - Godot is `godot` on the server's PATH. Its export templates must match its version exactly;
 *   they live where the Godot editor keeps them (`templatesRoot`). They are installed only when
 *   a call asks (`installTemplates`): the official `.tpz` from the godot-builds GitHub release of
 *   that version, checked against the release's `SHA512-SUMS.txt`, unpacked into
 *   `<root>/<version>/`. Never a silent download.
 * - The project is never changed. Each export clones the project folder (APFS/reflink clones
 *   where the volume has them) into a temp folder without `build/`, `.git` and
 *   `export_presets.cfg`, writes a one-preset `export_presets.cfg` there, and exports that copy.
 *   Leaving `build/` out keeps earlier builds out of the new one.
 * - Web is the single-threaded variant (`variant/thread_support=false`): no SharedArrayBuffer,
 *   so it needs no cross-origin isolation headers and no secure context, and plays over the
 *   server's plain-HTTP or HTTPS address alike. The finished folder goes to the server
 *   (`OppiGodotHost.adoptWebExport`), which serves it to the owner and paired devices.
 * - Desktop builds replace `build/<target>/<file>` in the project folder. `build/` holds them in
 *   a subfolder so the pane, which plays the newest `build/*.pck`, never picks one up.
 */
import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { createWriteStream } from "node:fs";
import * as fs from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { basename, join, relative } from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import type { ReadableStream as WebReadableStream } from "node:stream/web";

import type { OppiGodotHost } from "oppi/v1";
import { templatesMissingError, type GodotExportTarget } from "./contract.js";

const GODOT = "godot";
const RELEASES = "https://github.com/godotengine/godot-builds/releases/download";
const EXPORT_TIMEOUT_MS = 15 * 60_000;
const OUTPUT_TAIL_CHARS = 4_000;

/** What an export writes, and the template it needs (`<root>/<version>/<template>`). */
const TARGETS: Record<
  GodotExportTarget,
  { platform: string; template: string; label: string; file: (slug: string) => string }
> = {
  web: {
    platform: "Web",
    template: "web_nothreads_release.zip",
    label: "the web",
    file: () => "index.html",
  },
  macos: {
    platform: "macOS",
    template: "macos.zip",
    label: "macOS",
    file: (slug) => `${slug}.zip`,
  },
  linux: {
    platform: "Linux",
    template: "linux_release.x86_64",
    label: "Linux",
    file: (slug) => `${slug}.x86_64`,
  },
  windows: {
    platform: "Windows Desktop",
    template: "windows_release_x86_64.exe",
    label: "Windows",
    file: (slug) => `${slug}.exe`,
  },
};

export interface GodotExportProgress {
  (line: string): void;
}

export type GodotExportOutcome = { ok: true; text: string } | { ok: false; error: string };

/** Where the Godot editor keeps export templates on this OS. */
export function templatesRoot(): string {
  if (process.platform === "darwin")
    return join(homedir(), "Library", "Application Support", "Godot", "export_templates");
  if (process.platform === "win32")
    return join(
      process.env.APPDATA ?? join(homedir(), "AppData", "Roaming"),
      "Godot",
      "export_templates",
    );
  const data = process.env.XDG_DATA_HOME || join(homedir(), ".local", "share");
  return join(data, "godot", "export_templates");
}

/** The engine's version as its templates folder and release name spell it. */
export interface GodotVersion {
  /** `4.7.2.stable` (or `4.7.2.stable.mono`): the templates folder and `version.txt`. */
  folder: string;
  /** `4.7.2-stable`: the release tag. */
  tag: string;
  /** `Godot_v4.7.2-stable_export_templates.tpz`. */
  archive: string;
}

/** `4.7.2.stable.official.ed1daf0bf` → its folder, tag and template archive; else undefined. */
export function parseGodotVersion(line: string): GodotVersion | undefined {
  const parts = line.trim().split(".");
  const status = parts.findIndex((part) => !/^\d+$/.test(part));
  if (status < 2 || status > 3) return undefined;
  const numbers = parts.slice(0, status).join(".");
  const name = parts[status] ?? "";
  if (!/^(stable|rc\d+|beta\d+|alpha\d+|dev\d+)$/.test(name)) return undefined;
  const mono = parts.slice(status + 1).includes("mono");
  const tag = `${numbers}-${name}`;
  return {
    folder: `${numbers}.${name}${mono ? ".mono" : ""}`,
    tag,
    archive: `Godot_v${tag}${mono ? "_mono" : ""}_export_templates.tpz`,
  };
}

interface Run {
  code: number | null;
  output: string;
  spawnError?: string;
}

function run(
  command: string,
  args: string[],
  options: { signal?: AbortSignal; timeoutMs: number },
): Promise<Run> {
  return new Promise((resolve) => {
    let output = "";
    const child = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"],
      ...(options.signal ? { signal: options.signal } : {}),
      timeout: options.timeoutMs,
    });
    const keep = (chunk: Buffer): void => {
      output = (output + chunk.toString("utf8")).slice(-OUTPUT_TAIL_CHARS);
    };
    child.stdout.on("data", keep);
    child.stderr.on("data", keep);
    child.on("error", (error: NodeJS.ErrnoException) =>
      resolve({ code: null, output, spawnError: error.code ?? error.message }),
    );
    child.on("close", (code) => resolve({ code, output }));
  });
}

async function exists(path: string): Promise<boolean> {
  try {
    await fs.stat(path);
    return true;
  } catch {
    return false;
  }
}

const sizeOf = (bytes: number): string =>
  bytes >= 1024 * 1024
    ? `${(bytes / (1024 * 1024)).toFixed(1)} MB`
    : `${Math.ceil(bytes / 1024)} KB`;

async function folderSize(folder: string): Promise<number> {
  let total = 0;
  for (const name of await fs.readdir(folder)) total += (await fs.stat(join(folder, name))).size;
  return total;
}

/** One install per templates folder at a time; a second caller waits for the first. */
const installing = new Map<string, Promise<void>>();

/**
 * Download the official templates for `version` and unpack them into `<root>/<folder>/`.
 * Throws with the reason; leaves nothing behind on failure.
 */
export function installTemplates(
  version: GodotVersion,
  root: string,
  progress: GodotExportProgress,
  signal?: AbortSignal,
): Promise<void> {
  const target = join(root, version.folder);
  const running = installing.get(target);
  if (running) return running;
  const job = downloadAndUnpack(version, root, progress, signal).finally(() =>
    installing.delete(target),
  );
  installing.set(target, job);
  return job;
}

async function downloadAndUnpack(
  version: GodotVersion,
  root: string,
  progress: GodotExportProgress,
  signal?: AbortSignal,
): Promise<void> {
  const base = `${RELEASES}/${version.tag}`;
  const sums = await fetch(`${base}/SHA512-SUMS.txt`, signal ? { signal } : {});
  if (!sums.ok) throw new Error(`No SHA512-SUMS.txt for Godot ${version.tag} (${sums.status})`);
  const expected = (await sums.text())
    .split("\n")
    .map((line) => line.trim().split(/\s+/))
    .find(([, name]) => name === version.archive)?.[0];
  if (!expected || !/^[0-9a-f]{128}$/.test(expected))
    throw new Error(`The ${version.tag} release lists no checksum for ${version.archive}`);

  await fs.mkdir(root, { recursive: true });
  const work = join(root, `.oppi-${version.folder}-${randomUUID()}`);
  await fs.mkdir(work);
  try {
    const archive = join(work, version.archive);
    const response = await fetch(`${base}/${version.archive}`, signal ? { signal } : {});
    if (!response.ok || !response.body)
      throw new Error(`Downloading ${version.archive} failed (${response.status})`);
    const total = Number(response.headers.get("content-length")) || 0;
    progress(`Downloading ${version.archive}${total ? ` (${sizeOf(total)})` : ""}…`);
    const digest = createHash("sha512");
    let received = 0;
    let reported = 0;
    await pipeline(
      Readable.fromWeb(response.body as WebReadableStream<Uint8Array>),
      async function* (source: AsyncIterable<Buffer>) {
        for await (const chunk of source) {
          digest.update(chunk);
          received += chunk.length;
          const percent = total ? Math.floor((received / total) * 10) * 10 : 0;
          if (percent > reported) {
            reported = percent;
            progress(`Templates: ${percent}% (${sizeOf(received)})`);
          }
          yield chunk;
        }
      },
      createWriteStream(archive),
      ...(signal ? [{ signal }] : []),
    );
    if (digest.digest("hex") !== expected)
      throw new Error(`${version.archive} does not match its published SHA-512; not installed`);
    progress("Checksum verified. Unpacking…");
    const unpacked = join(work, "unpacked");
    const unzip = await run("unzip", ["-q", archive, "-d", unpacked], {
      timeoutMs: 10 * 60_000,
      ...(signal ? { signal } : {}),
    });
    if (unzip.code !== 0)
      throw new Error(`Unpacking the templates failed: ${unzip.spawnError ?? unzip.output.trim()}`);
    const templates = join(unpacked, "templates");
    const stamped = (await fs.readFile(join(templates, "version.txt"), "utf8")).trim();
    if (stamped !== version.folder)
      throw new Error(`The archive holds templates for ${stamped}, not ${version.folder}`);
    await fs.rename(templates, join(root, version.folder));
    progress(`Installed Godot ${version.folder} export templates in ${root}.`);
  } finally {
    await fs.rm(work, { recursive: true, force: true });
  }
}

// eslint-disable-next-line no-control-regex
const ANSI = /\u001b\[[0-9;]*m/g;
const ETC2_ASTC = "textures/vram_compression/import_etc2_astc=true";

/** `project.godot` with ETC2/ASTC texture import on, in its `[rendering]` section. */
export function withEtc2Astc(settings: string): string {
  const lines = settings
    .split("\n")
    .filter((line) => !line.startsWith("textures/vram_compression/import_etc2_astc="));
  const section = lines.findIndex((line) => line.trim() === "[rendering]");
  if (section < 0) return `${lines.join("\n").trimEnd()}\n\n[rendering]\n\n${ETC2_ASTC}\n`;
  lines.splice(section + 1, 0, "", ETC2_ASTC);
  return lines.join("\n");
}

function slugOf(dir: string): string {
  return (
    basename(dir)
      .replace(/[^A-Za-z0-9._-]+/g, "-")
      .replace(/^[-.]+/, "") || "game"
  );
}

/** The one preset `godot_export` exports with; the project's own presets are not used. */
export function presetFor(target: GodotExportTarget, slug: string): { name: string; cfg: string } {
  const spec = TARGETS[target];
  const name = `Oppi ${spec.label}`;
  const options: Record<GodotExportTarget, string[]> = {
    web: ["variant/thread_support=false", "variant/extensions_support=false"],
    macos: [
      'binary_format/architecture="universal"',
      `application/bundle_identifier="dev.oppi.export.${slug.replace(/[^A-Za-z0-9-]/g, "-")}"`,
      // Built-in ad-hoc signing: Apple silicon runs no unsigned code.
      "codesign/codesign=1",
      "notarization/notarization=0",
    ],
    linux: ['binary_format/architecture="x86_64"', "binary_format/embed_pck=true"],
    windows: [
      'binary_format/architecture="x86_64"',
      "binary_format/embed_pck=true",
      // Changing the icon and version resources needs rcedit, which the server does not have.
      "application/modify_resources=false",
    ],
  };
  const cfg = [
    "[preset.0]",
    "",
    `name="${name}"`,
    `platform="${spec.platform}"`,
    "runnable=true",
    "dedicated_server=false",
    'custom_features=""',
    'export_filter="all_resources"',
    'include_filter=""',
    'exclude_filter="build/*"',
    'export_path=""',
    "",
    "[preset.0.options]",
    "",
    ...options[target],
    "",
  ].join("\n");
  return { name, cfg };
}

/** Run one export end to end; failures are outcomes with the reason, never throws. */
export async function exportGodotProject(
  games: OppiGodotHost,
  projectId: string,
  target: GodotExportTarget,
  options: { installTemplates: boolean; progress: GodotExportProgress; signal?: AbortSignal },
): Promise<GodotExportOutcome> {
  const source = games.exportSource(projectId);
  if ("error" in source) return { ok: false, error: source.error };
  const { signal, progress } = options;
  const spec = TARGETS[target];

  const probe = await run(GODOT, ["--headless", "--version"], {
    timeoutMs: 30_000,
    ...(signal ? { signal } : {}),
  });
  if (probe.spawnError === "ENOENT")
    return { ok: false, error: "Godot is not installed on the server: no godot on its PATH." };
  const versionLine = probe.output.trim().split("\n").pop() ?? "";
  const version = probe.code === 0 ? parseGodotVersion(versionLine) : undefined;
  if (!version)
    return {
      ok: false,
      error: `Cannot tell which Godot this is from \`godot --version\`: ${versionLine || probe.output.trim()}`,
    };

  const root = templatesRoot();
  const template = join(root, version.folder, spec.template);
  if (!(await exists(template))) {
    if (await exists(join(root, version.folder)))
      return {
        ok: false,
        error: `The Godot ${version.folder} export templates in ${join(root, version.folder)} have no ${spec.template}. Reinstall them from the Godot editor.`,
      };
    if (!options.installTemplates)
      return { ok: false, error: templatesMissingError(version.folder, root) };
    try {
      await installTemplates(version, root, progress, signal);
    } catch (error) {
      return {
        ok: false,
        error: `Installing the export templates failed: ${String((error as Error).message ?? error)}`,
      };
    }
  }

  const slug = slugOf(source.dir);
  // Outside the project: a folder cannot be copied into itself. The system temp folder is on the
  // same volume as the home folder on a Mac, so the copy is still a clone there.
  const work = join(tmpdir(), `oppi-godot-export-${randomUUID()}`);
  try {
    const project = join(work, "project");
    const out = join(work, "out");
    await fs.mkdir(out, { recursive: true });
    await fs.cp(source.dir, project, {
      recursive: true,
      preserveTimestamps: true,
      mode: fs.constants.COPYFILE_FICLONE,
      filter: (path) => {
        const top = relative(source.dir, path).split(/[\\/]/)[0];
        return (
          top !== "build" && top !== ".git" && relative(source.dir, path) !== "export_presets.cfg"
        );
      },
    });
    const preset = presetFor(target, slug);
    await fs.writeFile(join(project, "export_presets.cfg"), preset.cfg);
    // Godot refuses a universal (or arm64) macOS build unless the project imports ETC2/ASTC
    // textures; the copy turns that on, the project keeps its setting.
    if (target === "macos") {
      const settings = join(project, "project.godot");
      await fs.writeFile(settings, withEtc2Astc(await fs.readFile(settings, "utf8")));
    }
    const file = spec.file(slug);
    progress(`Exporting ${source.name} for ${spec.label} with Godot ${version.folder}…`);
    const exported = await run(
      GODOT,
      ["--headless", "--path", project, "--export-release", preset.name, join(out, file)],
      { timeoutMs: EXPORT_TIMEOUT_MS, ...(signal ? { signal } : {}) },
    );
    const tail = exported.output
      .replace(ANSI, "")
      .trim()
      .split("\n")
      .filter((line) => !line.startsWith("["))
      .slice(-20)
      .join("\n");
    if (exported.code !== 0 || !(await exists(join(out, file))))
      return {
        ok: false,
        error: `Godot could not export ${source.name} for ${spec.label}${
          exported.code === null ? " (it was stopped or timed out)" : ` (exit ${exported.code})`
        }:\n${tail}`,
      };

    if (target === "web") {
      const size = await folderSize(out);
      const served = await games.adoptWebExport(projectId, out);
      return {
        ok: true,
        text:
          `Exported ${source.name} for the web, single-threaded (${sizeOf(size)}). This Oppi ` +
          `server serves it at ${served.path} to the owner and paired devices: every request ` +
          "needs the owner token or a paired device's token, so a browser without one is refused.",
      };
    }
    const folder = join(source.dir, "build", target);
    await fs.mkdir(folder, { recursive: true });
    const destination = join(folder, file);
    // Write beside it, then rename: a build in use is replaced whole, never half-written.
    const staged = join(folder, `.${file}.${randomUUID()}`);
    await fs.copyFile(join(out, file), staged, fs.constants.COPYFILE_FICLONE);
    await fs.rename(staged, destination);
    const size = (await fs.stat(destination)).size;
    return {
      ok: true,
      text: `Exported ${source.name} for ${spec.label}: build/${target}/${file} (${sizeOf(size)}) in ${source.dir}.`,
    };
  } catch (error) {
    return {
      ok: false,
      error: `Exporting ${source.name} failed: ${String((error as Error).message ?? error)}`,
    };
  } finally {
    await fs.rm(work, { recursive: true, force: true });
  }
}
