import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { DictationDictionaryStore } from "../src/storage/dictation-dictionary-store.js";

describe("dictation dictionary persistence", () => {
  it("isolates workspace ids, preserves ordered global entries, and keeps deletion across reload", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-dictionary-"));
    const store = new DictationDictionaryStore(dir);
    store.add(null, "Duh Ifone");
    store.add("ws-a", "Yuwp");
    store.add("ws-b", "kypu");
    expect(store.get(null).phrases).toEqual(["Duh Ifone"]);
    expect(store.get("ws-a").phrases).toEqual(["Yuwp"]);
    expect(store.get("ws-b").phrases).toEqual(["kypu"]);
    store.remove("ws-a", "Yuwp");
    expect(new DictationDictionaryStore(dir).get("ws-a").phrases).toEqual([]);
    expect(new DictationDictionaryStore(dir).get("ws-b").phrases).toEqual(["kypu"]);
    store.forget("ws-b");
    expect(store.get(null).phrases).toEqual(["Duh Ifone"]);
    expect(store.get("ws-b").phrases).toEqual([]);
  });

  it("fails closed on corrupt persisted content rather than reviving old entries or overwriting it", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-dictionary-corrupt-"));
    const store = new DictationDictionaryStore(dir);
    store.add(null, "deleted");
    mkdirSync(join(dir, "settings"), { recursive: true });
    writeFileSync(join(dir, "settings", "dictation-dictionary.json"), "not json");
    expect(() => store.get(null)).toThrow();
    expect(() => store.add(null, "new")).toThrow();
  });

  it("rejects invalid phrases without logging or persisting them, and detects stale revisions", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-dictionary-validation-"));
    const store = new DictationDictionaryStore(dir);
    expect(() => store.add(null, "bad\nphrase")).toThrow();
    store.add(null, "x".repeat(256));
    expect(() => store.add(null, "x".repeat(257))).toThrow();
    const first = store.get(null);
    store.replace(null, first.revision, ["Yuwp"]);
    expect(() => store.replace(null, first.revision, ["stale"])).toThrow();
    expect(store.get(null).phrases).toEqual(["Yuwp"]);
  });

  it("adds as many ordered phrases as fit and reports duplicates, byte overflow, and the saved cap", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-dictionary-bulk-"));
    const store = new DictationDictionaryStore(dir);
    const batch = [
      ...Array.from({ length: 101 }, (_, i) => `jargon ${i}`),
      "jargon 0",
      "é".repeat(129),
    ];
    const result = store.addMany(null, batch);
    expect(result.phrases).toEqual(batch.slice(0, 100));
    expect(result.added).toBe(100);
    expect(result.skipped).toEqual([
      { phrase: "jargon 100", reason: "cap" },
      { phrase: "jargon 0", reason: "duplicate" },
      { phrase: "é".repeat(129), reason: "phrase-bytes" },
    ]);
    expect(result.revision).toBe(1);
    expect(store.addMany(null, ["one more"]).skipped).toEqual([
      { phrase: "one more", reason: "cap" },
    ]);
    expect(new DictationDictionaryStore(dir).get(null).phrases).toHaveLength(100);
    expect(store.addMany("other", ["one more"]).added).toBe(1);
    expect(() => store.addMany("other", ["valid", "bad\nphrase"])).toThrow();
    expect(store.get("other").phrases).toEqual(["one more"]);
    expect(() => store.replace(null, 1, [...batch.slice(0, 100), "overflow"])).toThrow();
    expect(() => store.replace("other", 1, ["é".repeat(129)])).toThrow();
  });
});
