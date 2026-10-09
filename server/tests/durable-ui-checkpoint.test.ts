import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, expect, it } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import {
  createSession,
  defineDoc,
  type ConversationId,
  type Session,
  type Storage,
  type TaskId,
} from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { DurableUI, type UIState } from "../extensions/durable/durable-ui.js";

// Matches DurableUI's checkpointWhen. The predicate probe below fails if they drift.
const THRESHOLD = 500;
const PAST = 4;
const taskId = 1 as TaskId;

const UncheckpointedUI = defineDoc<UIState>({
  kind: "oppi.extension-ui",
  version: 1,
  scope: "conversation",
  history: "latest",
  fork: "initial",
  initial: () => ({ requests: {}, notifications: {} }),
});

const dirs: string[] = [];
afterEach(async () => {
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
});

function applyStep(ui: UIState, i: number): void {
  ui.notifications["working:message"] = {
    id: "working-words:working:message",
    method: "setWorkingMessage",
    message: `Waiting on bash · ${i}s`,
  };
  if (i % 7 === 0) {
    ui.notifications["widget:activity"] = {
      id: "widget:activity",
      method: "setWidget",
      widgetKey: "activity",
      widgetLines: [`step ${i}`, "tail"],
    };
  }
  if (i % 10 === 0) {
    ui.requests[`req-${i}`] = {
      taskId,
      request: { id: `req-${i}`, method: "confirm", title: "Continue?", message: `step ${i}` },
    };
  }
  if (i % 10 === 5) delete ui.requests[`req-${i - 5}`];
}

async function openStore(): Promise<{ file: string; storage: Storage; session: Session }> {
  const dir = await mkdtemp(path.join(tmpdir(), "oppi-ui-checkpoint-"));
  dirs.push(dir);
  const file = path.join(dir, "harness.sqlite");
  const storage = await openNodeSqliteStorage(file);
  return { file, storage, session: createSession(storage) };
}

async function deltasSinceBase(storage: Storage, conversationId: ConversationId): Promise<number> {
  const page = await storage.scanDocuments(
    {
      scope: { kind: "conversation", conversationId },
      at: "current",
      kind: DurableUI.definition.kind,
    },
    2,
    undefined,
    context,
  );
  expect(page.items).toHaveLength(1);
  const stored = await storage.document(page.items[0]!.id, "current", context);
  expect(stored).toBeDefined();
  return stored!.deltasSinceBase;
}

it("replays the same extension UI state after checkpointing and after reload", async () => {
  const when = DurableUI.definition.checkpointWhen;
  expect(when).toBeTypeOf("function");
  const running = UncheckpointedUI.definition.initial();
  applyStep(running, 1);
  expect(when!(running, [], { deltasSinceBase: THRESHOLD - 1 })).toBe(false);
  expect(when!(running, [], { deltasSinceBase: THRESHOLD })).toBe(true);

  const opened = await openStore();
  const checkpointed = await opened.session.commit(
    (tx) => tx.createConversation({ ownership: { kind: "ownerless" } }),
    context,
  );
  const replayed = await opened.session.commit(
    (tx) => tx.createConversation({ ownership: { kind: "ownerless" } }),
    context,
  );
  // Index 0 creates a base. The next THRESHOLD commits are deltas. The following
  // commit sees deltasSinceBase === THRESHOLD and is stored as a base; PAST
  // commits after that remain deltas.
  const commits = THRESHOLD + 2 + PAST;
  for (let i = 0; i < commits; i++) {
    await opened.session.commit(async (tx) => {
      applyStep(await tx.doc(DurableUI, checkpointed.id), i);
      applyStep(await tx.doc(UncheckpointedUI, replayed.id), i);
    }, context);
  }

  const checkpointedState = await opened.session.snapshot(DurableUI, checkpointed.id, context);
  const replayedState = await opened.session.snapshot(UncheckpointedUI, replayed.id, context);
  expect(checkpointedState).toEqual(replayedState);
  expect(await deltasSinceBase(opened.storage, checkpointed.id)).toBe(PAST);
  expect(await deltasSinceBase(opened.storage, replayed.id)).toBe(commits - 1);

  await opened.session.close(context);
  const reloaded = await openNodeSqliteStorage(opened.file);
  const session = createSession(reloaded);
  try {
    const attached = await session.watchDoc(DurableUI, checkpointed.id, context);
    expect(attached).toBeDefined();
    expect(attached!.value).toEqual(replayedState);
    expect(await session.snapshot(DurableUI, checkpointed.id, context)).toEqual(replayedState);
    expect(await deltasSinceBase(reloaded, checkpointed.id)).toBe(PAST);
    await attached!.stop();
  } finally {
    await session.close(context);
  }
}, 60_000);

it("stores a base when the run's working message clears and on every idle write", async () => {
  const opened = await openStore();
  const [checkpointed, replayed] = [
    await opened.session.commit(
      (tx) => tx.createConversation({ ownership: { kind: "ownerless" } }),
      context,
    ),
    await opened.session.commit(
      (tx) => tx.createConversation({ ownership: { kind: "ownerless" } }),
      context,
    ),
  ];
  const both = (change: (ui: UIState) => void) =>
    opened.session.commit(async (tx) => {
      change(await tx.doc(DurableUI, checkpointed.id));
      change(await tx.doc(UncheckpointedUI, replayed.id));
    }, context);
  const RUN = 40;
  for (let i = 0; i < RUN; i++) await both((ui) => applyStep(ui, i));
  expect(await deltasSinceBase(opened.storage, checkpointed.id)).toBe(RUN - 1);

  // Run ends: the working message clears, as working-words publishes while idle.
  await both((ui) => {
    ui.notifications["working:message"] = {
      id: "working-words:working:message",
      method: "setWorkingMessage",
    };
  });
  expect(await deltasSinceBase(opened.storage, checkpointed.id)).toBe(0);
  // Idle writes (a job widget finishing between turns) stay bases.
  await both((ui) => {
    ui.notifications["widget:jobs"] = {
      id: "widget:jobs",
      method: "setWidget",
      widgetKey: "jobs",
      widgetLines: ["done"],
    };
  });
  expect(await deltasSinceBase(opened.storage, checkpointed.id)).toBe(0);
  // The next run starts a new chain.
  await both((ui) => applyStep(ui, RUN));
  expect(await deltasSinceBase(opened.storage, checkpointed.id)).toBe(1);

  const expected = await opened.session.snapshot(UncheckpointedUI, replayed.id, context);
  await opened.session.close(context);
  const reloaded = await openNodeSqliteStorage(opened.file);
  const session = createSession(reloaded);
  try {
    expect(await session.snapshot(DurableUI, checkpointed.id, context)).toEqual(expected);
  } finally {
    await session.close(context);
  }
}, 60_000);

it("checkpoints an existing over-threshold extension UI document on the next write", async () => {
  const opened = await openStore();
  const conversation = await opened.session.commit(
    (tx) => tx.createConversation({ ownership: { kind: "ownerless" } }),
    context,
  );
  for (let i = 0; i < THRESHOLD + 1; i++) {
    await opened.session.commit(async (tx) => {
      applyStep(await tx.doc(UncheckpointedUI, conversation.id), i);
    }, context);
  }
  expect(await deltasSinceBase(opened.storage, conversation.id)).toBe(THRESHOLD);
  const before = await opened.session.snapshot(UncheckpointedUI, conversation.id, context);
  const step = THRESHOLD + 1;
  await opened.session.commit(async (tx) => {
    applyStep(await tx.doc(DurableUI, conversation.id), step);
  }, context);
  const expected = structuredClone(before);
  applyStep(expected!, step);

  expect(await opened.session.snapshot(DurableUI, conversation.id, context)).toEqual(expected);
  expect(await deltasSinceBase(opened.storage, conversation.id)).toBe(0);

  await opened.session.close(context);
  const reloaded = await openNodeSqliteStorage(opened.file);
  const session = createSession(reloaded);
  try {
    const attached = await session.watchDoc(DurableUI, conversation.id, context);
    expect(attached?.value).toEqual(expected);
    expect(await deltasSinceBase(reloaded, conversation.id)).toBe(0);
    await attached?.stop();
  } finally {
    await session.close(context);
  }
}, 60_000);
