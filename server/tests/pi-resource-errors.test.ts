import { describe, expect, it } from "vitest";

import {
  ServerResourceNotFoundError,
  ServerResourceServiceError,
  ServerResourceValidationError,
} from "../src/server-resource-service.js";
import {
  httpStatusForPiResourceError,
  PiResourceNotFoundError,
  PiSettingsOperationError,
  WorkspaceResourceScopeError,
} from "../src/settings/pi-resource-errors.js";
import { SettingValidationError } from "../src/settings/registry.js";

describe("httpStatusForPiResourceError", () => {
  it.each([
    ["a missing workspace-scoped resource", new PiResourceNotFoundError(), 404],
    ["a missing server resource", new ServerResourceNotFoundError("skill"), 404],
    ["a rejected setting value", new SettingValidationError("bad"), 400],
    ["a rejected server resource write", new ServerResourceValidationError("bad"), 400],
    ["a failed Pi settings read or write", new PiSettingsOperationError("write", "EACCES"), 500],
    ["a failed server resource operation", new ServerResourceServiceError("boom"), 500],
    ["a workspace scope error", new WorkspaceResourceScopeError("gone", 404), 404],
  ])("answers %s with %i", (_label, error, status) => {
    expect(httpStatusForPiResourceError(error, 400)).toBe(status);
    expect(httpStatusForPiResourceError(error, 500)).toBe(status);
  });

  it("leaves an error it does not know to the route's fallback, not to its message", () => {
    const lookalike = new Error("Pi settings load failed: nope");
    expect(httpStatusForPiResourceError(lookalike, 400)).toBe(400);
    expect(httpStatusForPiResourceError(lookalike, 500)).toBe(500);
  });
});
