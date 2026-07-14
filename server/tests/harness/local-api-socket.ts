import { mkdirSync } from "node:fs";
import type { Server } from "node:http";
import { dirname } from "node:path";

import { localApiSocketPath } from "../../src/local-api-socket.js";

export async function listenOnLocalApiFixture(server: Server, dataDir: string): Promise<string> {
  const socketPath = localApiSocketPath(dataDir);
  mkdirSync(dirname(socketPath), { recursive: true, mode: 0o700 });
  await new Promise<void>((resolve, reject) => {
    const onError = (error: Error): void => reject(error);
    server.once("error", onError);
    server.listen(socketPath, () => {
      server.off("error", onError);
      resolve();
    });
  });
  return socketPath;
}
