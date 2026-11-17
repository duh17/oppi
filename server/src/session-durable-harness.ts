/**
 * The durable Harness of one SessionManager, loaded on first use. The manager passes what the
 * Harness calls back into; anything the server injects after construction (`sessionNaming`,
 * `notifyPort`, `liveVoiceSpeech`) is read at each use through a getter.
 */
import { isAbsolute, normalize, relative as relativePath } from "node:path";

import { isControlConversation } from "./control-session.js";
import { sessionWorkRoot } from "./session-work-root.js";
import { plainRelativePath } from "./storage/pins-store.js";
import { hasUrlScheme } from "./tool-mutations.js";
import type { DurableHarness, DurableSessionNaming, SessionHost } from "./durable-harness.js";
import type { DurableThreadsDeps } from "./durable-threads.js";
import type { LiveVoiceSpeech } from "./live-voice-speech.js";
import type { SessionNotifyPort } from "./session-push-notifier.js";
import type { Storage } from "./storage.js";
import type { Session } from "./types.js";
import type { SessionSurfaces } from "./session-surfaces.js";

export interface DurableHarnessOwner {
  storage: Storage;
  fenceStopped: (hosts: readonly SessionHost[]) => Promise<void>;
  recoverSessions: (host: SessionHost, failure: unknown) => Promise<void>;
  threads: Pick<DurableThreadsDeps, "withIncomingWork" | "onCreated" | "trace">;
  /** A running Session's surfaces, whose `publisher` is what `oppiHost().surfaces(env)` returns. */
  surfacesFor: (sessionId: string) => SessionSurfaces | undefined;
  /** A running Session's record, newer than the stored one until it is saved. */
  activeSession: (sessionId: string) => Session | undefined;
  sessionNaming: () => DurableSessionNaming | null;
  notifyPort: () => SessionNotifyPort | null;
  liveVoiceSpeech: () => LiveVoiceSpeech | null;
}

/**
 * A Session's changed files as paths inside its working folder `root`: a relative path as the
 * tool named it, an absolute one under `root` made relative, each once, in the plain form a pin's
 * path takes (`plainRelativePath`). Everything else is left out, so a plugin can link each one
 * without its surface being refused: a path that leaves the folder (`../x`; `..hidden/x` stays),
 * a home (`~/…`) or URL path, one with control characters or over 1 KiB, and an absolute path
 * when the folder is unknown.
 */
export function relativeChangedFiles(
  recorded: readonly string[],
  root: string | undefined,
): string[] {
  const kept = new Set<string>();
  for (const raw of recorded) {
    const path = raw.trim();
    if (!path || path.startsWith("~") || hasUrlScheme(path)) continue;
    const relative = isAbsolute(path)
      ? root === undefined
        ? undefined
        : relativePath(root, path)
      : normalize(path);
    if (relative === undefined || isAbsolute(relative)) continue;
    const plain = plainRelativePath(relative);
    if (plain) kept.add(plain);
  }
  return [...kept];
}

export async function loadDurableHarness(owner: DurableHarnessOwner): Promise<DurableHarness> {
  const { storage } = owner;
  const [{ DurableHarness }, { DurableThreads }, { DurableControlCli }] = await Promise.all([
    import("./durable-harness.js"),
    import("./durable-threads.js"),
    import("./durable-control-cli.js"),
  ]);
  const runtime = new DurableHarness(storage.getDataDir());
  runtime.onHostOpened = (host) => owner.fenceStopped([host]);
  runtime.onHostRecovered = (host, failure) => owner.recoverSessions(host, failure);
  runtime.bindExtensionSwitches(() => storage.getConfig().experimental?.durableExtensions ?? {});
  runtime.bindThreads(new DurableThreads({ runtime, storage, ...owner.threads }));
  runtime.bindSessions({
    sessionIdOf: (storeId, conversationId) =>
      storage.findSessionByDurableConversation(storeId, conversationId)?.id,
    // What `oppiHost().surfaces(env)` hands a durable plugin: the surface loop of the Session
    // bound to the conversation its tool call runs.
    surfacesFor: (storeId, conversationId) => {
      const sessionId = storage.findSessionByDurableConversation(storeId, conversationId)?.id;
      return sessionId ? owner.surfacesFor(sessionId)?.publisher : undefined;
    },
  });
  runtime.bindSessionNaming({
    name: (sessionId) => owner.sessionNaming()?.name(sessionId),
    setName: async (sessionId, name) => {
      const naming = owner.sessionNaming();
      if (naming) await naming.setName(sessionId, name);
    },
  });
  // A running Session's record is newer than the stored one until it is saved.
  const sessionOf = (sessionId: string): Session | undefined =>
    owner.activeSession(sessionId) ?? storage.getSession(sessionId);
  runtime.bindSessionRecords({
    storeIdOf: (sessionId) => sessionOf(sessionId)?.serverDurable?.storeId,
    activity: async (sessionId) => {
      const session = sessionOf(sessionId);
      if (!session?.serverDurable?.storeId) return undefined;
      const root = await sessionWorkRoot(session, storage, { create: false });
      return {
        sessionId,
        changedFiles: relativeChangedFiles(
          session.changeStats?.changedFiles ?? [],
          root.kind === "ok" ? root.root : undefined,
        ),
        children: storage
          .listChildSessions(sessionId)
          .sort((a, b) => a.createdAt - b.createdAt)
          .map((child) => (child.name ? { id: child.id, name: child.name } : { id: child.id })),
      };
    },
  });
  runtime.bindNotify({
    offersNotify: (sessionId) => owner.notifyPort()?.offersNotify(sessionId) ?? false,
    notify: async (sessionId, input) => {
      const port = owner.notifyPort();
      return port ? port.notify(sessionId, input) : { status: "off" };
    },
  });
  runtime.bindLiveVoice({
    attachRuntime: (sessionId, activate) =>
      owner.liveVoiceSpeech()?.attachRuntime(sessionId, activate) ?? (() => {}),
    spoke: (sessionId, text) => {
      const speech = owner.liveVoiceSpeech();
      if (!speech) throw new Error("Live Voice is not available");
      speech.spoke(sessionId, text);
    },
  });
  runtime.bindControl(
    new DurableControlCli({
      dataDir: storage.getDataDir(),
      sessionIdOf: (storeId, conversationId) => {
        const session = storage.findSessionByDurableConversation(storeId, conversationId);
        return session && isControlConversation(session) ? session.id : undefined;
      },
    }),
  );
  return runtime;
}
