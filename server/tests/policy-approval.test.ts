import { describe, expect, it } from "vitest";
import { approvalOptionsForTool, normalizeApprovalChoice } from "../src/policy-approval.js";

describe("policy approval mapping", () => {
  it("exposes policy-specific approval options", () => {
    const policyOptions = approvalOptionsForTool("policy.update");
    expect(policyOptions).toEqual([
      { id: "approve", label: "Approve", action: "allow", scope: "once" },
      { id: "reject", label: "Reject", action: "deny", scope: "once" },
    ]);

    const standardOptions = approvalOptionsForTool("bash");
    expect(standardOptions).toEqual([
      { id: "allow-once", label: "Allow once", action: "allow", scope: "once" },
      { id: "allow-session", label: "Allow this session", action: "allow", scope: "session" },
      { id: "allow-global", label: "Allow always", action: "allow", scope: "global" },
      { id: "deny-once", label: "Deny", action: "deny", scope: "once" },
      { id: "deny-global", label: "Deny always", action: "deny", scope: "global" },
    ]);
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
