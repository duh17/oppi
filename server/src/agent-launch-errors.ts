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

/**
 * Operator-facing summary for logs and schedule run errors: the failure code,
 * plus the missing Extension IDs / Skill paths when the preflight recorded
 * them. Mobile-facing copy lives in `actionableAgentConfigurationMessage`.
 */
export function describeAgentConfigurationFailure(failure: AgentConfigurationFailure): string {
  const missing =
    failure.code === "agent_plugins_unavailable"
      ? failure.details.unavailablePlugins
      : failure.code === "agent_skills_unavailable"
        ? failure.details.unavailableSkills
        : undefined;
  return missing?.length ? `${failure.code}: ${missing.join(", ")}` : failure.code;
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
    case "agent_workspace_unavailable":
      return `${prefix} because the selected workspace or worktree is unavailable: ${failure.details.workspaceError ?? "the target could not be resolved"}. Choose another workspace or repair the selected worktree, then start again.`;
    case "agent_tools_unavailable":
      return `${prefix} because these configured tools are unavailable: ${(failure.details.missingTools ?? []).join(", ")}. Edit ${context.agentName} → Tools and select the plugin that provides them, or turn Edit files back on. Then start again.`;
    case "agent_plugins_unavailable":
      return `${prefix} because selected plugins are unavailable: ${(failure.details.unavailablePlugins ?? []).join(", ")}. Edit ${context.agentName} → Tools → Plugins and replace or remove the unavailable selections. Then start again.`;
    case "agent_skills_unavailable":
      return `${prefix} because selected Skills are unavailable: ${(failure.details.unavailableSkills ?? []).join(", ")}. Edit ${context.agentName} → Tools → Skills and replace or remove the unavailable selections. Then start again.`;
    case "agent_definition_v2_required":
      return `${prefix} because this Agent is still stored in the old format (tool lists and Extension IDs). Update the server so it can finish migrating saved Agents, then start again.`;
    case "agent_builtin_plugins_unavailable":
      return `${prefix} because Oppi could not read the plugins it offers, which this read-only Agent needs to keep tools it did not name out of its session. Start it again in a moment; if it keeps failing, run it with full access or check the server's plugins.`;
  }
}
