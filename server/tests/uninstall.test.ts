/**
 * `oppi uninstall` on a home laid out the way install.sh and `oppi serve` leave it: everything
 * Oppi added goes, and everything that was there before stays as it was.
 */
import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  readlinkSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { cmdUninstall, removeInstallerPathLines } from "../src/cli/commands/uninstall.js";

const AUTO_NAME_SHIPPED =
  "/opt/oppi/install/current/lib/node_modules/oppi-server/dist/plugins/auto-name";

let home: string;
beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "oppi-uninstall-home-"));
  vi.stubEnv("HOME", home);
  vi.stubEnv("OPPI_DATA_DIR", join(home, ".config", "oppi"));
  vi.stubEnv("PI_CODING_AGENT_DIR", join(home, ".pi", "agent"));
  vi.stubEnv("ZDOTDIR", "");
});
afterEach(() => {
  vi.unstubAllEnvs();
  rmSync(home, { recursive: true, force: true });
});

/** Every path under the home with its content (files), target (links), or `dir`. */
function tree(root: string): Record<string, string> {
  const entries: Record<string, string> = {};
  const walk = (dir: string): void => {
    for (const name of readdirSync(dir)) {
      const path = join(dir, name);
      const key = relative(root, path);
      const stat = lstatSync(path);
      if (stat.isSymbolicLink()) entries[key] = `-> ${readlinkSync(path)}`;
      else if (stat.isDirectory()) {
        entries[key] = "dir";
        walk(path);
      } else entries[key] = readFileSync(path, "utf8");
    }
  };
  walk(root);
  return entries;
}

function write(path: string, content: string): void {
  mkdirSync(join(path, ".."), { recursive: true });
  writeFileSync(path, content);
}

/** What the owner had before installing: a profile, Pi with another package, another link. */
function seedOwnersHome(): void {
  write(join(home, ".zprofile"), 'eval "$(/opt/homebrew/bin/brew shellenv)"\n');
  write(join(home, ".profile"), "umask 022\n");
  write(
    join(home, ".pi", "agent", "settings.json"),
    // As Pi writes it.
    JSON.stringify({ defaultProvider: "anthropic", packages: ["npm:pi-other"] }, null, 2),
  );
}

/** What install.sh and a first `oppi serve` add (the strings install.sh writes). */
function seedOppiInstall(): void {
  const oppiHome = join(home, ".oppi");
  write(join(oppiHome, "bin", "oppi"), "#!/bin/sh\n");
  write(join(oppiHome, "install", "releases", "0.56.0", "cli.js"), "");
  write(
    join(oppiHome, "install", "created"),
    `${join(home, ".local", "bin")}\n${join(home, ".local")}\n`,
  );
  mkdirSync(join(home, ".local", "bin"), { recursive: true });
  symlinkSync(join(oppiHome, "bin", "oppi"), join(home, ".local", "bin", "oppi"));
  writeFileSync(
    join(home, ".zprofile"),
    `${readFileSync(join(home, ".zprofile"), "utf8")}\n# Added by the Oppi installer\nexport PATH="$HOME/.local/bin:$PATH"\n`,
  );
  const settingsPath = join(home, ".pi", "agent", "settings.json");
  const settings = JSON.parse(readFileSync(settingsPath, "utf8")) as { packages: unknown[] };
  settings.packages.push({ source: AUTO_NAME_SHIPPED, extensions: ["+index.ts"] });
  writeFileSync(settingsPath, JSON.stringify(settings, null, 2));
  write(join(home, ".config", "oppi", "config.json"), "{}\n");
}

/** Runs the command and returns what it printed, and its exit code. */
async function uninstall(flags: Record<string, string>): Promise<{ output: string; code: number }> {
  const lines: string[] = [];
  const spy = vi.spyOn(console, "log").mockImplementation((line: string) => lines.push(line));
  const exitCode = process.exitCode;
  try {
    await cmdUninstall(flags);
    return { output: lines.join("\n"), code: Number(process.exitCode ?? 0) };
  } finally {
    spy.mockRestore();
    process.exitCode = exitCode;
  }
}

describe("oppi uninstall", () => {
  it("leaves the home as it was before the install", async () => {
    seedOwnersHome();
    mkdirSync(join(home, ".config"));
    const before = tree(home);
    seedOppiInstall();

    const { code } = await uninstall({ "delete-data": "true" });

    expect(tree(home)).toEqual(before);
    expect(code).toBe(0);
  });

  it("keeps the data folder without a terminal to ask, and what is not Oppi's", async () => {
    seedOwnersHome();
    seedOppiInstall();
    // The owner replaced the link with their own oppi, and edited Oppi's PATH line.
    rmSync(join(home, ".local", "bin", "oppi"));
    write(join(home, ".local", "bin", "oppi"), "#!/bin/sh\necho mine\n");
    const edited =
      'umask 022\n\n# Added by the Oppi installer\nexport PATH="$HOME/bin:$HOME/.local/bin:$PATH:/extra"\n';
    writeFileSync(join(home, ".profile"), edited);

    const { output } = await uninstall({});

    expect(readFileSync(join(home, ".config", "oppi", "config.json"), "utf8")).toBe("{}\n");
    expect(output).toContain("Kept the data folder");
    expect(readFileSync(join(home, ".local", "bin", "oppi"), "utf8")).toContain("mine");
    expect(readFileSync(join(home, ".profile"), "utf8")).toBe(edited);
    expect(existsSync(join(home, ".oppi"))).toBe(false);
  });
});

describe("removeInstallerPathLines", () => {
  it("removes each block install.sh appended and nothing around it", () => {
    const owner = "export EDITOR=vim\n\nalias ll='ls -l'\n";
    const block = '\n# Added by the Oppi installer\nexport PATH="$HOME/.local/bin:$PATH"\n';
    const fish = '# Added by the Oppi installer\nfish_add_path -g "$HOME/.oppi/bin"\n';

    expect(removeInstallerPathLines(owner + block + "export LANG=C\n")).toEqual({
      text: owner + "export LANG=C\n",
      removed: 1,
    });
    expect(removeInstallerPathLines(owner + block + block)).toEqual({ text: owner, removed: 2 });
    expect(removeInstallerPathLines(fish)).toEqual({ text: "", removed: 1 });
    expect(removeInstallerPathLines(owner)).toEqual({ text: owner, removed: 0 });
  });
});
