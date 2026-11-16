/**
 * The durable Harness of one SessionManager, loaded on first use. The manager passes what the
 * Harness calls back into; anything the server injects after construction (`sessionNaming`,
 * `notifyPort`, `liveVoiceSpeech`) is read at each use through a getter.
 */
import { isControlConversation } from "./control-session.js";
import type { DurableHarness, DurableSessionNaming, SessionHost } from "./durable-harness.js";
import type { DurableThreadsDeps } from "./durable-threads.js";
import type { LiveVoiceSpeech } from "./live-voice-speech.js";
import type { SessionNotifyPort } from "./session-push-notifier.js";
import type { Storage } from "./storage.js";
import type { SurfaceLoop } from "./session-surfaces.js";

export interface DurableHarnessOwner {
  storage: Storage;
  fenceStopped: (hosts: readonly SessionHost[]) => Promise<void>;
  recoverSessions: (host: SessionHost, failure: unknown) => Promise<void>;
  threads: Pick<DurableThreadsDeps, "withIncomingWork" | "onCreated" | "trace">;
  surfacePublisherFor: (sessionId: string) => SurfaceLoop | undefined;
  sessionNaming: () => DurableSessionNaming | null;
  notifyPort: () => SessionNotifyPort | null;
  liveVoiceSpeech: () => LiveVoiceSpeech | null;
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
      return sessionId ? owner.surfacePublisherFor(sessionId) : undefined;
    },
  });
  runtime.bindSessionNaming({
    name: (sessionId) => owner.sessionNaming()?.name(sessionId),
    setName: async (sessionId, name) => {
      const naming = owner.sessionNaming();
      if (naming) await naming.setName(sessionId, name);
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
