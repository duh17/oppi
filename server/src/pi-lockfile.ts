import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

/** `proper-lockfile` as bundled with `@earendil-works/pi-coding-agent`. */
export const properLockfile = createRequire(
  fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent")),
)("proper-lockfile") as {
  lock: (
    file: string,
    options?: { realpath?: boolean; stale?: number; update?: number; retries?: number },
  ) => Promise<() => Promise<void>>;
  lockSync: (file: string, options?: { realpath?: boolean }) => () => void;
};
