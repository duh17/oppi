import { describe, expect, it } from "vitest";
import { createSttProvider, resolveSttBearerToken } from "../src/create-stt-provider.js";
import { resolveAsrProvider, type DictationConfig } from "../src/dictation-types.js";
import { StreamingSttProvider } from "../src/stt-provider.js";
import { XaiSttProvider } from "../src/xai-stt-provider.js";

describe("createSttProvider", () => {
  it("keeps Yuwp session STT for http endpoints", () => {
    const provider = createSttProvider({
      sttEndpoint: "http://127.0.0.1:7936",
      sttModel: "test-model",
    });
    expect(provider).toBeInstanceOf(StreamingSttProvider);
    expect(provider.name).toBe("streaming-127.0.0.1");
  });

  it.each(["openai", "openai-codex"])(
    "rejects removed provider %s without auth or HTTP fallback",
    (provider) => {
      let authCalls = 0;
      expect(() =>
        createSttProvider(
          { provider, sttEndpoint: "https://api.openai.com", sttModel: "test" } as DictationConfig,
          {
            resolveApiKey: () => {
              authCalls++;
              return "unused";
            },
          },
        ),
      ).toThrow("STT provider must be http or xai");
      expect(authCalls).toBe(0);
    },
  );

  it("selects xAI for asr.provider xai", () => {
    const provider = createSttProvider(
      { provider: "xai", sttModel: "grok-stt" },
      { resolveApiKey: () => "xai-test" },
    );
    expect(provider).toBeInstanceOf(XaiSttProvider);
    expect(provider.name).toBe("xai");
  });

  it("prefers ModelRuntime.getAuth bearers, including OAuth access tokens", async () => {
    const seen: string[] = [];
    await expect(
      resolveSttBearerToken("xai", {
        getAuth: async (providerId) => {
          seen.push(providerId);
          return { auth: { apiKey: "oauth-access" } };
        },
        fallback: () => "should-not-use",
      }),
    ).resolves.toBe("oauth-access");
    expect(seen).toEqual(["xai"]);
  });

  it("uses the credential fallback when Pi auth is unavailable", async () => {
    await expect(
      resolveSttBearerToken("xai", {
        getAuth: async () => {
          throw new Error("unavailable");
        },
        fallback: () => "xai-key",
      }),
    ).resolves.toBe("xai-key");
  });

  it("only infers xAI from a vendor hostname; other endpoints use the HTTP session contract", () => {
    expect(resolveAsrProvider({ sttEndpoint: "https://api.x.ai" })).toBe("xai");
    expect(resolveAsrProvider({ sttEndpoint: "https://api.openai.com" })).toBe("http");
    expect(resolveAsrProvider({ provider: "http", sttEndpoint: "https://api.x.ai" })).toBe("http");
  });
});
