import type {
  AgentConfigurationFailure,
  AgentConfigurationFailureCode,
  AgentConfigurationFailureDetails,
} from "./types/session.js";

export type {
  AgentConfigurationFailure,
  AgentConfigurationFailureCode,
  AgentConfigurationFailureDetails,
} from "./types/session.js";

export class AgentConfigurationError extends Error {
  readonly retryable = false as const;

  constructor(
    readonly code: AgentConfigurationFailureCode,
    readonly details: AgentConfigurationFailureDetails,
    message: string = code,
  ) {
    super(message);
    this.name = "AgentConfigurationError";
  }

  toFailure(): AgentConfigurationFailure {
    return { code: this.code, retryable: false, details: this.details };
  }
}

export function actionableAgentConfigurationMessage(
  failure: AgentConfigurationFailure,
  context: { agentName: string; workspaceName: string },
): string {
  const prefix = `${context.agentName} can’t start in ${context.workspaceName}`;
  switch (failure.code) {
    case "agent_workspace_incompatible": {
      const requirements = [
        failure.details.requiredRuntime
          ? `a ${failure.details.requiredRuntime} workspace`
          : undefined,
        failure.details.allowedWorkspaceIds?.length
          ? `one of its allowed workspaces (${failure.details.allowedWorkspaceIds.join(", ")})`
          : undefined,
      ].filter((value): value is string => value !== undefined);
      return `${prefix} because it requires ${requirements.join(" and ")}. Choose a compatible workspace in the Workspace picker, or edit ${context.agentName} → Launch Constraints. Then start again.`;
    }
    case "agent_tools_unavailable":
      return `${prefix} because these configured tools are unavailable: ${(failure.details.missingTools ?? []).join(", ")}. Edit ${context.agentName} → Resources → Extensions and select Extensions that provide these tools, or remove them from Allowed Tools. Then start again.`;
    case "agent_extensions_unavailable":
      return `${prefix} because selected Extensions are unavailable: ${(failure.details.unavailableExtensions ?? []).join(", ")}. Edit ${context.agentName} → Resources → Extensions and replace or remove the unavailable selections. Then start again.`;
    case "agent_skills_unavailable":
      return `${prefix} because selected Skills are unavailable: ${(failure.details.unavailableSkills ?? []).join(", ")}. Edit ${context.agentName} → Resources → Skills and replace or remove the unavailable selections. Then start again.`;
  }
}
