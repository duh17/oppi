import { basename } from "node:path";

import {
  DefaultResourceLoader,
  SettingsManager,
  getAgentDir,
  type PromptTemplate,
} from "@earendil-works/pi-coding-agent";

import { normalizePath } from "./git-utils.js";
import { getGitStatus } from "./git-status.js";
import { resolveSdkSessionCwd } from "./sdk-backend.js";
import { buildWorkspaceReviewFilesResponse } from "./workspace-review.js";
import type {
  Session,
  Workspace,
  WorkspaceQuickActionOption,
  WorkspaceReviewFile,
} from "./types.js";

export class WorkspaceQuickActionSessionError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "WorkspaceQuickActionSessionError";
  }
}

type QuickActionSessionSelection = {
  files: WorkspaceReviewFile[];
  visiblePrompt: string;
  sessionName: string;
  promptTemplateName: string;
};

export async function loadWorkspacePromptTemplates(
  workspace: Workspace,
): Promise<PromptTemplate[]> {
  if (!workspace.hostMount) {
    return [];
  }

  const cwd = resolveSdkSessionCwd(workspace);
  const agentDir = getAgentDir();
  const settingsManager = SettingsManager.create(cwd, agentDir);
  const loader = new DefaultResourceLoader({
    cwd,
    agentDir,
    settingsManager,
    noExtensions: true,
    noSkills: true,
    noThemes: true,
    noContextFiles: true,
  });
  await loader.reload();
  return loader.getPrompts().prompts;
}

function substitutePromptTemplateArgs(content: string, args: string[]): string {
  let result = content;

  result = result.replace(/\$(\d+)/g, (_, num: string) => {
    const index = Number.parseInt(num, 10) - 1;
    return args[index] ?? "";
  });

  result = result.replace(
    /\$\{@:(\d+)(?::(\d+))?\}/g,
    (_, startStr: string, lengthStr?: string) => {
      const start = Math.max(0, Number.parseInt(startStr, 10) - 1);
      if (lengthStr) {
        const length = Number.parseInt(lengthStr, 10);
        return args.slice(start, start + length).join(" ");
      }
      return args.slice(start).join(" ");
    },
  );

  const allArgs = args.join(" ");
  return result.replace(/\$ARGUMENTS/g, allArgs).replace(/\$@/g, allArgs);
}

function displayTemplateName(name: string): string {
  return name
    .split(/[-_\s]+/g)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

export async function loadWorkspaceQuickActionOptions(
  workspace: Workspace,
): Promise<WorkspaceQuickActionOption[]> {
  const templates = await loadWorkspacePromptTemplates(workspace);
  return templates.map(
    (template): WorkspaceQuickActionOption => ({
      id: `prompt:${template.name}`,
      title: displayTemplateName(template.name),
      commandName: template.name,
      description: template.description,
      argumentHint: template.argumentHint,
      source: "prompt",
      sourceScope: template.sourceInfo.scope,
      promptTemplateName: template.name,
    }),
  );
}

export async function prepareWorkspaceQuickActionSession(args: {
  workspaceId: string;
  workspace: Workspace;
  paths: string[];
  selectedSession?: Session;
  promptTemplateName: string;
}): Promise<QuickActionSessionSelection> {
  const { workspace, paths, selectedSession } = args;
  const promptTemplateName = args.promptTemplateName?.trim();

  if (!promptTemplateName) {
    throw new WorkspaceQuickActionSessionError(400, "promptTemplateName required");
  }

  if (!workspace.hostMount) {
    throw new WorkspaceQuickActionSessionError(404, "Workspace quick actions unavailable");
  }

  const gitStatus = await getGitStatus(workspace.hostMount);
  if (!gitStatus.isGitRepo) {
    throw new WorkspaceQuickActionSessionError(409, "Workspace is not a git repository");
  }

  const templates = await loadWorkspacePromptTemplates(workspace);
  const template = templates.find((candidate) => candidate.name === promptTemplateName);
  if (!template) {
    throw new WorkspaceQuickActionSessionError(
      400,
      `Unknown prompt template: ${promptTemplateName}`,
    );
  }

  const review = buildWorkspaceReviewFilesResponse({
    workspaceId: args.workspaceId,
    gitStatus,
    selectedSession,
    workspaceRoot: workspace.hostMount,
  });

  const uniquePaths = Array.from(
    new Set(paths.map((p) => normalizePath(p)).filter((value) => value.length > 0)),
  );

  if (uniquePaths.length === 0) {
    throw new WorkspaceQuickActionSessionError(400, "paths array required");
  }

  const reviewFilesByPath = new Map(
    review.files.map((file) => [normalizePath(file.path), file] as const),
  );
  const requestedFiles: WorkspaceReviewFile[] = [];
  const missingPaths: string[] = [];

  for (const path of uniquePaths) {
    const file = reviewFilesByPath.get(path);
    if (!file) {
      missingPaths.push(path);
      continue;
    }
    requestedFiles.push(file);
  }

  if (missingPaths.length > 0) {
    throw new WorkspaceQuickActionSessionError(
      400,
      `Selected files are no longer available in the current review: ${missingPaths.join(", ")}`,
    );
  }

  const title = displayTemplateName(promptTemplateName);
  const onlyFile = requestedFiles.length === 1 ? requestedFiles[0] : undefined;
  const sessionName = (
    onlyFile ? `${title}: ${basename(onlyFile.path)}` : `${title}: ${requestedFiles.length} files`
  ).slice(0, 160);
  const visiblePrompt = substitutePromptTemplateArgs(
    template.content.trim(),
    requestedFiles.map((file) => file.path),
  );

  return {
    files: requestedFiles,
    visiblePrompt,
    sessionName,
    promptTemplateName,
  };
}
