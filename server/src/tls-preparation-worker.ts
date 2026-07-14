import { parentPort, workerData } from "node:worker_threads";

import {
  prepareTlsForServer,
  TailscaleRemoteUnavailableError,
  type TlsPreparationOptions,
} from "./tls.js";
import type { ServerConfig } from "./types.js";

type TlsPreparationWorkerInput = {
  config: Pick<ServerConfig, "tls">;
  dataDir: string;
  options: TlsPreparationOptions;
};

type TlsPreparationWorkerResult =
  | { ok: true; tls: ReturnType<typeof prepareTlsForServer> }
  | { ok: false; kind: "tailscale_unavailable" | "unexpected"; message: string };

const input = workerData as TlsPreparationWorkerInput;

try {
  const tls = prepareTlsForServer(input.config, input.dataDir, input.options);
  post({ ok: true, tls });
} catch (error: unknown) {
  post({
    ok: false,
    kind: error instanceof TailscaleRemoteUnavailableError ? "tailscale_unavailable" : "unexpected",
    message: error instanceof Error ? error.message : String(error),
  });
}

function post(result: TlsPreparationWorkerResult): void {
  if (!parentPort) throw new Error("TLS preparation worker has no parent port");
  parentPort.postMessage(result);
}
