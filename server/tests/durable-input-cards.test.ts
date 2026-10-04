import { afterEach, expect, it } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import { fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai/providers/faux";
import { Harness, MemoryStorage, createRegistry, watchEvents } from "@earendil-works/pi-durable";
import { DurableInputCards, sanitizeTranscriptCard } from "../extensions/durable/durable-ui.js";
import { readDurableInputCardOutput, readDurableInputCards } from "../src/durable-input-cards.js";
import { DurableEventProjection } from "../src/durable-event-projection.js";
import {
  readDurableTrace,
  readDurableTracePage,
  readDurableTraceOutline,
} from "../src/durable-history.js";
import { MobileRendererRegistry } from "../src/mobile-renderer.js";

const harnesses: Harness[] = [];
afterEach(async () => {
  await Promise.all(harnesses.splice(0).map((h) => h.close(context)));
});

it("projects arbitrary extension input by receipt identity, preserving model bytes and fork/paged history", async () => {
  const models = createModels();
  const faux = fauxProvider();
  faux.setResponses([fauxAssistantMessage("Integrated."), fauxAssistantMessage("User reply.")]);
  models.setProvider(faux.provider);
  const harness = await Harness.open(
    new MemoryStorage(),
    {
      models,
      registry: createRegistry(),
      settings: { compaction: { enabled: false } },
    },
    context,
  );
  harnesses.push(harness);
  const root = await harness.root(context, {
    agent: { model: { provider: "faux", modelId: "faux-1" } },
  });
  const card = {
    title: "Arbitrary extension result",
    status: "completed",
    body: "Compact summary",
    output: { kind: "terminal" as const, offset: 4, length: 34, command: "arbitrary producer" },
    at: 1234,
  };
  await root.commit(async (tx) => {
    (await tx.doc(DurableInputCards, root.id)).requests["arbitrary:report"] = card;
  }, context);
  const raw = "RAW-RESULT\n".repeat(200);
  const projection = new DurableEventProjection(harness, () => ({}));
  const stream = await watchEvents(harness, root.id, context);
  const projected: unknown[] = [];
  let delivered!: () => void;
  const seen = new Promise<void>((resolve) => {
    delivered = resolve;
  });
  stream.start(async (events) => {
    projected.push(...(await projection.batch(events)));
    if (events.some((event) => event.type === "run_end")) delivered();
  });
  const receipt = await root.submit(
    { type: "input", content: raw, requestId: "arbitrary:report" },
    context,
  );
  await receipt.wait(context);
  await root.waitForIdle(context);
  await seen;
  await stream.stop();
  const entry = (await receipt.status(context)).entry!;
  expect(projection.inputCards.entries.get(entry)).toMatchObject(card);
  expect(JSON.stringify(projected)).not.toContain("RAW-RESULT");
  expect(JSON.stringify((await root.context(context)).messages)).toContain("RAW-RESULT");

  // Identical text typed by a user is not presentation metadata.
  await (await root.submit({ type: "input", content: raw }, context)).wait(context);
  const trace = await readDurableTrace(harness, root.id, "full");
  const result = trace.find((event) => event.id === String(entry))!;
  expect(result).toMatchObject({
    type: "system",
    presentation: { kind: "custom", title: card.title },
  });
  expect(trace.filter((event) => event.type === "user")).toHaveLength(1);
  expect(JSON.stringify(result)).not.toContain("RAW-RESULT");
  expect(result.presentation?.output).toEqual({
    kind: "terminal",
    entryId: String(entry),
    command: "arbitrary producer",
  });
  expect(JSON.stringify(result)).not.toContain('"offset"');
  expect(await readDurableInputCardOutput(harness, root.id, String(entry))).toEqual({
    output: raw.slice(4, 38),
  });
  const user = trace.find((event) => event.type === "user")!;
  expect(await readDurableInputCardOutput(harness, root.id, user.id)).toBeNull();
  for (const invalid of ["../1", "1.5", "NaN", "-1", "9007199254740993", "999999"]) {
    expect(await readDurableInputCardOutput(harness, root.id, invalid)).toBeNull();
  }
  const other = await harness.createConversation({ ownership: { kind: "ownerless" } }, context);
  expect(other.id).not.toBe(root.id);
  expect(await readDurableInputCardOutput(harness, other.id, String(entry))).toBeNull();
  const page = await readDurableTracePage(harness, root.id, {
    targetEvents: 1,
    aroundEntryId: String(entry),
  });
  expect(page.trace.find((event) => event.id === String(entry))).toEqual(result);
  const outline = await readDurableTraceOutline(harness, root.id, new MobileRendererRegistry());
  expect(JSON.stringify(outline)).toContain(card.title);
  expect(await readDurableInputCards(harness, [root.id])).toEqual(projection.inputCards);

  const fork = await root.fork(entry, { ownership: { kind: "ownerless" } }, context);
  const inherited = await readDurableTrace(harness, fork.id, "full");
  expect(inherited.find((event) => event.id === String(entry))).toEqual(result);
  expect(await readDurableInputCardOutput(harness, fork.id, String(entry))).toEqual({
    output: raw.slice(4, 38),
  });
  await root.commit(async (tx) => {
    (await tx.doc(DurableInputCards, root.id)).requests["arbitrary:report"].output!.offset =
      raw.length;
  }, context);
  expect(await readDurableInputCardOutput(harness, fork.id, String(entry))).toBeNull();
});

it("rejects malformed or oversized output selectors without dropping the compact card", () => {
  for (const output of [
    { kind: "terminal", offset: -1, length: 2 },
    { kind: "terminal", offset: 0.5, length: 2 },
    { kind: "terminal", offset: 0, length: 64_001 },
    { kind: "terminal", offset: 0, length: NaN },
    { kind: "unknown", offset: 0, length: 2 },
  ]) {
    expect(sanitizeTranscriptCard({ title: "Result", at: 1, output })).toEqual({
      kind: "custom",
      title: "Result",
      at: 1,
    });
  }
});
