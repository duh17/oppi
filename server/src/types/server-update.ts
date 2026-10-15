/**
 * How this Oppi server was installed. The app updates `npm-global` from the
 * registry and rebuilds a `source-link` (an `npm link`ed checkout) in place.
 */
export type ServerInstallKind = "npm-global" | "source-link" | "other";

/** In-flight or last completed in-app update. */
export type ServerUpdateStatus = "idle" | "installing" | "restarting" | "restart-needed" | "failed";

/**
 * How the process will come back after a successful install or rebuild.
 * `reexec` replaces this process in-place. `launchd` exits non-zero so
 * KeepAlive (SuccessfulExit=false) starts the new binary. `manual` means
 * the install succeeded and the user must restart the server.
 */
export type ServerRestartMode = "reexec" | "launchd" | "manual";

/** Additive `update` object on GET /server/info. */
export interface ServerUpdateInfo {
  installKind: ServerInstallKind;
  /**
   * npm-global: latest published `oppi-server` version, or null when the registry
   * is unknown. source-link: the checkout's package.json version.
   */
  latestVersion: string | null;
  /**
   * npm-global: `latestVersion` is newer than `version`. source-link: the checkout
   * changed since the running build (version, or a file under src/ or extensions/ edited
   * after the earlier of process start and the dist build).
   */
  available: boolean;
  /** Copyable host command when the app cannot update this install. */
  manualCommand: string;
  status: ServerUpdateStatus;
  /** Version the in-flight or last attempt targeted. */
  targetVersion?: string;
  /** npm install or build output tail when `status` is `failed`. */
  error?: string;
  restartMode: ServerRestartMode;
}

export const SERVER_UPDATE_ERROR = {
  invalidVersion: "invalid_version",
  versionNotLatest: "version_not_latest",
  latestUnknown: "latest_unknown",
  installNotUpdatable: "install_not_updatable",
  updateInProgress: "update_in_progress",
  alreadyCurrent: "already_current",
} as const;

export type ServerUpdateErrorCode = (typeof SERVER_UPDATE_ERROR)[keyof typeof SERVER_UPDATE_ERROR];
