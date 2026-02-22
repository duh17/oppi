export type ApprovalAction = "allow" | "deny";
export type ApprovalScope = "once" | "session" | "global";

export interface ApprovalChoice {
  action: ApprovalAction;
  scope: ApprovalScope;
}

export interface ApprovalOption extends ApprovalChoice {
  id:
    | "allow-once"
    | "allow-session"
    | "allow-global"
    | "deny-once"
    | "deny-global"
    | "approve"
    | "reject";
  label: string;
}

export interface NormalizedApprovalChoice extends ApprovalChoice {
  /** True when the requested scope was downgraded for safety/contract reasons. */
  normalized: boolean;
}

export const STANDARD_APPROVAL_OPTIONS: readonly ApprovalOption[] = [
  { id: "allow-once", label: "Allow once", action: "allow", scope: "once" },
  { id: "allow-session", label: "Allow this session", action: "allow", scope: "session" },
  { id: "allow-global", label: "Allow always", action: "allow", scope: "global" },
  { id: "deny-once", label: "Deny", action: "deny", scope: "once" },
  { id: "deny-global", label: "Deny always", action: "deny", scope: "global" },
];

export const POLICY_APPROVAL_OPTIONS: readonly ApprovalOption[] = [
  { id: "approve", label: "Approve", action: "allow", scope: "once" },
  { id: "reject", label: "Reject", action: "deny", scope: "once" },
];

function isPolicyTool(tool: string): boolean {
  return tool.startsWith("policy.");
}

export function approvalOptionsForTool(tool: string): readonly ApprovalOption[] {
  return isPolicyTool(tool) ? POLICY_APPROVAL_OPTIONS : STANDARD_APPROVAL_OPTIONS;
}

/**
 * Fixed approval contract:
 * - policy.* tools are always one-shot (scope forced to once)
 * - deny+session downgrades to once
 */
export function normalizeApprovalChoice(
  tool: string,
  choice: ApprovalChoice,
): NormalizedApprovalChoice {
  let scope = choice.scope;

  if (isPolicyTool(tool)) {
    scope = "once";
  } else if (choice.action === "deny" && scope === "session") {
    scope = "once";
  }

  return {
    action: choice.action,
    scope,
    normalized: scope !== choice.scope,
  };
}
