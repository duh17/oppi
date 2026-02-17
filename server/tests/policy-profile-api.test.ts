import { describe, expect, it } from "vitest";
import { RouteHandler, type RouteContext } from "../src/routes.js";
import type { Workspace } from "../src/types.js";

interface MockResponse {
  statusCode: number;
  body: string;
  writeHead: (status: number, headers: Record<string, string>) => MockResponse;
  end: (payload?: string) => void;
}

function makeResponse(): MockResponse {
  return {
    statusCode: 0,
    body: "",
    writeHead(status: number): MockResponse {
      this.statusCode = status;
      return this;
    },
    end(payload?: string): void {
      this.body = payload ?? "";
    },
  };
}

function makeUser(): User {
  return {
    id: "u1",
    name: "Bob",
    token: "sk_test",
    createdAt: Date.now(),
  };
}

function makeWorkspace(policyPreset: string): Workspace {
  const now = Date.now();
  return {
    id: "w1",
    name: "Workspace",
    runtime: "host",
    skills: [],
    policyPreset,
    createdAt: now,
    updatedAt: now,
  };
}

function makeRoutes(workspace: Workspace): RouteHandler {
  const ctx = {
    storage: {
      getWorkspace: (workspaceId: string) =>
        workspaceId === workspace.id ? workspace : undefined,
    },
  } as unknown as RouteContext;

  return new RouteHandler(ctx);
}

describe("GET /policy/profile", () => {
  it("returns developer trust profile for host preset", async () => {
    const routes = makeRoutes(makeWorkspace("host"));
    const res = makeResponse();

    await routes.dispatch(
      "GET",
      "/policy/profile",
      new URL("http://localhost/policy/profile?workspaceId=w1"),
      {} as never,
      res as never,
    );

    expect(res.statusCode).toBe(200);
    const payload = JSON.parse(res.body) as {
      profile: {
        policyPreset: string;
        supervisionLevel: string;
        summary: string;
      };
    };

    expect(payload.profile.policyPreset).toBe("host");
    expect(payload.profile.supervisionLevel).toBe("standard");
    expect(payload.profile.summary).toContain("Developer Trust");
  });

  it("returns approval-first profile for host_standard", async () => {
    const routes = makeRoutes(makeWorkspace("host_standard"));
    const res = makeResponse();

    await routes.dispatch(
      "GET",
      "/policy/profile",
      new URL("http://localhost/policy/profile?workspaceId=w1"),
      {} as never,
      res as never,
    );

    expect(res.statusCode).toBe(200);
    const payload = JSON.parse(res.body) as {
      profile: {
        policyPreset: string;
        supervisionLevel: string;
        summary: string;
        needsApproval: Array<{ id: string }>;
      };
    };

    expect(payload.profile.policyPreset).toBe("host_standard");
    expect(payload.profile.supervisionLevel).toBe("high");
    expect(payload.profile.summary).toContain("approval-first");
    expect(payload.profile.needsApproval.some((item) => item.id === "default-ask")).toBe(true);
  });

  it("returns locked profile with default-deny visibility", async () => {
    const routes = makeRoutes(makeWorkspace("host_locked"));
    const res = makeResponse();

    await routes.dispatch(
      "GET",
      "/policy/profile",
      new URL("http://localhost/policy/profile?workspaceId=w1"),
      {} as never,
      res as never,
    );

    expect(res.statusCode).toBe(200);
    const payload = JSON.parse(res.body) as {
      profile: {
        policyPreset: string;
        supervisionLevel: string;
        summary: string;
        alwaysBlocked: Array<{ id: string }>;
      };
    };

    expect(payload.profile.policyPreset).toBe("host_locked");
    expect(payload.profile.supervisionLevel).toBe("high");
    expect(payload.profile.summary).toContain("unknown actions are blocked");
    expect(payload.profile.alwaysBlocked.some((item) => item.id === "default-deny")).toBe(true);
  });
});
