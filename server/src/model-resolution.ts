import type { ModelRegistry } from "@earendil-works/pi-coding-agent";
import type { Api, Model } from "@earendil-works/pi-ai";

export type ModelAuthKind = "subscription" | "local" | "apiKey";
export type ModelThinkingLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh";

// The optional suffix recognizes schedule failures persisted before the typed error existed.
const REQUIRED_MODEL_UNAVAILABLE_PATTERN =
  /^Required model "[\s\S]+" is not available(?:; refusing model fallback)?$/;

export class RequiredModelUnavailableError extends Error {
  constructor(readonly model: string) {
    super(`Required model "${model}" is not available; refusing model fallback`);
    this.name = "RequiredModelUnavailableError";
  }
}

export function isRequiredModelUnavailableMessage(message: string | undefined): boolean {
  return typeof message === "string" && REQUIRED_MODEL_UNAVAILABLE_PATTERN.test(message);
}

export function isRequiredModelUnavailableError(error: unknown): boolean {
  return (
    error instanceof RequiredModelUnavailableError ||
    (error instanceof Error && isRequiredModelUnavailableMessage(error.message))
  );
}

export interface ModelResolutionInfo {
  /** Canonical provider/model-id. */
  id: string;
  name?: string;
  provider?: string;
  authKind?: ModelAuthKind;
  contextWindow?: number;
}

export interface ModelResolutionCandidate<TModel = unknown> {
  model: TModel;
  canonicalId: string;
  provider: string;
  modelId: string;
  name: string;
  contextWindow?: number;
  authKind?: ModelAuthKind;
  index: number;
}

export interface ModelResolutionResult<TModel = unknown> {
  candidate: ModelResolutionCandidate<TModel>;
  thinkingLevel?: ModelThinkingLevel;
  alternatives: Array<ModelResolutionCandidate<TModel>>;
}

type RegistryModel = Model<Api> & { baseUrl?: string };

type RegistryForResolution = Pick<ModelRegistry, "getAvailable" | "getAll"> & {
  isUsingOAuth?: (model: Model<Api>) => boolean;
};

const THINKING_LEVELS = new Set<ModelThinkingLevel>([
  "off",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
]);

function splitCanonicalModelId(id: string): { provider: string; modelId: string } | undefined {
  const slash = id.indexOf("/");
  if (slash <= 0 || slash === id.length - 1) return undefined;
  return { provider: id.substring(0, slash), modelId: id.substring(slash + 1) };
}

export function stripModelThinkingLevel(raw: string): {
  model: string;
  thinkingLevel?: ModelThinkingLevel;
} {
  const trimmed = raw.trim();
  const colonIndex = trimmed.lastIndexOf(":");
  if (colonIndex === -1) return { model: trimmed };

  const suffix = trimmed.substring(colonIndex + 1) as ModelThinkingLevel;
  if (!THINKING_LEVELS.has(suffix)) return { model: trimmed };
  return { model: trimmed.substring(0, colonIndex), thinkingLevel: suffix };
}

export function normalizeModelSearchText(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]/g, "");
}

function searchTokens(value: string): string[] {
  return value
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .map((token) => token.trim())
    .filter((token) => token.length > 0);
}

function isAliasModelId(id: string): boolean {
  if (id.endsWith("-latest")) return true;
  return !/-\d{8}$/.test(id);
}

function authPriority(kind: ModelAuthKind | undefined): number {
  if (kind === "subscription") return 3;
  if (kind === "local") return 2;
  if (kind === "apiKey") return 1;
  return 0;
}

function levenshteinDistance(a: string, b: string): number {
  if (a === b) return 0;
  if (a.length === 0) return b.length;
  if (b.length === 0) return a.length;

  let previous = Array.from({ length: b.length + 1 }, (_value, index) => index);
  let current = new Array<number>(b.length + 1);

  for (let i = 1; i <= a.length; i++) {
    current[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      current[j] = Math.min(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + cost);
    }
    [previous, current] = [current, previous];
  }

  return previous[b.length] ?? Number.POSITIVE_INFINITY;
}

function tokenMatches(queryToken: string, targetToken: string): boolean {
  if (targetToken.includes(queryToken)) return true;
  if (queryToken.length >= 5 && queryToken.includes(targetToken)) return true;
  if (queryToken.length < 4 || targetToken.length < 4) return false;
  const maxDistance = Math.max(1, Math.floor(Math.min(queryToken.length, targetToken.length) / 4));
  return levenshteinDistance(queryToken, targetToken) <= maxDistance;
}

function allQueryTokensMatch(query: string, candidate: ModelResolutionCandidate): boolean {
  const queryTokens = searchTokens(query);
  if (queryTokens.length === 0) return false;
  const targetTokens = searchTokens(
    `${candidate.canonicalId} ${candidate.modelId} ${candidate.name} ${candidate.provider}`,
  );
  return queryTokens.every((queryToken) =>
    targetTokens.some((targetToken) => tokenMatches(queryToken, targetToken)),
  );
}

function scoreAgainstCandidate(query: string, candidate: ModelResolutionCandidate): number {
  const raw = query.trim();
  if (!raw) return 0;

  const rawLower = raw.toLowerCase();
  const canonicalLower = candidate.canonicalId.toLowerCase();
  const modelIdLower = candidate.modelId.toLowerCase();
  const nameLower = candidate.name.toLowerCase();

  if (canonicalLower === rawLower) return 1000;
  if (modelIdLower === rawLower) return 950;
  if (nameLower === rawLower) return 900;

  const normalizedQuery = normalizeModelSearchText(raw);
  if (!normalizedQuery) return 0;

  const normalizedCanonical = normalizeModelSearchText(candidate.canonicalId);
  const normalizedModelId = normalizeModelSearchText(candidate.modelId);
  const normalizedName = normalizeModelSearchText(candidate.name);
  const normalizedProvider = normalizeModelSearchText(candidate.provider);

  if (normalizedCanonical === normalizedQuery) return 850;
  if (normalizedModelId === normalizedQuery) return 825;
  if (normalizedName === normalizedQuery) return 800;

  const slashIndex = raw.indexOf("/");
  if (slashIndex > 0) {
    const requestedProvider = normalizeModelSearchText(raw.substring(0, slashIndex));
    if (requestedProvider && requestedProvider !== normalizedProvider) return 0;
    const requestedModel = raw.substring(slashIndex + 1);
    const scopedScore = scoreAgainstCandidate(requestedModel, candidate);
    return scopedScore > 0 ? Math.min(790, scopedScore + 25) : 0;
  }

  if (normalizedModelId.includes(normalizedQuery)) {
    return 700 + Math.min(normalizedQuery.length, 80);
  }
  if (normalizedName.includes(normalizedQuery)) {
    return 650 + Math.min(normalizedQuery.length, 80);
  }
  if (normalizedCanonical.includes(normalizedQuery)) {
    return 600 + Math.min(normalizedQuery.length, 80);
  }

  if (allQueryTokensMatch(raw, candidate)) {
    const tokenLength = searchTokens(raw).reduce((sum, token) => sum + token.length, 0);
    return 400 + Math.min(tokenLength, 80);
  }

  return 0;
}

function compareCandidates<TModel>(
  lhs: { candidate: ModelResolutionCandidate<TModel>; score: number },
  rhs: { candidate: ModelResolutionCandidate<TModel>; score: number },
): number {
  if (lhs.score !== rhs.score) return rhs.score - lhs.score;

  const lhsAuth = authPriority(lhs.candidate.authKind);
  const rhsAuth = authPriority(rhs.candidate.authKind);
  if (lhsAuth !== rhsAuth) return rhsAuth - lhsAuth;

  const lhsAlias = isAliasModelId(lhs.candidate.modelId) ? 1 : 0;
  const rhsAlias = isAliasModelId(rhs.candidate.modelId) ? 1 : 0;
  if (lhsAlias !== rhsAlias) return rhsAlias - lhsAlias;

  const idSort = rhs.candidate.modelId.localeCompare(lhs.candidate.modelId);
  if (idSort !== 0) return idSort;

  return lhs.candidate.index - rhs.candidate.index;
}

function isLocalModel(model: RegistryModel): boolean {
  if (!model.baseUrl) return false;

  try {
    const hostname = new URL(model.baseUrl).hostname.toLowerCase();
    return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "::1";
  } catch {
    return false;
  }
}

function canonicalIdForRegistryModel(model: RegistryModel): string {
  return `${model.provider}/${model.id}`;
}

function authKindForRegistryModel(
  registry: RegistryForResolution,
  model: RegistryModel,
): ModelAuthKind {
  try {
    if (registry.isUsingOAuth?.(model)) return "subscription";
  } catch {
    // Ignore auth-kind decoration failures; resolution can still proceed.
  }
  return isLocalModel(model) ? "local" : "apiKey";
}

function toRegistryCandidate(
  model: RegistryModel,
  index: number,
  authKind: ModelAuthKind,
): ModelResolutionCandidate<RegistryModel> {
  return {
    model,
    canonicalId: canonicalIdForRegistryModel(model),
    provider: model.provider,
    modelId: model.id,
    name: model.name || model.id,
    contextWindow: model.contextWindow,
    authKind,
    index,
  };
}

export function candidateFromModelInfo(
  model: ModelResolutionInfo,
  index: number,
): ModelResolutionCandidate<ModelResolutionInfo> | undefined {
  const parts = splitCanonicalModelId(model.id);
  if (!parts) return undefined;
  const provider = model.provider?.trim() || parts.provider;
  return {
    model,
    canonicalId: model.id,
    provider,
    modelId: parts.modelId,
    name: model.name || parts.modelId,
    contextWindow: model.contextWindow,
    authKind: model.authKind,
    index,
  };
}

function stripThinkingLevelFromPattern(pattern: string): string {
  return stripModelThinkingLevel(pattern).model;
}

function globToRegExp(pattern: string): RegExp {
  let source = "^";
  for (const char of pattern) {
    if (char === "*") {
      source += ".*";
    } else if (char === "?") {
      source += ".";
    } else {
      source += char.replace(/[|\\{}()[\]^$+?.]/g, "\\$&");
    }
  }
  return new RegExp(`${source}$`, "i");
}

export function modelMatchesEnabledPattern(
  candidate: Pick<ModelResolutionCandidate, "canonicalId" | "modelId">,
  rawPattern: string,
): boolean {
  const pattern = stripThinkingLevelFromPattern(rawPattern.trim());
  if (!pattern) return false;

  const hasGlob = /[*?[]/.test(pattern);
  if (hasGlob) {
    const regex = globToRegExp(pattern);
    return regex.test(candidate.canonicalId) || regex.test(candidate.modelId);
  }

  return candidate.canonicalId === pattern || candidate.modelId === pattern;
}

export function modelCandidatesFromRegistry(
  registry: RegistryForResolution,
  enabledPatterns?: readonly string[],
): Array<ModelResolutionCandidate<RegistryModel>> {
  const available = registry.getAvailable() as RegistryModel[];
  const all = registry.getAll() as RegistryModel[];
  const availableIds = new Set(available.map(canonicalIdForRegistryModel));
  const localModels = all.filter(
    (model) => isLocalModel(model) && !availableIds.has(canonicalIdForRegistryModel(model)),
  );

  const deduped = new Map<string, ModelResolutionCandidate<RegistryModel>>();
  let index = 0;
  for (const model of available) {
    const candidate = toRegistryCandidate(
      model,
      index++,
      authKindForRegistryModel(registry, model),
    );
    if (!deduped.has(candidate.canonicalId)) deduped.set(candidate.canonicalId, candidate);
  }
  for (const model of localModels) {
    const candidate = toRegistryCandidate(model, index++, "local");
    if (!deduped.has(candidate.canonicalId)) deduped.set(candidate.canonicalId, candidate);
  }

  const candidates = [...deduped.values()];
  const patterns = enabledPatterns?.map((pattern) => pattern.trim()).filter(Boolean);
  if (!patterns || patterns.length === 0) return candidates;

  return candidates.filter((candidate) =>
    patterns.some((pattern) => modelMatchesEnabledPattern(candidate, pattern)),
  );
}

export function modelCandidatesFromModelInfo(
  models: readonly ModelResolutionInfo[],
): Array<ModelResolutionCandidate<ModelResolutionInfo>> {
  return models.flatMap((model, index) => {
    const candidate = candidateFromModelInfo(model, index);
    return candidate ? [candidate] : [];
  });
}

export function resolveModelRequest<TModel>(
  requestedModel: string,
  candidates: readonly ModelResolutionCandidate<TModel>[],
): ModelResolutionResult<TModel> | undefined {
  const parsed = stripModelThinkingLevel(requestedModel);
  const query = parsed.model.trim();
  if (!query) return undefined;

  const scored = candidates
    .map((candidate) => ({ candidate, score: scoreAgainstCandidate(query, candidate) }))
    .filter((entry) => entry.score > 0)
    .sort(compareCandidates);

  const winner = scored[0];
  if (!winner) return undefined;

  return {
    candidate: winner.candidate,
    thinkingLevel: parsed.thinkingLevel,
    alternatives: scored.slice(1, 6).map((entry) => entry.candidate),
  };
}

export function exactModelIdsForDisplay(
  candidates: readonly Pick<ModelResolutionCandidate, "canonicalId">[],
): string[] {
  return candidates.map((candidate) => candidate.canonicalId);
}

export function formatAvailableModels(
  candidates: readonly Pick<ModelResolutionCandidate, "canonicalId">[],
  limit = 30,
): string {
  const ids = exactModelIdsForDisplay(candidates);
  if (ids.length === 0) return "(none)";
  if (ids.length <= limit) return ids.join(", ");
  const visible = ids.slice(0, limit);
  return `${visible.join(", ")}, … (${ids.length - visible.length} more)`;
}

export function modelUnavailableMessage(
  requestedModel: string,
  candidates: readonly Pick<ModelResolutionCandidate, "canonicalId">[],
): string {
  const requested = requestedModel.trim();
  if (!requested) return "Model cannot be empty.";
  if (candidates.length === 0) {
    return `Model "${requested}" is not available. No enabled models are available from Pi settings.`;
  }
  return `Model "${requested}" is not available. Available models: ${formatAvailableModels(candidates)}`;
}
