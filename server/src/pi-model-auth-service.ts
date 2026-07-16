import type { Api, KnownProvider, Model } from "@earendil-works/pi-ai";
import { completeSimple, getModel } from "@earendil-works/pi-ai/compat";

export type PiCompleteSimpleRequest = Parameters<typeof completeSimple>[1];
export type PiCompleteSimpleOptions = Parameters<typeof completeSimple>[2];
export type PiCompleteSimpleResponse = Awaited<ReturnType<typeof completeSimple>>;

/**
 * Transitional Pi 0.80 model/auth boundary.
 *
 * Keep deprecated pi-ai compat calls here while Oppi migrates title generation,
 * token pricing, and later catalog/auth wiring toward createModels() and
 * provider factories.
 */
export async function completeSimpleWithPiModel(
  model: Model<Api>,
  request: PiCompleteSimpleRequest,
  options: PiCompleteSimpleOptions,
): Promise<PiCompleteSimpleResponse> {
  return completeSimple(model, request, options);
}

export function getBuiltinCostModel(
  provider: KnownProvider,
  modelId: string,
): Model<Api> | undefined {
  // KnownProvider includes dynamic providers such as Radius, while this static
  // catalog intentionally does not. Its lookup returns undefined for them.
  return getModel(provider as Parameters<typeof getModel>[0], modelId as never) as
    | Model<Api>
    | undefined;
}
