import { Readable } from "node:stream";
import { describe, expect, it } from "vitest";
import { RouteHandler, type RouteContext } from "../src/routes.js";
import type { PolicyPermission, Workspace } from "../src/types.js";

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

function makeRequest(body?: unknown): Readable {
  const text = body === undefined ? "" : JSON.stringify(body);
  return Readable.from(text ? [text] : []);
}

function makeWorkspace(): Workspace {
  const now = Date.now();
  return {
    id: "w1",
    name: "Workspace",
    runtime: "host",
    skills: [],
    policy: { permissions: [] },
    createdAt: now,
    updatedAt: now,
  };
}

function makeRoutes(workspace: Workspace): RouteHandler {
  const globalPolicy = {
    schemaVersion: 1 as const,
    fallback: "ask" as const,
    guardrails: [
      {
        id: "block-secret-files",
        decision: "block" as const,
        immutable: true,
        match: { tool: "read", pathMatches: "*identity_ed25519*" },
      },
    ],
    permissions: [
      {
        id: "ask-git-push",
        decision: "ask" as const,
        match: { tool: "bash", executable: "git", commandMatches: "git push*" },
      },
    ],
  };

  const storage = {
    getConfig: () => ({ policy: globalPolicy }),
    getWorkspace: (id: string) => (id === workspace.id ? workspace : undefined),
    setWorkspacePolicyPermissions: (
      id: string,
      permissions: PolicyPermission[],
      fallback?: "allow" | "ask" | "block",
    ) => {
      if (id !== workspace.id) return undefined;
      const nextFallback = fallback ?? workspace.policy?.fallback;
      workspace.policy = nextFallback ? { permissions, fallback: nextFallback } : { permissions };
      workspace.updatedAt = Date.now();
      return workspace;
    },
    deleteWorkspacePolicyPermission: (id: string, permissionId: string) => {
      if (id !== workspace.id) return undefined;
      workspace.policy = {
        permissions: (workspace.policy?.permissions || []).filter((p) => p.id !== permissionId),
      };
      workspace.updatedAt = Date.now();
      return workspace;
    },
  };

  const ctx = { storage } as unknown as RouteContext;
  return new RouteHandler(ctx);
}

describe("workspace policy API", () => {
  it("GET /workspaces/:id/policy returns effective merged policy", async () => {
    const workspace = makeWorkspace();
    workspace.policy = {
      permissions: [
        {
          id: "allow-npm-test",
          decision: "allow",
          match: { tool: "bash", executable: "npm", commandMatches: "npm test*" },
        },
      ],
    };

    const routes = makeRoutes(workspace);
    const res = makeResponse();

    await routes.dispatch(
      "GET",
      "/workspaces/w1/policy",
      new URL("http://localhost/workspaces/w1/policy"),
      makeRequest() as never,
      res as never,
    );

    expect(res.statusCode).toBe(200);
    const payload = JSON.parse(res.body) as {
      effectivePolicy: { permissions: PolicyPermission[] };
    };

    expect(payload.effectivePolicy.permissions.map((p) => p.id)).toEqual([
      "ask-git-push",
      "allow-npm-test",
    ]);
  });

  it("PATCH updates workspace fallback override", async () => {
    const workspace = makeWorkspace();
    const routes = makeRoutes(workspace);
    const res = makeResponse();

    await routes.dispatch(
      "PATCH",
      "/workspaces/w1/policy",
      new URL("http://localhost/workspaces/w1/policy"),
      makeRequest({ fallback: "allow" }) as never,
      res as never,
    );

    expect(res.statusCode).toBe(200);
    expect(workspace.policy?.fallback).toBe("allow");

    const getRes = makeResponse();
    await routes.dispatch(
      "GET",
      "/workspaces/w1/policy",
      new URL("http://localhost/workspaces/w1/policy"),
      makeRequest() as never,
      getRes as never,
    );

    const payload = JSON.parse(getRes.body) as {
      effectivePolicy: { fallback: string };
    };
    expect(payload.effectivePolicy.fallback).toBe("allow");
  });

  it("PATCH toggles fallback ask ⇄ allow repeatedly", async () => {
    const workspace = makeWorkspace();
    const routes = makeRoutes(workspace);

    const patchFallback = async (fallback: "allow" | "ask") => {
      const res = makeResponse();
      await routes.dispatch(
        "PATCH",
        "/workspaces/w1/policy",
        new URL("http://localhost/workspaces/w1/policy"),
        makeRequest({ fallback }) as never,
        res as never,
      );
      expect(res.statusCode).toBe(200);

      const payload = JSON.parse(res.body) as {
        policy: { fallback?: string };
      };
      expect(payload.policy.fallback).toBe(fallback);
    };

    await patchFallback("ask");
    await patchFallback("allow");
    await patchFallback("ask");
    await patchFallback("allow");

    const getRes = makeResponse();
    await routes.dispatch(
      "GET",
      "/workspaces/w1/policy",
      new URL("http://localhost/workspaces/w1/policy"),
      makeRequest() as never,
      getRes as never,
    );

    const effective = JSON.parse(getRes.body) as {
      effectivePolicy: { fallback: string };
    };
    expect(effective.effectivePolicy.fallback).toBe("allow");
  });

  it("PATCH rejects workspace permission that weakens matching global rule", async () => {
    const workspace = makeWorkspace();
    const routes = makeRoutes(workspace);
    const res = makeResponse();

    await routes.dispatch(
      "PATCH",
      "/workspaces/w1/policy",
      new URL("http://localhost/workspaces/w1/policy"),
      makeRequest({
        permissions: [
          {
            id: "allow-git-push",
            decision: "allow",
            match: { tool: "bash", executable: "git", commandMatches: "git push*" },
          },
        ],
      }) as never,
      res as never,
    );

    expect(res.statusCode).toBe(400);
    expect(JSON.parse(res.body).error).toContain("cannot weaken global decision");
  });

  it("PATCH + DELETE lifecycle updates workspace permissions", async () => {
    const workspace = makeWorkspace();
    const routes = makeRoutes(workspace);

    const patchRes = makeResponse();
    await routes.dispatch(
      "PATCH",
      "/workspaces/w1/policy",
      new URL("http://localhost/workspaces/w1/policy"),
      makeRequest({
        permissions: [
          {
            id: "allow-npm-test",
            decision: "allow",
            match: { tool: "bash", executable: "npm", commandMatches: "npm test*" },
          },
        ],
      }) as never,
      patchRes as never,
    );

    expect(patchRes.statusCode).toBe(200);
    expect(workspace.policy?.permissions.map((p) => p.id)).toEqual(["allow-npm-test"]);

    const deleteRes = makeResponse();
    await routes.dispatch(
      "DELETE",
      "/workspaces/w1/policy/permissions/allow-npm-test",
      new URL("http://localhost/workspaces/w1/policy/permissions/allow-npm-test"),
      makeRequest() as never,
      deleteRes as never,
    );

    expect(deleteRes.statusCode).toBe(200);
    expect(workspace.policy?.permissions).toEqual([]);
  });
});
