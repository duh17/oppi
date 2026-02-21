import { describe, expect, it } from "vitest";
import {
  POLICY_APPROVAL_OPTIONS,
  STANDARD_APPROVAL_OPTIONS,
  approvalOptionsForTool,
  normalizeApprovalChoice,
} from "../src/policy-approval.js";

describe("policy approval mapping", () => {
  it("exposes policy-specific approval options", () => {
    expect(approvalOptionsForTool("policy.update")).toEqual(POLICY_APPROVAL_OPTIONS);
    expect(approvalOptionsForTool("bash")).toEqual(STANDARD_APPROVAL_OPTIONS);
  });

  it("forces policy tools to one-shot approvals", () => {
    const normalized = normalizeApprovalChoice("policy.update", {
      action: "allow",
      scope: "global",
    });

    expect(normalized).toEqual({
      action: "allow",
      scope: "once",
      normalized: true,
    });
  });

  it("downgrades deny+session to one-shot", () => {
    const normalized = normalizeApprovalChoice("bash", {
      action: "deny",
      scope: "session",
    });

    expect(normalized).toEqual({
      action: "deny",
      scope: "once",
      normalized: true,
    });
  });

  it("preserves allow session/global choices", () => {
    expect(
      normalizeApprovalChoice("bash", {
        action: "allow",
        scope: "session",
      }),
    ).toEqual({
      action: "allow",
      scope: "session",
      normalized: false,
    });

    expect(
      normalizeApprovalChoice("bash", {
        action: "allow",
        scope: "global",
      }),
    ).toEqual({
      action: "allow",
      scope: "global",
      normalized: false,
    });
  });
});
