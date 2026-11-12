import { homedir } from "node:os";
import { join } from "node:path";

/**
 * The machine-wide Gondolin guest image store tests boot real VMs from, so no file or run pulls
 * the image again. `home` is the developer's, read before a test run swaps HOME for a temp dir.
 */
export function machineGondolinImageStore(home = process.env.HOME ?? homedir()): string {
  const cache =
    process.platform === "darwin"
      ? join(home, "Library", "Caches")
      : (process.env.XDG_CACHE_HOME ?? join(home, ".cache"));
  return join(cache, "oppi-gondolin", "images");
}
