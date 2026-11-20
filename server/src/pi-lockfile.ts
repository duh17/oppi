import { createRequire } from "node:module";
import { PI_PACKAGE_ENTRY } from "./pi-private.js";

/** `proper-lockfile` as bundled with `@earendil-works/pi-coding-agent`. */
export const properLockfile = createRequire(PI_PACKAGE_ENTRY)("proper-lockfile") as {
  lock: (
    file: string,
    options?: {
      /** The lock directory; defaults to `<file>.lock`. */
      lockfilePath?: string;
      realpath?: boolean;
      stale?: number;
      update?: number;
      retries?: number;
      /** Called once the held lock is lost. The default throws, outside any caller. */
      onCompromised?: (error: Error) => void;
    },
  ) => Promise<() => Promise<void>>;
  lockSync: (file: string, options?: { realpath?: boolean }) => () => void;
};
