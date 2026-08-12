import { EventEmitter } from "node:events";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

import { ResourceUsageService } from "../src/resource-usage-service.js";
import { ResourceUsageStore } from "../src/storage/resource-usage-store.js";
import { createResourceUsageRoutes } from "../src/routes/resource-usage.js";

const SKILL_ID = `skill_${"a".repeat(64)}`;
const EXTENSION_ID = `extension_${"b".repeat(64)}`;

function response() {
  return {
    statusCode: 200,
    payload: undefined as unknown,
    writeHead(status: number) {
      this.statusCode = status;
    },
    end(body?: string) {
      this.payload = body ? JSON.parse(body) : undefined;
    },
  };
}

const dirs: string[] = [];

afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function harness(getUsage = vi.fn().mockResolvedValue({ recordedActions: 0 })) {
  const helpers = {
    parseBody: vi.fn(),
    json: (res: ReturnType<typeof response>, data: unknown, status = 200) => {
      res.statusCode = status;
      res.payload = data;
    },
    compressedJson: vi.fn(),
    error: (res: ReturnType<typeof response>, status: number, message: string) => {
      res.statusCode = status;
      res.payload = { error: message };
    },
  };
  const dispatch = createResourceUsageRoutes(
    { resourceUsage: { getUsage } } as never,
    helpers as never,
  );
  return { dispatch, getUsage };
}

async function get(
  dispatch: ReturnType<typeof createResourceUsageRoutes>,
  path: string,
  query: string,
) {
  const res = response();
  await dispatch({
    method: "GET",
    path,
    url: new URL(`http://localhost${path}${query}`),
    req: new EventEmitter() as never,
    res: res as never,
  });
  return res;
}

describe("resource usage routes", () => {
  it("serves Skill, Extension, and global Tool Activity through indexed usage reads", async () => {
    const { dispatch, getUsage } = harness();

    expect(
      (await get(dispatch, `/server/resources/skills/${SKILL_ID}/usage`, "?range=30&timezone=UTC"))
        .statusCode,
    ).toBe(200);
    expect(
      (
        await get(
          dispatch,
          `/server/resources/extensions/${EXTENSION_ID}/usage`,
          "?range=7&timezone=America%2FLos_Angeles",
        )
      ).statusCode,
    ).toBe(200);
    expect(
      (await get(dispatch, "/server/stats/tool-activity", "?range=90&timezone=Asia%2FTokyo"))
        .statusCode,
    ).toBe(200);

    expect(getUsage.mock.calls).toEqual([
      [{ kind: "skill", id: SKILL_ID }, 30, "UTC"],
      [{ kind: "extension", id: EXTENSION_ID }, 7, "America/Los_Angeles"],
      [{ kind: "tools" }, 90, "Asia/Tokyo"],
    ]);
  });

  it.each([
    ["?range=14&timezone=UTC", "range"],
    ["?range=30&timezone=Not%2FAZone", "timezone"],
    ["?range=30", "timezone"],
    ["?range=30&timezone=UTC&extra=1", "query"],
  ])("rejects invalid query %s", async (query, expectedError) => {
    const { dispatch, getUsage } = harness();
    const res = await get(dispatch, "/server/stats/tool-activity", query);

    expect(res.statusCode).toBe(400);
    expect(res.payload).toEqual({ error: expect.stringContaining(expectedError) });
    expect(getUsage).not.toHaveBeenCalled();
  });

  it("does not read the real trace/filesystem boundary on a GET", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-resource-usage-route-"));
    dirs.push(dir);
    const store = new ResourceUsageStore(dir);
    const service = new ResourceUsageService(store);
    const { dispatch } = harness(service.getUsage.bind(service) as never);

    const res = await get(
      dispatch,
      `/server/resources/skills/${SKILL_ID}/usage`,
      "?range=30&timezone=UTC",
    );

    expect(res.statusCode).toBe(200);
    expect(res.payload).toMatchObject({
      recordedActions: 0,
      recordingStartedAt: expect.any(Number),
      capture: { status: "active" },
      retainedHistory: { retentionDays: 120 },
    });
    await service.close();
  });
});
