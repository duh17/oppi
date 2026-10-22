import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { LiveActivityNotifier } from "../src/live-activity-notifier.js";
import { Server } from "../src/server.js";
import { requestServerStop, stopRequestedPath } from "../src/server-stop-marker.js";
import { Storage } from "../src/storage.js";

// Away phones' Live Activity cards end only on a stop the person asked for. Every restart (the
// in-app update, `oppi server restart`, launchd KeepAlive, Docker) reaches the server as the
// same SIGTERM as `oppi server stop`, and a restart must keep the card.
describe("Server stop and Live Activity cards", () => {
  let dataDir: string;
  let storage: Storage;
  let endLiveCards: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-stop-marker-"));
    storage = new Storage(dataDir);
    storage.ensurePaired();
    storage.updateConfig({ host: "127.0.0.1", port: 0, tls: { mode: "disabled" } });
    endLiveCards = vi.spyOn(LiveActivityNotifier.prototype, "endLiveCards").mockResolvedValue();
  });

  afterEach(() => {
    vi.restoreAllMocks();
    rmSync(dataDir, { recursive: true, force: true });
  });

  it("keeps the cards on a stop nobody asked for, and drops a request left from an earlier run", async () => {
    // A `oppi server stop` that never reached a running server.
    requestServerStop(dataDir);
    const server = new Server(storage);
    await server.start();
    expect(existsSync(stopRequestedPath(dataDir))).toBe(false);
    await server.stop();
    expect(endLiveCards).not.toHaveBeenCalled();
  }, 30_000);

  it("ends the cards once on a requested stop, and removes the request", async () => {
    const server = new Server(storage);
    await server.start();
    requestServerStop(dataDir);
    await server.stop();
    expect(endLiveCards).toHaveBeenCalledTimes(1);
    expect(endLiveCards).toHaveBeenCalledWith(3_000);
    expect(existsSync(stopRequestedPath(dataDir))).toBe(false);
  }, 30_000);
});
