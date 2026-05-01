import * as fs from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

type FirstPartyExtensionName = "ask" | "subagents" | "voice";

type FirstPartyFactory = (pi: ExtensionAPI) => void | Promise<void>;

type RuntimeGlobal = typeof globalThis & {
  __oppiFirstPartyExtensionRuntime?: {
    loadFactory: (name: FirstPartyExtensionName) => FirstPartyFactory;
  };
};

let runtimeLoadPromise: Promise<void> | undefined;

async function ensureOppiRuntimeLoaded(): Promise<void> {
  if ((globalThis as RuntimeGlobal).__oppiFirstPartyExtensionRuntime) {
    return;
  }
  if (runtimeLoadPromise) {
    return runtimeLoadPromise;
  }

  const here = dirname(fileURLToPath(import.meta.url));
  const candidates = [
    resolve(
      here,
      "..",
      "..",
      "server",
      "src",
      "first-party-extension-runtime.ts",
    ),
    resolve(here, "..", "..", "src", "first-party-extension-runtime.js"),
  ];
  const runtimePath = candidates.find((candidate) => fs.existsSync(candidate));

  if (!runtimePath) {
    throw new Error(
      `Oppi first-party extension runtime is unavailable. Checked:\n${candidates
        .map((candidate) => `  - ${candidate}`)
        .join("\n")}`,
    );
  }

  runtimeLoadPromise = import(pathToFileURL(runtimePath).href).then(() => {});
  return runtimeLoadPromise;
}

export async function loadOppiFirstPartyFactory(
  name: FirstPartyExtensionName,
): Promise<FirstPartyFactory> {
  await ensureOppiRuntimeLoaded();
  const factory = (
    globalThis as RuntimeGlobal
  ).__oppiFirstPartyExtensionRuntime?.loadFactory(name);
  if (!factory) {
    throw new Error(
      `Oppi first-party extension runtime is unavailable for ${name}`,
    );
  }
  return factory;
}
