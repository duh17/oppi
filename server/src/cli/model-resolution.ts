/* eslint-disable no-console, local/structured-log-format */
import * as c from "../ansi.js";
import {
  exactModelIdsForDisplay,
  formatAvailableModels,
  modelCandidatesFromModelInfo,
  modelUnavailableMessage,
  resolveModelRequest,
  type ModelResolutionInfo,
} from "../model-resolution.js";
import {
  localApiRequest,
  type LocalApiConnection,
  type LocalApiHostResolvers,
} from "./local-api-client.js";

export class CliModelResolutionError extends Error {
  readonly availableModels: string[];

  constructor(message: string, availableModels: string[]) {
    super(message);
    this.name = "CliModelResolutionError";
    this.availableModels = availableModels;
  }
}

export function isCliModelResolutionError(error: unknown): error is CliModelResolutionError {
  return error instanceof CliModelResolutionError;
}

function isModelInfo(value: unknown): value is ModelResolutionInfo {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const record = value as Record<string, unknown>;
  return typeof record.id === "string";
}

export async function resolveModelFlagForCli(
  storage: LocalApiConnection,
  requestedModel: string | undefined,
  hostResolvers: LocalApiHostResolvers,
): Promise<string | undefined> {
  const trimmed = requestedModel?.trim();
  if (!trimmed) return undefined;

  const result = await localApiRequest<{ models?: unknown[] }>(
    storage,
    "/models",
    undefined,
    hostResolvers,
  );
  const models = (Array.isArray(result.models) ? result.models : []).filter(isModelInfo);
  const candidates = modelCandidatesFromModelInfo(models);
  const resolution = resolveModelRequest(trimmed, candidates);
  if (!resolution) {
    throw new CliModelResolutionError(
      modelUnavailableMessage(trimmed, candidates),
      exactModelIdsForDisplay(candidates),
    );
  }

  return resolution.candidate.canonicalId;
}

export function modelResolutionErrorEnvelope(error: CliModelResolutionError): {
  message: string;
  available_models: string[];
} {
  return {
    message: error.message,
    available_models: error.availableModels,
  };
}

export function printModelResolutionError(error: CliModelResolutionError): void {
  console.log(c.red(`  Error: ${error.message}`));
  if (error.availableModels.length > 0) {
    console.log("");
    console.log(c.bold("  Available models:"));
    console.log("");
    for (const model of error.availableModels) {
      console.log(`    ${model}`);
    }
  } else {
    console.log(c.dim(`  Available models: ${formatAvailableModels([])}`));
  }
}
