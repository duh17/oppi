import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

import { loadOppiFirstPartyFactory } from "./load-oppi-first-party.js";

export default async function (pi: ExtensionAPI) {
  return (await loadOppiFirstPartyFactory("voice"))(pi);
}
