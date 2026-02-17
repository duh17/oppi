import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { EventEmitter } from "node:events";
import { RouteHandler, type RouteContext } from "../src/routes.js";
import { Storage } from "../src/storage.js";

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

function makeJsonRequest(payload: unknown): never {
  const req = new EventEmitter() as unknown as {
    emit: (event: string, ...args: unknown[]) => boolean;
  };

  queueMicrotask(() => {
    req.emit("data", Buffer.from(JSON.stringify(payload)));
    req.emit("end");
  });

  return req as never;
}

describe("GET /security/profile", () => {
  let tempDir: string;

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "oppi-server-security-profile-"));
  });

  afterEach(() => {
    rmSync(tempDir, { recursive: true, force: true });
  });

  it("returns effective server security posture", async () => {
    const config = Storage.getDefaultConfig(tempDir);
    config.security = {
      profile: "strict",
      requireTlsOutsideTailnet: true,
      allowInsecureHttpInTailnet: false,
      requirePinnedServerIdentity: true,
    };
    config.identity = {
      ...config.identity!,
      enabled: false,
      keyId: "srv-test",
      fingerprint: "sha256:test",
    };
    config.invite = {
      ...config.invite!,
      format: "v2-signed",
      maxAgeSeconds: 90,
    };

    const ctx = {
      storage: {
        getConfig: vi.fn(() => config),
        updateConfig: vi.fn(),
      },
    } as unknown as RouteContext;

    const routes = new RouteHandler(ctx);
    const res = makeResponse();

    await routes.dispatch(
      "GET",
      "/security/profile",
      new URL("http://localhost/security/profile"),
      {} as never,
      res as never,
    );

    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body) as {
      profile: string;
      requireTlsOutsideTailnet: boolean;
      allowInsecureHttpInTailnet: boolean;
      requirePinnedServerIdentity: boolean;
      identity: { enabled: boolean; keyId: string; fingerprint: string };
      invite: { format: string; maxAgeSeconds: number };
    };

    expect(body.profile).toBe("strict");
    expect(body.requireTlsOutsideTailnet).toBe(true);
    expect(body.allowInsecureHttpInTailnet).toBe(false);
    expect(body.requirePinnedServerIdentity).toBe(true);
    expect(body.identity.enabled).toBe(false);
    expect(body.identity.keyId).toBe("srv-test");
    expect(body.identity.fingerprint).toBe("sha256:test");
    expect(body.invite.format).toBe("v2-signed");
    expect(body.invite.maxAgeSeconds).toBe(90);
  });

  it("hydrates identity fingerprint from key material and persists it", async () => {
    const config = Storage.getDefaultConfig(tempDir);
    config.identity = {
      ...config.identity!,
      enabled: true,
      keyId: "srv-test",
      privateKeyPath: join(tempDir, "identity_ed25519"),
      publicKeyPath: join(tempDir, "identity_ed25519.pub"),
      fingerprint: "sha256:stale",
    };

    const updateConfig = vi.fn();

    const ctx = {
      storage: {
        getConfig: vi.fn(() => config),
        updateConfig,
      },
    } as unknown as RouteContext;

    const routes = new RouteHandler(ctx);
    const res = makeResponse();

    await routes.dispatch(
      "GET",
      "/security/profile",
      new URL("http://localhost/security/profile"),
      {} as never,
      res as never,
    );

    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body) as {
      identity: { fingerprint: string; keyId: string };
    };

    expect(body.identity.keyId).toBe("srv-test");
    expect(body.identity.fingerprint.startsWith("sha256:")).toBe(true);
    expect(body.identity.fingerprint).not.toBe("sha256:stale");

    expect(updateConfig).toHaveBeenCalledTimes(1);
    const updateArg = updateConfig.mock.calls[0]?.[0] as {
      identity?: { fingerprint?: string };
    };
    expect(updateArg.identity?.fingerprint).toBe(body.identity.fingerprint);
  });
});

describe("PUT /security/profile", () => {
  it("updates security toggles and invite max age", async () => {
    const config = Storage.getDefaultConfig(join(tmpdir(), "oppi-server-security-profile-put"));
    config.security = {
      profile: "tailscale-permissive",
      requireTlsOutsideTailnet: true,
      allowInsecureHttpInTailnet: true,
      requirePinnedServerIdentity: true,
    };
    config.invite = {
      ...config.invite!,
      format: "v2-signed",
      singleUse: false,
      maxAgeSeconds: 600,
    };
    config.identity = {
      ...config.identity!,
      enabled: false,
    };

    const updateConfig = vi.fn(
      (updates: {
        security?: {
          profile: string;
          requireTlsOutsideTailnet: boolean;
          allowInsecureHttpInTailnet: boolean;
          requirePinnedServerIdentity: boolean;
        };
        invite?: { format: string; singleUse: boolean; maxAgeSeconds: number };
      }) => {
        if (updates.security) {
          config.security = {
            profile: updates.security.profile as "legacy" | "tailscale-permissive" | "strict",
            requireTlsOutsideTailnet: updates.security.requireTlsOutsideTailnet,
            allowInsecureHttpInTailnet: updates.security.allowInsecureHttpInTailnet,
            requirePinnedServerIdentity: updates.security.requirePinnedServerIdentity,
          };
        }
        if (updates.invite) {
          config.invite = {
            format: "v2-signed",
            singleUse: updates.invite.singleUse,
            maxAgeSeconds: updates.invite.maxAgeSeconds,
          };
        }
      },
    );

    const ctx = {
      storage: {
        getConfig: vi.fn(() => config),
        updateConfig,
      },
    } as unknown as RouteContext;

    const routes = new RouteHandler(ctx);
    const res = makeResponse();

    await routes.dispatch(
      "PUT",
      "/security/profile",
      new URL("http://localhost/security/profile"),
      makeJsonRequest({
        profile: "strict",
        requireTlsOutsideTailnet: true,
        allowInsecureHttpInTailnet: false,
        requirePinnedServerIdentity: true,
        invite: { maxAgeSeconds: 300 },
      }),
      res as never,
    );

    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body) as {
      profile: string;
      allowInsecureHttpInTailnet: boolean;
      invite: { maxAgeSeconds: number };
    };

    expect(updateConfig).toHaveBeenCalledTimes(1);
    expect(body.profile).toBe("strict");
    expect(body.allowInsecureHttpInTailnet).toBe(false);
    expect(body.invite.maxAgeSeconds).toBe(300);
  });

  it("rejects invalid invite maxAgeSeconds", async () => {
    const config = Storage.getDefaultConfig(join(tmpdir(), "oppi-server-security-profile-put-invalid"));

    const ctx = {
      storage: {
        getConfig: vi.fn(() => config),
        updateConfig: vi.fn(),
      },
    } as unknown as RouteContext;

    const routes = new RouteHandler(ctx);
    const res = makeResponse();

    await routes.dispatch(
      "PUT",
      "/security/profile",
      new URL("http://localhost/security/profile"),
      makeJsonRequest({ invite: { maxAgeSeconds: 0 } }),
      res as never,
    );

    expect(res.statusCode).toBe(400);
    const body = JSON.parse(res.body) as { error: string };
    expect(body.error).toContain("invite.maxAgeSeconds");
  });
});
