import { createServer, request } from "node:http";
import { afterEach, describe, expect, it, vi } from "vitest";

import { NetworkListeners } from "../src/network-listeners.js";

// 192.0.2.0/24 is TEST-NET-1: never assigned to this machine, so binding it fails with
// EADDRNOTAVAIL, the same as a Tailscale address before Tailscale connects.
const ABSENT_ADDRESS = "192.0.2.1";

function get(host: string, port: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const req = request({ host, port, path: "/" }, (res) => {
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (chunk: string) => (body += chunk));
      res.on("end", () => resolve(body));
    });
    req.on("error", reject);
    req.end();
  });
}

function listeners(tailscaleAddresses: () => Promise<string[]>): NetworkListeners {
  return new NetworkListeners({
    scheme: "http",
    createServer: () => createServer((_req, res) => res.end("ok")),
    onUpgrade: (_req, socket) => socket.destroy(),
    tailscaleAddresses,
  });
}

describe("NetworkListeners", () => {
  let open: NetworkListeners | undefined;

  afterEach(async () => {
    vi.useRealTimers();
    await open?.close();
    open = undefined;
  });

  it("binds only loopback plus Tailscale by default, all on one port", async () => {
    open = listeners(async () => [ABSENT_ADDRESS]);
    await open.listen(undefined, 0);

    expect(open.addresses).toEqual(["127.0.0.1", "::1"]);
    const port = open.port!;
    await expect(get("127.0.0.1", port)).resolves.toBe("ok");
    await expect(get("::1", port)).resolves.toBe("ok");
  });

  it("keeps an explicit host as the single listener and never asks Tailscale", async () => {
    const tailscaleAddresses = vi.fn(async () => ["::1"]);
    open = listeners(tailscaleAddresses);
    await open.listen("127.0.0.1", 0);

    expect(open.addresses).toEqual(["127.0.0.1"]);
    expect(tailscaleAddresses).not.toHaveBeenCalled();
    await expect(get("::1", open.port!)).rejects.toThrow();
  });

  it("looks Tailscale up again until an address binds", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    const tailscaleAddresses = vi.fn(async (): Promise<string[]> => []);
    open = listeners(tailscaleAddresses);
    await open.listen(undefined, 0);
    expect(tailscaleAddresses).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(30_000);
    expect(tailscaleAddresses).toHaveBeenCalledTimes(2);

    // An address that is already bound counts: the lookups stop.
    tailscaleAddresses.mockResolvedValue(["::1"]);
    await vi.advanceTimersByTimeAsync(30_000);
    expect(tailscaleAddresses).toHaveBeenCalledTimes(3);
    await vi.advanceTimersByTimeAsync(60_000);
    expect(tailscaleAddresses).toHaveBeenCalledTimes(3);
  });

  it("fails startup on a real conflict instead of skipping the address", async () => {
    const first = listeners(async () => []);
    await first.listen("127.0.0.1", 0);
    open = listeners(async () => []);
    try {
      await expect(open.listen(undefined, first.port!)).rejects.toMatchObject({
        code: "EADDRINUSE",
      });
    } finally {
      await first.close();
    }
  });
});
