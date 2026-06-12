import { describe, expect, it } from "vitest";

import { isManagedExtensionName, MANAGED_EXTENSION_NAMES } from "./built-ins.js";

describe("managed extension names", () => {
  it("does not reserve ask or other host extensions", () => {
    expect(MANAGED_EXTENSION_NAMES).toEqual([]);
    expect(isManagedExtensionName("ask")).toBe(false);
    expect(isManagedExtensionName("memory")).toBe(false);
    expect(isManagedExtensionName("todos")).toBe(false);
  });
});
