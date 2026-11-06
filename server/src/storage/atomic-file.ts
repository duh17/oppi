import { randomUUID } from "node:crypto";
import { closeSync, fsyncSync, openSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";

export type AtomicWriteStep =
  "after_temp_write" | "after_temp_fsync" | "before_rename" | "after_rename";

export interface AtomicWriteOptions {
  /**
   * Survive a crash: fsync the file before the rename and the directory after it. Without it a
   * crash can leave the old file, or on some filesystems an empty new one, but never a torn one.
   */
  durable: boolean;
  /**
   * Called as each step completes (`after_temp_fsync` only when `durable`); throwing aborts the
   * write. After `after_rename` the target already holds the new bytes, so a caller that rolls
   * back watches for that step.
   */
  onStep?: (step: AtomicWriteStep) => void;
}

/**
 * Replaces `path` with `data`: a reader sees the old file or the whole new one. The file is 0600.
 * The temp file is unique to this call, beside `path`, and removed on failure. The caller owns
 * the directory's existence and any lock against concurrent writers.
 */
export function writeFileAtomic(
  path: string,
  data: string | Uint8Array,
  options: AtomicWriteOptions,
): void {
  const { durable, onStep } = options;
  const directory = dirname(path);
  const temporaryPath = join(directory, `.${basename(path)}.${process.pid}.${randomUUID()}.tmp`);
  let descriptor: number | undefined;
  try {
    descriptor = openSync(temporaryPath, "wx", 0o600);
    writeFileSync(descriptor, data);
    onStep?.("after_temp_write");
    if (durable) {
      fsyncSync(descriptor);
      onStep?.("after_temp_fsync");
    }
    closeSync(descriptor);
    descriptor = undefined;

    onStep?.("before_rename");
    renameSync(temporaryPath, path);
    onStep?.("after_rename");
    if (durable) syncDirectory(directory);
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
    // This exact random path belongs to this call: never scan for or remove anyone else's.
    rmSync(temporaryPath, { force: true });
  }
}

export function syncDirectory(directory: string): void {
  const descriptor = openSync(directory, "r");
  try {
    fsyncSync(descriptor);
  } finally {
    closeSync(descriptor);
  }
}
