import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

import "../../server/src/first-party-extension-runtime.ts";

export default function (pi: ExtensionAPI) {
  const runtime = globalThis as typeof globalThis & {
    __oppiFirstPartyExtensionRuntime?: {
      loadFactory: (name: "subagents") => (pi: ExtensionAPI) => void | Promise<void>;
    };
  };

  const factory = runtime.__oppiFirstPartyExtensionRuntime?.loadFactory("subagents");
  if (!factory) {
    throw new Error("Oppi first-party extension runtime is unavailable for subagents");
  }

  return factory(pi);
}
