import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

import { SdkBackend } from "../src/sdk-backend.js";
import { SessionManager } from "../src/sessions.js";
import { Storage } from "../src/storage.js";
import type { Session, Workspace } from "../src/types.js";
import { makeSdkBackendStub } from "./sdk-backend.helpers.js";

const dirs: string[] = [];
const managers: SessionManager[] = [];
afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all(managers.splice(0).map((manager) => manager.close()));
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function makeFixture(status: Session["status"]): {
  storage: Storage;
  workspace: Workspace;
  session: Session;
  manager: SessionManager;
} {
  const dataDir = mkdtempSync(join(tmpdir(), "oppi-start-stop-"));
  dirs.push(dataDir);
  const storage = new Storage(dataDir);
  const workspace = storage.createWorkspace({ name: "project", hostMount: dataDir });
  const session = storage.createSession("start-stop", "anthropic/claude-sonnet-4-0");
  session.workspaceId = workspace.id;
  session.status = status;
  storage.saveSession(session);
  const manager = new SessionManager(storage);
  managers.push(manager);
  return { storage, workspace, session, manager };
}

describe("stop while a session is starting", () => {
  it("wins over the start: no runtime stays live and the row ends stopped", async () => {
    const { storage, workspace, session, manager } = makeFixture("stopped");
    const { sdkBackend, dispose } = makeSdkBackendStub();
    let finishCreate!: (backend: SdkBackend) => void;
    const create = vi.spyOn(SdkBackend, "create").mockReturnValue(
      new Promise<SdkBackend>((resolve) => {
        finishCreate = resolve;
      }),
    );

    const start = manager.startSession(session.id, workspace);
    await vi.waitFor(() => expect(create).toHaveBeenCalledOnce());
    expect(storage.getSession(session.id)?.status).toBe("starting");

    const stop = manager.stopSession(session.id);
    finishCreate(sdkBackend);
    await Promise.allSettled([start, stop]);
    await stop;

    expect(manager.isActive(session.id)).toBe(false);
    expect(dispose).toHaveBeenCalled();
    expect(storage.getSession(session.id)?.status).toBe("stopped");
  });

  it("settles when the start fails instead of waiting on it forever", async () => {
    const { storage, workspace, session, manager } = makeFixture("stopped");
    let failCreate!: (error: Error) => void;
    const create = vi.spyOn(SdkBackend, "create").mockReturnValue(
      new Promise<SdkBackend>((_resolve, reject) => {
        failCreate = reject;
      }),
    );

    const start = manager.startSession(session.id, workspace);
    const startOutcome = start.catch((error: unknown) => error);
    await vi.waitFor(() => expect(create).toHaveBeenCalledOnce());
    const stop = manager.stopSession(session.id);
    failCreate(new Error("create failed"));

    await stop;
    expect(await startOutcome).toMatchObject({ message: "create failed" });
    expect(manager.isActive(session.id)).toBe(false);
    expect(storage.getSession(session.id)?.status).not.toBe("ready");
  });
});
