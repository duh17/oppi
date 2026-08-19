import { describe, expect, it, vi } from "vitest";

import { SdkBackend } from "../src/sdk-backend.js";
import {
  deleteWorkspaceAndStopVm,
  notifySandboxWorkspaceActivity,
} from "../src/workspace-sandbox-lifecycle.js";

describe("notifySandboxWorkspaceActivity", () => {
  it("notifies busy for a sandbox session", () => {
    const vm = {
      noteWorkspaceBusy: vi.fn(),
      noteWorkspaceIdle: vi.fn(),
    };

    notifySandboxWorkspaceActivity(
      { id: "s1", workspaceId: "ws-1", status: "busy" },
      { runtime: "sandbox" },
      vm,
    );

    expect(vm.noteWorkspaceBusy).toHaveBeenCalledWith("ws-1", "s1");
    expect(vm.noteWorkspaceIdle).not.toHaveBeenCalled();
  });

  it.each(["stopped", "error"] as const)(
    "notifies idle when a sandbox session is %s",
    (status) => {
      const vm = {
        noteWorkspaceBusy: vi.fn(),
        noteWorkspaceIdle: vi.fn(),
      };

      notifySandboxWorkspaceActivity(
        { id: "s1", workspaceId: "ws-1", status },
        { runtime: "sandbox" },
        vm,
      );

      expect(vm.noteWorkspaceIdle).toHaveBeenCalledWith("ws-1", "s1");
      expect(vm.noteWorkspaceBusy).not.toHaveBeenCalled();
    },
  );

  it.each(["ready", "starting", "stopping"] as const)(
    "keeps the VM while a sandbox session is %s",
    (status) => {
      const vm = {
        noteWorkspaceBusy: vi.fn(),
        noteWorkspaceIdle: vi.fn(),
      };

      notifySandboxWorkspaceActivity(
        { id: "s1", workspaceId: "ws-1", status },
        { runtime: "sandbox" },
        vm,
      );

      expect(vm.noteWorkspaceBusy).toHaveBeenCalledWith("ws-1", "s1");
      expect(vm.noteWorkspaceIdle).not.toHaveBeenCalled();
    },
  );

  it("ignores host workspaces and missing targets", () => {
    const vm = {
      noteWorkspaceBusy: vi.fn(),
      noteWorkspaceIdle: vi.fn(),
    };

    notifySandboxWorkspaceActivity(
      { id: "s1", workspaceId: "ws-1", status: "busy" },
      { runtime: "host" },
      vm,
    );
    notifySandboxWorkspaceActivity({ id: "s1", status: "busy" }, { runtime: "sandbox" }, vm);
    notifySandboxWorkspaceActivity(
      { id: "s1", workspaceId: "ws-1", status: "ready" },
      { runtime: "sandbox" },
    );

    expect(vm.noteWorkspaceBusy).not.toHaveBeenCalled();
    expect(vm.noteWorkspaceIdle).not.toHaveBeenCalled();
  });
});

describe("deleteWorkspaceAndStopVm", () => {
  it("invokes stopWorkspaceVm after deleting the workspace record", async () => {
    const deleteWorkspace = vi.fn(() => true);
    const stopWorkspaceVm = vi.fn(async () => undefined);

    const deleted = await deleteWorkspaceAndStopVm("ws-1", {
      deleteWorkspace,
      stopWorkspaceVm,
    });

    expect(deleted).toBe(true);
    expect(deleteWorkspace).toHaveBeenCalledWith("ws-1");
    expect(stopWorkspaceVm).toHaveBeenCalledWith("ws-1");
    expect(deleteWorkspace.mock.invocationCallOrder[0]).toBeLessThan(
      stopWorkspaceVm.mock.invocationCallOrder[0],
    );
  });

  it("still stops the workspace VM when the record was already gone", async () => {
    const stopWorkspaceVm = vi.fn(async () => undefined);

    const deleted = await deleteWorkspaceAndStopVm("ws-missing", {
      deleteWorkspace: () => false,
      stopWorkspaceVm,
    });

    expect(deleted).toBe(false);
    expect(stopWorkspaceVm).toHaveBeenCalledWith("ws-missing");
  });
});

describe("SdkBackend workspace VM accessors", () => {
  it("delegates stopWorkspaceVm and stopAll to the manager", async () => {
    const manager = {
      stopWorkspaceVm: vi.fn(async () => undefined),
      stopAll: vi.fn(async () => undefined),
      noteWorkspaceBusy: vi.fn(),
      noteWorkspaceIdle: vi.fn(),
    };
    const sdkBackendType = SdkBackend as unknown as { _gondolinManager?: typeof manager };
    const previous = sdkBackendType._gondolinManager;
    sdkBackendType._gondolinManager = manager;

    try {
      await SdkBackend.stopWorkspaceVm("ws-1");
      await SdkBackend.stopAllWorkspaceVms();
      SdkBackend.noteWorkspaceBusy("ws-1", "s1");
      SdkBackend.noteWorkspaceIdle("ws-1", "s1");
      expect(manager.stopWorkspaceVm).toHaveBeenCalledWith("ws-1");
      expect(manager.stopAll).toHaveBeenCalledOnce();
      expect(manager.noteWorkspaceBusy).toHaveBeenCalledWith("ws-1", "s1");
      expect(manager.noteWorkspaceIdle).toHaveBeenCalledWith("ws-1", "s1");
    } finally {
      sdkBackendType._gondolinManager = previous;
    }
  });

  it("is a no-op when sandbox mode has never booted a VM", async () => {
    const sdkBackendType = SdkBackend as unknown as { _gondolinManager?: unknown };
    const previous = sdkBackendType._gondolinManager;
    sdkBackendType._gondolinManager = undefined;

    try {
      await expect(SdkBackend.stopWorkspaceVm("ws-1")).resolves.toBeUndefined();
      await expect(SdkBackend.stopAllWorkspaceVms()).resolves.toBeUndefined();
      expect(() => SdkBackend.noteWorkspaceBusy("ws-1", "s1")).not.toThrow();
      expect(() => SdkBackend.noteWorkspaceIdle("ws-1", "s1")).not.toThrow();
    } finally {
      sdkBackendType._gondolinManager = previous;
    }
  });
});
