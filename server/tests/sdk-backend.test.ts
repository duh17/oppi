import { homedir } from "node:os";
import { resolve as resolvePath } from "node:path";
import { describe, expect, it, vi } from "vitest";

import { resolveSdkSessionCwd, SdkBackend } from "../src/sdk-backend.js";
import type { Workspace } from "../src/types.js";

describe("resolveSdkSessionCwd", () => {
  it("defaults to home dir when workspace is missing", () => {
    expect(resolveSdkSessionCwd(undefined)).toBe(homedir());
  });

  it("expands tilde hostMount to an absolute path", () => {
    const workspace = { hostMount: "~/workspace/oppi" } as Workspace;
    expect(resolveSdkSessionCwd(workspace)).toBe(resolvePath(homedir(), "workspace", "oppi"));
  });

  it("expands bare tilde hostMount", () => {
    const workspace = { hostMount: "~" } as Workspace;
    expect(resolveSdkSessionCwd(workspace)).toBe(homedir());
  });

  it("keeps absolute hostMount unchanged", () => {
    const mount = resolvePath(homedir(), "workspace", "oppi");
    const workspace = { hostMount: mount } as Workspace;
    expect(resolveSdkSessionCwd(workspace)).toBe(mount);
  });
});

describe("SdkBackend.setModel", () => {
  function makeSetModelHarness() {
    const backend = Object.create(SdkBackend.prototype) as SdkBackend;

    const modelRegistry = {
      find: vi.fn(),
    };

    const piSession = {
      setModel: vi.fn(async () => {}),
      model: undefined as
        | {
            provider?: string;
            id?: string;
            name?: string;
          }
        | undefined,
    };

    const mutableBackend = backend as unknown as {
      modelRegistry: typeof modelRegistry;
      piSession: typeof piSession;
    };

    mutableBackend.modelRegistry = modelRegistry;
    mutableBackend.piSession = piSession;

    return { backend, modelRegistry, piSession };
  }

  it("rejects invalid model IDs", async () => {
    const { backend, modelRegistry, piSession } = makeSetModelHarness();

    const result = await backend.setModel("claude-sonnet-4-5");

    expect(result).toEqual({ success: false, error: "Invalid model ID: claude-sonnet-4-5" });
    expect(modelRegistry.find).not.toHaveBeenCalled();
    expect(piSession.setModel).not.toHaveBeenCalled();
  });

  it("returns unknown model instead of throwing on missing provider/model", async () => {
    const { backend, modelRegistry, piSession } = makeSetModelHarness();
    modelRegistry.find.mockReturnValue(undefined);

    const result = await backend.setModel("studio/qwen3-coder");

    expect(result).toEqual({ success: false, error: "Unknown model: studio/qwen3-coder" });
    expect(modelRegistry.find).toHaveBeenCalledWith("studio", "qwen3-coder");
    expect(piSession.setModel).not.toHaveBeenCalled();
  });

  it("sets models resolved from ModelRegistry (including custom providers)", async () => {
    const { backend, modelRegistry, piSession } = makeSetModelHarness();
    const model = {
      provider: "studio",
      id: "qwen3-coder",
      name: "Qwen3 Coder",
    };
    modelRegistry.find.mockReturnValue(model);
    piSession.model = model;

    const result = await backend.setModel("studio/qwen3-coder");

    expect(modelRegistry.find).toHaveBeenCalledWith("studio", "qwen3-coder");
    expect(piSession.setModel).toHaveBeenCalledWith(model);
    expect(result).toEqual({
      success: true,
      provider: "studio",
      id: "qwen3-coder",
      name: "Qwen3 Coder",
    });
  });
});
