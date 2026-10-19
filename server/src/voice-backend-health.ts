/**
 * Voice backend health: one owner decides, per voice feature, whether its backend can serve.
 *
 * `/server/info` maps each feature's state to `capabilities.<feature>` (present only when
 * `ready`) and lists every feature in `voiceBackends` for About This Server → Voice.
 *
 * - xAI backends are cloud services: a credential (sign-in, stored key, `XAI_API_KEY`) is
 *   `ready`, with no network probe.
 * - HTTP backends are probed with one request to the endpoint origin. Any HTTP response is
 *   reachable (a 404 from a wrong path still answers); a network error or timeout is
 *   `unreachable`. Results are cached per origin, so dictation and local Live Voice share the
 *   ASR probe, and stay fresh for `ttlMs`.
 * - Reading state never waits on the network: a cold or stale origin starts one background
 *   probe (concurrent readers share it) and reads `checking` until a first result exists.
 *   The server warms the cache once at start; there is no timer.
 * - Real read-aloud and Live Voice TTS requests report back (`SpeechBackendObserver`): a
 *   connect failure marks the origin `unreachable` at once, a success marks it `ready`, and an
 *   HTTP error from a backend that answered keeps it `ready` with the failure as `detail`
 *   until the next successful request.
 */

import { hasVoiceProviderCredential, type SttGetAuth } from "./create-stt-provider.js";
import { isDictationStreamEnabled, resolveAsrProvider } from "./dictation-types.js";
import {
  isSpeechEnabled,
  resolveTtsProvider,
  type SpeechBackendObserver,
} from "./speech-synthesis.js";
import type { ServerConfig } from "./types.js";

export type VoiceFeature = "dictation" | "speech" | "liveVoice";

export type VoiceBackendState =
  "not_configured" | "needs_credentials" | "checking" | "unreachable" | "ready";

/** One `voiceBackends` entry in `GET /server/info`. */
export interface VoiceBackendHealthEntry {
  feature: VoiceFeature;
  /** Display label; the app shows it as sent. */
  label: string;
  state: VoiceBackendState;
  /** Endpoint origin or provider name, display only. */
  target?: string;
  /** Short reason for a non-ready state, or the last failed request of a ready backend. */
  detail?: string;
  /** Epoch ms of the last reachability result for an HTTP backend. */
  checkedAt?: number;
}

type VoiceConfig = Pick<ServerConfig, "asr" | "tts">;

export interface VoiceBackendHealthDeps {
  /** Config the server loaded: dictation and read aloud use it. */
  loadedConfig: () => VoiceConfig;
  /** Voice settings on disk now: each Live Voice call reads them. */
  voiceConfig: () => VoiceConfig;
  getAuth?: SttGetAuth;
  fetchFn?: typeof globalThis.fetch;
  now?: () => number;
  /** How long a reachability result stays fresh. */
  ttlMs?: number;
  /** Probe request timeout. */
  timeoutMs?: number;
}

export const VOICE_BACKEND_TTL_MS = 15_000;
export const VOICE_BACKEND_PROBE_TIMEOUT_MS = 1_500;

const LABELS: Record<VoiceFeature, string> = {
  dictation: "Dictation",
  speech: "Read aloud",
  liveVoice: "Live Voice",
};
const XAI_TARGET = "xAI";

interface Reachability {
  reachable: boolean;
  /** Network error for an unreachable origin. */
  detail?: string;
  /** Failed request against a reachable origin, cleared by the next success. */
  lastRequestFailure?: string;
  checkedAt: number;
}

/** Health of one backend before it is attached to a feature. */
interface BackendHealth {
  state: VoiceBackendState;
  target?: string;
  detail?: string;
  checkedAt?: number;
}

export class VoiceBackendHealth implements SpeechBackendObserver {
  private readonly results = new Map<string, Reachability>();
  private readonly probes = new Map<string, Promise<void>>();
  private readonly now: () => number;
  private readonly ttlMs: number;
  private readonly timeoutMs: number;
  private readonly fetchFn: typeof globalThis.fetch;

  constructor(private readonly deps: VoiceBackendHealthDeps) {
    this.now = deps.now ?? Date.now;
    this.ttlMs = deps.ttlMs ?? VOICE_BACKEND_TTL_MS;
    this.timeoutMs = deps.timeoutMs ?? VOICE_BACKEND_PROBE_TIMEOUT_MS;
    this.fetchFn = deps.fetchFn ?? globalThis.fetch;
  }

  /**
   * Every feature's state from cached reachability. Starts a background probe for each
   * configured HTTP origin that is cold or stale; never waits for one.
   */
  async entries(): Promise<VoiceBackendHealthEntry[]> {
    const loaded = this.deps.loadedConfig();
    const voice = this.deps.voiceConfig();
    const [dictation, speech, liveVoice] = await Promise.all([
      this.dictationHealth(loaded.asr),
      this.speechHealth(loaded.tts),
      this.liveVoiceHealth(voice),
    ]);
    return [entry("dictation", dictation), entry("speech", speech), entry("liveVoice", liveVoice)];
  }

  /**
   * Probe every configured HTTP origin that is cold or stale and wait for the results.
   * The server calls this once at start so the first `/server/info` rarely reads `checking`.
   */
  async refresh(): Promise<void> {
    const loaded = this.deps.loadedConfig();
    const voice = this.deps.voiceConfig();
    const localLiveVoice = (voice.asr?.liveVoiceBackend ?? "yuwp") === "yuwp";
    const endpoints = [
      httpAsrEndpoint(loaded.asr),
      httpTtsEndpoint(loaded.tts),
      ...(localLiveVoice ? [voice.asr?.sttEndpoint, httpTtsEndpoint(voice.tts)] : []),
    ];
    const origins = new Set(endpoints.flatMap((endpoint) => originOf(endpoint) ?? []));
    await Promise.all([...origins].map((origin) => this.ensureFresh(origin)));
  }

  // ─── SpeechBackendObserver: real read-aloud and Live Voice TTS requests ───

  requestSucceeded(endpoint: string): void {
    const origin = originOf(endpoint);
    if (origin) this.results.set(origin, { reachable: true, checkedAt: this.now() });
  }

  requestFailed(endpoint: string, message: string): void {
    const origin = originOf(endpoint);
    if (!origin) return;
    this.results.set(origin, {
      reachable: true,
      lastRequestFailure: `Last request failed: ${message}`,
      checkedAt: this.now(),
    });
  }

  connectFailed(endpoint: string, error: unknown): void {
    const origin = originOf(endpoint);
    if (!origin) return;
    this.results.set(origin, {
      reachable: false,
      detail: networkErrorDetail(error),
      checkedAt: this.now(),
    });
  }

  // ─── Features ───

  private async dictationHealth(asr: VoiceConfig["asr"]): Promise<BackendHealth> {
    const provider = resolveAsrProvider(asr);
    if (!provider || !isDictationStreamEnabled(asr)) return { state: "not_configured" };
    if (provider === "xai") return this.xaiHealth();
    return this.httpHealth(asr?.sttEndpoint ?? "");
  }

  private async speechHealth(tts: VoiceConfig["tts"]): Promise<BackendHealth> {
    const provider = resolveTtsProvider(tts);
    if (!provider || !isSpeechEnabled(tts)) return { state: "not_configured" };
    if (provider === "xai") return this.xaiHealth();
    return this.httpHealth(tts?.endpoint ?? "");
  }

  /**
   * `grok-voice` needs an xAI credential. `yuwp` (the default) needs its ASR endpoint
   * reachable and, when `tts` is configured, the voice too; without `tts` a call runs
   * silent, so the voice is not required.
   */
  private async liveVoiceHealth({ asr, tts }: VoiceConfig): Promise<BackendHealth> {
    const backend = asr?.liveVoiceBackend ?? "yuwp";
    if (backend === "grok-voice") return this.xaiHealth();
    if (backend !== "yuwp") {
      return { state: "not_configured", detail: `Unknown Live Voice backend "${String(backend)}"` };
    }
    const endpoint = asr?.sttEndpoint?.trim();
    if (!endpoint) return { state: "not_configured" };
    const listening = this.httpHealth(endpoint);
    if (listening.state !== "ready" || !isSpeechEnabled(tts)) return listening;
    const voice = await this.speechHealth(tts);
    if (voice.state === "ready") {
      return { ...listening, detail: voice.detail ? `Voice: ${voice.detail}` : listening.detail };
    }
    const voiceTarget = voice.target ? ` at ${voice.target}` : "";
    return {
      state: voice.state,
      target: listening.target,
      detail: `Voice${voiceTarget}: ${voice.detail ?? stateReason(voice.state)}`,
      checkedAt: voice.checkedAt,
    };
  }

  private async xaiHealth(): Promise<BackendHealth> {
    const credentialed = await hasVoiceProviderCredential("xai", this.deps.getAuth);
    return credentialed
      ? { state: "ready", target: XAI_TARGET }
      : {
          state: "needs_credentials",
          target: XAI_TARGET,
          detail: "Sign in to xAI or set an API key",
        };
  }

  // ─── Reachability ───

  private httpHealth(endpoint: string): BackendHealth {
    const origin = originOf(endpoint);
    if (!origin) {
      return {
        state: "unreachable",
        target: endpoint.trim(),
        detail: "Endpoint is not a valid URL",
      };
    }
    void this.ensureFresh(origin);
    const result = this.results.get(origin);
    if (!result) return { state: "checking", target: origin };
    return {
      state: result.reachable ? "ready" : "unreachable",
      target: origin,
      detail: result.reachable ? result.lastRequestFailure : result.detail,
      checkedAt: result.checkedAt,
    };
  }

  /** One probe per origin at a time; nothing when the cached result is fresh. */
  private ensureFresh(origin: string): Promise<void> {
    const cached = this.results.get(origin);
    if (cached && this.now() - cached.checkedAt < this.ttlMs) return Promise.resolve();
    const inFlight = this.probes.get(origin);
    if (inFlight) return inFlight;
    const probe = this.probe(origin).finally(() => this.probes.delete(origin));
    this.probes.set(origin, probe);
    return probe;
  }

  private async probe(origin: string): Promise<void> {
    const previous = this.results.get(origin);
    let outcome: Pick<Reachability, "reachable" | "detail">;
    try {
      const response = await this.fetchFn(`${origin}/`, {
        method: "GET",
        signal: AbortSignal.timeout(this.timeoutMs),
      });
      // Any status means the backend answered; the body is not needed.
      await response.body?.cancel().catch(() => undefined);
      outcome = { reachable: true };
    } catch (error) {
      outcome = {
        reachable: false,
        detail: isTimeout(error)
          ? `No answer within ${this.timeoutMs} ms`
          : networkErrorDetail(error),
      };
    }
    // A real request that finished while this probe ran is newer evidence.
    if (this.results.get(origin) !== previous) return;
    this.results.set(origin, {
      ...outcome,
      // A request failure stays until a request succeeds, while the backend keeps answering.
      lastRequestFailure:
        outcome.reachable && previous?.reachable ? previous.lastRequestFailure : undefined,
      checkedAt: this.now(),
    });
  }
}

/** Features whose state is `ready`: `/server/info` advertises exactly these. */
export function readyVoiceFeatures(entries: VoiceBackendHealthEntry[]): Set<VoiceFeature> {
  return new Set(entries.filter((e) => e.state === "ready").map((e) => e.feature));
}

function entry(feature: VoiceFeature, health: BackendHealth): VoiceBackendHealthEntry {
  return {
    feature,
    label: LABELS[feature],
    state: health.state,
    ...(health.target ? { target: health.target } : {}),
    ...(health.detail ? { detail: health.detail } : {}),
    ...(health.checkedAt !== undefined ? { checkedAt: health.checkedAt } : {}),
  };
}

function stateReason(state: VoiceBackendState): string {
  switch (state) {
    case "checking":
      return "checking";
    case "needs_credentials":
      return "needs credentials";
    case "unreachable":
      return "not reachable";
    default:
      return "not set up";
  }
}

function httpAsrEndpoint(asr: VoiceConfig["asr"]): string | undefined {
  return resolveAsrProvider(asr) === "http" && isDictationStreamEnabled(asr)
    ? asr?.sttEndpoint
    : undefined;
}

function httpTtsEndpoint(tts: VoiceConfig["tts"]): string | undefined {
  return resolveTtsProvider(tts) === "http" && isSpeechEnabled(tts) ? tts?.endpoint : undefined;
}

function originOf(endpoint: string | undefined): string | undefined {
  const trimmed = endpoint?.trim();
  if (!trimmed) return undefined;
  try {
    const url = new URL(trimmed);
    return url.protocol === "http:" || url.protocol === "https:" ? url.origin : undefined;
  } catch {
    return undefined;
  }
}

function isTimeout(error: unknown): boolean {
  return error instanceof Error && (error.name === "TimeoutError" || error.name === "AbortError");
}

/** `fetch failed` hides the reason in `cause` (e.g. `connect ECONNREFUSED 127.0.0.1:7938`). */
export function networkErrorDetail(error: unknown): string {
  const cause = error instanceof Error ? (error.cause as unknown) : undefined;
  if (cause instanceof Error && cause.message) return cause.message;
  if (cause && typeof cause === "object" && "code" in cause) return String(cause.code);
  return error instanceof Error ? error.message : String(error);
}
