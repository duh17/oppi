import { afterEach, describe, expect, it } from "vitest";
import { LoopbackBridgeManager } from "../src/loopback-bridge.js";

const managers: LoopbackBridgeManager[] = [];

afterEach(async () => {
  await Promise.all(managers.map((manager) => manager.shutdown()));
  managers.length = 0;
});

describe("LoopbackBridgeManager", () => {
  it("keeps non-loopback URLs unchanged", () => {
    const manager = new LoopbackBridgeManager();
    managers.push(manager);

    const baseUrl = "https://api.example.com/v1";
    expect(manager.rewriteForHostGateway(baseUrl, "10.201.0.1")).toBe(baseUrl);
  });

  it("rewrites localhost URL to host-gateway with same port before bridge starts", () => {
    const manager = new LoopbackBridgeManager();
    managers.push(manager);

    const rewritten = manager.rewriteForHostGateway("http://localhost:1234/v1", "10.201.0.1");
    expect(rewritten).toBe("http://10.201.0.1:1234/v1");
  });

  it("uses bridge port for localhost URL after bridge is prepared", async () => {
    const manager = new LoopbackBridgeManager();
    managers.push(manager);

    await manager.ensureForBaseUrls(["http://localhost:1234/v1"]);

    const bridgePort = manager.bridgePortForTarget(1234);
    expect(bridgePort).toBeDefined();

    const rewritten = manager.rewriteForHostGateway("http://localhost:1234/v1", "10.201.0.1");
    expect(rewritten).toBe(`http://10.201.0.1:${bridgePort}/v1`);
  });
});
