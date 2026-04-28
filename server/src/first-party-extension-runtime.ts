import { AsyncLocalStorage } from "node:async_hooks";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

import type { ExtensionFactory } from "@mariozechner/pi-coding-agent";

import { createAskFactory } from "../extensions/ask.js";
import { createSubagentsFactory, type SubagentsContext } from "../extensions/subagents.js";
import { createVoiceFactory } from "../extensions/voice.js";
import type { Storage } from "./storage.js";
import type { SubagentConfig } from "./types.js";

export type ReloadableFirstPartyExtensionName = "ask" | "voice" | "subagents";

export interface ReloadableFirstPartyExtensionContext {
  storage: Storage;
  subagents: {
    context: SubagentsContext;
    childMode: boolean;
    subagentConfig: SubagentConfig;
  };
}

const extensionLoadContext = new AsyncLocalStorage<ReloadableFirstPartyExtensionContext>();

export function withReloadableFirstPartyExtensionContext<T>(
  context: ReloadableFirstPartyExtensionContext,
  fn: () => T,
): T {
  return extensionLoadContext.run(context, fn);
}

function loadReloadableFirstPartyExtensionFactory(
  name: ReloadableFirstPartyExtensionName,
): ExtensionFactory {
  const context = extensionLoadContext.getStore();
  if (!context) {
    throw new Error(
      `Oppi first-party extension "${name}" was loaded without runtime context. ` +
        "Load it through SdkBackend/DefaultResourceLoader so /reload can rebind session-specific dependencies.",
    );
  }

  switch (name) {
    case "ask":
      return createAskFactory();
    case "voice":
      return createVoiceFactory(context.storage);
    case "subagents":
      return createSubagentsFactory(context.subagents.context, {
        childMode: context.subagents.childMode,
        subagentConfig: context.subagents.subagentConfig,
      });
  }
}

declare global {
  var __oppiFirstPartyExtensionRuntime:
    | {
        loadFactory: (name: ReloadableFirstPartyExtensionName) => ExtensionFactory;
      }
    | undefined;
}

globalThis.__oppiFirstPartyExtensionRuntime ??= {
  loadFactory: loadReloadableFirstPartyExtensionFactory,
};

export function getReloadableFirstPartyExtensionPaths(): string[] {
  const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
  return ["ask", "voice", "subagents"].map((name) =>
    resolve(projectRoot, "oppi-extensions", "extensions", `${name}.ts`),
  );
}
