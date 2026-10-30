import { homedir, tmpdir } from "node:os";
import { relative, isAbsolute } from "node:path";
import { expect, it } from "vitest";

it("runs every test file against a temp home, never the developer's", () => {
  const rel = relative(tmpdir(), homedir());
  expect(rel === "" || rel.startsWith("..") || isAbsolute(rel)).toBe(false);
});
