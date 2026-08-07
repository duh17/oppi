import type { ProviderQuotaAdapter } from "../types.js";
import { codexProviderQuotaAdapter } from "./codex.js";
import { xaiProviderQuotaAdapter } from "./xai.js";

/**
 * Built-in quota adapters for GET /server/provider-quotas.
 *
 * To add the next provider:
 * 1. Create `adapters/<provider>.ts` exporting a `ProviderQuotaAdapter`
 *    (copy codex/xai for structure; use helpers from `../shared.ts`).
 * 2. Import it here and append to this array.
 * 3. Keep `providerId` identical to the model provider / provider-auth id.
 * 4. No Apple client change is required when windows use the shared DTO.
 */
export const defaultProviderQuotaAdapters: readonly ProviderQuotaAdapter[] = [
  codexProviderQuotaAdapter,
  xaiProviderQuotaAdapter,
];

export { codexProviderQuotaAdapter, xaiProviderQuotaAdapter };
