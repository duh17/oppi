import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";
import { Worker, type WorkerOptions } from "node:worker_threads";

import {
  resolveTlsConfig,
  TailscaleRemoteUnavailableError,
  type ResolvedTlsConfig,
  type TlsPreparationOptions,
} from "./tls.js";
import type { ServerConfig } from "./types.js";

type TlsPreparationWorkerResult =
  | { ok: true; tls: ResolvedTlsConfig }
  | { ok: false; kind: "tailscale_unavailable" | "unexpected"; message: string };

export function prepareTlsForServerOffMainThread(
  config: Pick<ServerConfig, "tls">,
  dataDir: string,
  options: TlsPreparationOptions = {},
): Promise<ResolvedTlsConfig> {
  const resolved = resolveTlsConfig(config, dataDir);
  if (!resolved.enabled) return Promise.resolve(resolved);

  const workerLocation = resolveWorkerLocation();
  const workerData = { config, dataDir, options };
  // Node 22.18+ loads a Worker .ts entry with native type stripping, which does
  // not rewrite .js → .ts specifiers. tsx's `--import tsx` auto-register runs in
  // worker threads only on Node 24.11.1+/26 (registerHooks); on 22 it registers
  // only on the main thread. Bootstrap source workers through tsx/esm/api.
  const worker = workerLocation.source
    ? new Worker(sourceTlsWorkerBootstrap(workerLocation.url), {
        eval: true,
        type: "module",
        workerData,
      } as WorkerOptions)
    : new Worker(workerLocation.url, { workerData });

  return new Promise((resolve, reject) => {
    let settled = false;
    worker.once("message", (message: TlsPreparationWorkerResult) => {
      settled = true;
      if (message.ok) {
        resolve(message.tls);
        return;
      }
      reject(
        message.kind === "tailscale_unavailable"
          ? new TailscaleRemoteUnavailableError(message.message)
          : new Error(message.message),
      );
    });
    worker.once("error", (error) => {
      settled = true;
      reject(error);
    });
    worker.once("exit", (code) => {
      if (!settled && code !== 0) {
        reject(new Error(`TLS preparation worker exited with code ${code}`));
      } else if (!settled) {
        reject(new Error("TLS preparation worker exited without a result"));
      }
    });
  });
}

function resolveWorkerLocation(): { url: URL; source: boolean } {
  const compiledUrl = new URL("./tls-preparation-worker.js", import.meta.url);
  if (existsSync(fileURLToPath(compiledUrl))) return { url: compiledUrl, source: false };

  const sourceUrl = new URL("./tls-preparation-worker.ts", import.meta.url);
  if (existsSync(fileURLToPath(sourceUrl))) return { url: sourceUrl, source: true };

  throw new Error("Could not locate the TLS preparation worker");
}

function sourceTlsWorkerBootstrap(sourceUrl: URL): string {
  const tsxApi = pathToFileURL(createRequire(import.meta.url).resolve("tsx/esm/api")).href;
  return `import { register } from ${JSON.stringify(tsxApi)};
register();
await import(${JSON.stringify(sourceUrl.href)});
`;
}
