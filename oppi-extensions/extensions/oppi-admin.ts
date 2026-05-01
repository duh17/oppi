import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

import { loadOppiFirstPartyFactory } from "./load-oppi-first-party.js";

export default async function (pi: ExtensionAPI) {
  return (await loadOppiFirstPartyFactory("oppi-admin"))(pi);
}
