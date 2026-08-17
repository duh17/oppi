import { describe, expect, it } from "vitest";
import { extractToolMutations, normalizeMutationToolName } from "../src/tool-mutations.js";

const editArgs = { path: "src/a.ts", oldText: "old", newText: "new" };
const writeArgs = { path: "src/a.ts", content: "hello" };

describe("normalizeMutationToolName", () => {
  it.each([
    { raw: "edit", canonical: "edit" },
    { raw: "write", canonical: "write" },
    { raw: "bash", canonical: "bash" },
    { raw: "functions.edit", canonical: "edit" },
    { raw: "functions.write", canonical: "write" },
    { raw: "EDIT", canonical: "edit" },
    { raw: "  Write  ", canonical: "write" },
    { raw: "Functions.Edit", canonical: "edit" },
  ])("maps known Pi name $raw to $canonical", ({ raw, canonical }) => {
    expect(normalizeMutationToolName(raw)).toBe(canonical);
  });

  it.each([
    "ext.edit",
    "my.write",
    "ask.edit",
    "something.write",
    "functions.bash",
    "read",
    "",
    "   ",
    42,
    null,
    undefined,
  ])("does not treat %s as a mutation tool", (raw) => {
    expect(normalizeMutationToolName(raw)).toBe("");
  });
});

describe("extractToolMutations", () => {
  it.each([
    { name: "edit", args: editArgs, kind: "edit" as const },
    { name: "write", args: writeArgs, kind: "write" as const },
    { name: "functions.edit", args: editArgs, kind: "edit" as const },
    { name: "functions.write", args: writeArgs, kind: "write" as const },
  ])("extracts $kind mutations from $name", ({ name, args, kind }) => {
    const mutations = extractToolMutations(name, args);
    expect(mutations).toHaveLength(1);
    expect(mutations[0]?.kind).toBe(kind);
    expect(mutations[0]?.path).toBe("src/a.ts");
  });

  it.each(["ext.edit", "my.write", "ask.edit", "something.write"])(
    "does not extract mutations from namespaced false positive %s",
    (name) => {
      expect(extractToolMutations(name, editArgs)).toEqual([]);
      expect(extractToolMutations(name, writeArgs)).toEqual([]);
    },
  );
});
