import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import type { Harness } from "@earendil-works/pi-durable";
import { DurableHarness } from "../src/durable-harness.js";
import { SessionManager } from "../src/sessions.js";
import { Storage } from "../src/storage.js";

const harnesses: Harness[] = [];
afterEach(async () => {
  await Promise.all(harnesses.splice(0).map((harness) => harness.close(context)));
  vi.restoreAllMocks();
});

async function isolatedModels(): Promise<ModelRuntime> {
  const dir = mkdtempSync(join(tmpdir(), "oppi-durable-models-"));
  return ModelRuntime.create({
    authPath: join(dir, "auth.json"),
    modelsPath: null,
    modelsStorePath: join(dir, "models-cache.json"),
    refreshOnCreate: false,
  });
}

describe("durable model runtime", () => {
  it("uses the bound catalog runtime instead of creating a private one", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-durable-models-harness-"));
    const runtime = await isolatedModels();
    vi.spyOn(SettingsManager, "create").mockReturnValue(
      SettingsManager.inMemory({ compaction: { enabled: false } }),
    );
    const create = vi.spyOn(ModelRuntime, "create");
    const owner = new DurableHarness(dir);
    owner.bindModelRuntime(runtime);
    const opened = await owner.open();
    harnesses.push(opened.harness);
    expect(opened.models).toBe(runtime);
    expect(create).not.toHaveBeenCalled();
  });

  it("refuses to open a production harness before the catalog runtime is bound", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-durable-models-required-"));
    const owner = new DurableHarness(dir);
    owner.requireDiscoveredModels();
    await expect(owner.open()).rejects.toThrow(/discovered model runtime was bound/);
  });

  it("forwards the server runtime through SessionManager before open", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-durable-models-manager-"));
    const runtime = await isolatedModels();
    const storage = new Storage(dir);
    storage.updateConfig({ experimental: { serverDurable: true } });
    const bind = vi.spyOn(DurableHarness.prototype, "bindModelRuntime");
    const manager = new SessionManager(storage);
    await manager.expectDurableModelRuntime();
    await manager.bindDurableModels(runtime);
    expect(bind).toHaveBeenCalledWith(runtime);
    await manager.close();
  });
});
