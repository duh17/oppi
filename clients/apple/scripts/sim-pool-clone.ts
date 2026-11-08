import { dlopen, FFIType, read, suffix } from "bun:ffi";
import { mkdirSync } from "node:fs";
import { spawnSync } from "node:child_process";

// One clonefile(2) on a directory clones the whole tree and emits a few file-system events (about
// three), where `cp -c -R` clones file by file and emits events for every one of them (about 726
// for a test run's products), each of which fseventsd and Spotlight then process.
// clonefile(2)'s man page discourages directory clones in favor of copyfile(3), but copyfile clones
// file by file like cp. The call is atomic (all or nothing), so a failure leaves no partial tree for
// the copy below to merge into. Flags 0: symlinks inside the tree are cloned as links.
const libc = dlopen(`libc.${suffix}`, {
  clonefile: { args: [FFIType.ptr, FFIType.ptr, FFIType.u32], returns: FFIType.i32 },
  // The address of this thread's errno; bun:ffi has no errno of its own.
  __error: { args: [], returns: FFIType.ptr },
});

const ERRNO_NAMES: Record<number, string> = {
  1: "EPERM",
  2: "ENOENT",
  13: "EACCES",
  17: "EEXIST",
  18: "EXDEV",
  28: "ENOSPC",
  45: "ENOTSUP",
};

function cString(path: string): Buffer {
  return Buffer.from(`${path}\0`);
}

/** Why clonefile(2) failed, as `EXDEV (18)`, read straight after the call that failed. */
function lastErrno(): string {
  const address = libc.symbols.__error?.();
  if (typeof address !== "number" || address === 0) return "unknown errno";
  const errno = read.i32(address);
  return ERRNO_NAMES[errno] ? `${ERRNO_NAMES[errno]} (${errno})` : `errno ${errno}`;
}

export type CloneMethod = "clonefile" | "copy";

/**
 * Clone the directory `src` to `dest` with one clonefile(2) call (APFS: no data copy). `dest` must
 * not exist and its parent must. When clonefile fails (another volume, EXDEV; a target that
 * exists, EEXIST; a file system without clones) it logs why and copies `src`'s contents into
 * `dest` file by file with `cp -c -R`, which still clones what it can. Throws when the copy fails too.
 */
export function cloneDirectory(src: string, dest: string, log: (message: string) => void = () => {}): CloneMethod {
  const clonefile = libc.symbols.clonefile;
  if (typeof clonefile !== "function") {
    log("[sim-pool] clonefile(2) is unavailable; copying the products file by file");
  } else if (clonefile(cString(src), cString(dest), 0) === 0) {
    return "clonefile";
  } else {
    log(`[sim-pool] clonefile(${src} -> ${dest}) failed: ${lastErrno()}; copying the products file by file`);
  }
  // `src/.` copies the contents into `dest`, so an existing `dest` is merged into, not nested under.
  mkdirSync(dest, { recursive: true });
  const result = spawnSync("/bin/cp", ["-c", "-R", `${src}/.`, dest], { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(`cloning ${src} failed: ${result.stderr.trim() || result.error?.message || result.status}`);
  }
  return "copy";
}
