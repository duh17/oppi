import { describe, expect, it } from "vitest";
import { createSttProvider, resolveSttBearerToken } from "../src/create-stt-provider.js";
import { OpenAiSttProvider } from "../src/openai-stt-provider.js";
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

  it("selects OpenAI transcriptions for asr.provider openai-codex", () => {
    const provider = createSttProvider(
      { provider: "openai-codex", sttModel: "gpt-4o-mini-transcribe" },
      { resolveApiKey: () => "sk-test" },
    );
    expect(provider).toBeInstanceOf(OpenAiSttProvider);
    expect(provider.name).toBe("openai-codex");
  });

  it("selects xAI for asr.provider xai", () => {
    const provider = createSttProvider(
      { provider: "xai", sttModel: "grok-stt" },
      { resolveApiKey: () => "xai-test" },
    );
    expect(provider).toBeInstanceOf(XaiSttProvider);
    expect(provider.name).toBe("xai");
  });

  it("prefers ModelRuntime.getAuth bearers, including OAuth access tokens", async () => {
    await expect(
      resolveSttBearerToken("xai", {
        getAuth: async () => ({ auth: { apiKey: "oauth-access" } }),
        fallback: () => "should-not-use",
      }),
    ).resolves.toBe("oauth-access");
    await expect(
      resolveSttBearerToken("openai-codex", {
        getAuth: async () => ({ auth: { apiKey: "codex-token" } }),
        fallback: () => "should-not-use",
      }),
    ).resolves.toBe("codex-token");
  });

  it("asks Pi auth for openai-codex, not a separate openai STT provider id", async () => {
    const seen: string[] = [];
    await expect(
      resolveSttBearerToken("openai-codex", {
        getAuth: async (providerId) => {
          seen.push(providerId);
          return { auth: { apiKey: "codex-token" } };
        },
        fallback: () => undefined,
      }),
    ).resolves.toBe("codex-token");
    expect(seen).toEqual(["openai-codex"]);
  });

  it("infers OpenAI from api.openai.com even without asr.provider", () => {
    const provider = createSttProvider(
      { sttEndpoint: "https://api.openai.com", sttModel: "gpt-4o-mini-transcribe" },
      { resolveApiKey: () => "sk-test" },
    );
    expect(provider).toBeInstanceOf(OpenAiSttProvider);
  });
});
