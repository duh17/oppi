import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { RouteHandler, type RouteContext } from "../src/routes.js";
import { Storage } from "../src/storage.js";
import type { User } from "../src/types.js";

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
    name: "Chen",
    token: "sk_test",
    createdAt: Date.now(),
  };
}

describe("GET /security/profile", () => {
  let tempDir: string;

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "pi-remote-security-profile-"));
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
      allowLegacyV1Unsigned: false,
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
      makeUser(),
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
      invite: { format: string; allowLegacyV1Unsigned: boolean; maxAgeSeconds: number };
    };

    expect(body.profile).toBe("strict");
    expect(body.requireTlsOutsideTailnet).toBe(true);
    expect(body.allowInsecureHttpInTailnet).toBe(false);
    expect(body.requirePinnedServerIdentity).toBe(true);
    expect(body.identity.enabled).toBe(false);
    expect(body.identity.keyId).toBe("srv-test");
    expect(body.identity.fingerprint).toBe("sha256:test");
    expect(body.invite.format).toBe("v2-signed");
    expect(body.invite.allowLegacyV1Unsigned).toBe(false);
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
      makeUser(),
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
