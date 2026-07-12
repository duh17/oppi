import { execFileSync } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const serverRoot = dirname(fileURLToPath(import.meta.url));

export default function buildCliOnce(): () => void {
  const buildRoot = mkdtempSync(join(tmpdir(), "oppi-vitest-build-"));

  try {
    execFileSync(join(serverRoot, "node_modules", ".bin", "tsc"), ["--outDir", buildRoot], {
      cwd: serverRoot,
      stdio: "inherit",
    });
    execFileSync(process.execPath, [join(serverRoot, "scripts", "copy-oppi-docs.mjs")], {
      cwd: serverRoot,
      env: { ...process.env, OPPI_BUILD_DIR: buildRoot },
      stdio: "inherit",
    });

    symlinkSync(join(serverRoot, "node_modules"), join(buildRoot, "node_modules"), "dir");

    const cliPath = join(buildRoot, "src", "cli.js");
    chmodSync(cliPath, 0o755);
    process.env.OPPI_TEST_CLI = cliPath;
  } catch (error) {
    rmSync(buildRoot, { recursive: true, force: true });
    throw error;
  }

  return () => rmSync(buildRoot, { recursive: true, force: true });
}
