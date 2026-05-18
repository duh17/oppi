import { readFile, stat } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";

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
  WorkspaceReviewFile,
  WorkspaceReviewSessionAction,
} from "./types.js";

export class WorkspaceReviewSessionError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "WorkspaceReviewSessionError";
  }
}

type ReviewSessionSelection = {
  files: WorkspaceReviewFile[];
  visiblePrompt: string;
  sessionName: string;
  promptTemplateName?: string;
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

const REVIEW_RUBRIC = `# Review Guidelines

You are acting as a code reviewer for a proposed code change made by another engineer.

Below are default guidelines for determining what to flag. These are not the final word — if you encounter more specific guidelines elsewhere (in a developer message, user message, file, or project review guidelines appended below), those override these general instructions.

## Determining what to flag

Flag issues that:
1. Meaningfully impact the accuracy, performance, security, or maintainability of the code.
2. Are discrete and actionable (not general issues or multiple combined issues).
3. Don't demand rigor inconsistent with the rest of the codebase.
4. Were introduced in the changes being reviewed (not pre-existing bugs).
5. The author would likely fix if aware of them.
6. Don't rely on unstated assumptions about the codebase or author's intent.
7. Have provable impact on other parts of the code — it is not enough to speculate that a change may disrupt another part, you must identify the parts that are provably affected.
8. Are clearly not intentional changes by the author.
9. Be particularly careful with untrusted user input and follow the specific guidelines to review.
10. Treat silent local error recovery (especially parsing/IO/network fallbacks) as high-signal review candidates unless there is explicit boundary-level justification.

## Untrusted User Input

1. Be careful with open redirects, they must always be checked to only go to trusted domains (?next_page=...)
2. Always flag SQL that is not parametrized
3. In systems with user supplied URL input, http fetches always need to be protected against access to local resources (intercept DNS resolver!)
4. Escape, don't sanitize if you have the option (eg: HTML escaping)

## Comment guidelines

1. Be clear about why the issue is a problem.
2. Communicate severity appropriately - don't exaggerate.
3. Be brief - at most 1 paragraph.
4. Keep code snippets under 3 lines, wrapped in inline code or code blocks.
5. Use \`\`\`suggestion blocks ONLY for concrete replacement code (minimal lines; no commentary inside the block). Preserve the exact leading whitespace of the replaced lines.
6. Explicitly state scenarios/environments where the issue arises.
7. Use a matter-of-fact tone - helpful AI assistant, not accusatory.
8. Write for quick comprehension without close reading.
9. Avoid excessive flattery or unhelpful phrases like "Great job...".

## Review priorities

1. Surface critical non-blocking human callouts (migrations, dependency churn, auth/permissions, compatibility, destructive operations) at the end.
2. Prefer simple, direct solutions over wrappers or abstractions without clear value.
3. Treat back pressure handling as critical to system stability.
4. Apply system-level thinking; flag changes that increase operational risk or on-call wakeups.
5. Ensure that errors are always checked against codes or stable identifiers, never error messages.

## Fail-fast error handling (strict)

When reviewing added or modified error handling, default to fail-fast behavior.

1. Evaluate every new or changed \`try/catch\`: identify what can fail and why local handling is correct at that exact layer.
2. Prefer propagation over local recovery. If the current scope cannot fully recover while preserving correctness, rethrow (optionally with context) instead of returning fallbacks.
3. Flag catch blocks that hide failure signals (e.g. returning \`null\`/\`[]\`/\`false\`, swallowing JSON parse failures, logging-and-continue, or “best effort” silent recovery).
4. JSON parsing/decoding should fail loudly by default. Quiet fallback parsing is only acceptable with an explicit compatibility requirement and clear tested behavior.
5. Boundary handlers (HTTP routes, CLI entrypoints, supervisors) may translate errors, but must not pretend success or silently degrade.
6. If a catch exists only to satisfy lint/style without real handling, treat it as a bug.
7. When uncertain, prefer crashing fast over silent degradation.

## Required human callouts (non-blocking, at the very end)

After findings/verdict, you MUST append this final section:

## Human Reviewer Callouts (Non-Blocking)

Include only applicable callouts (no yes/no lines):

- **This change adds a database migration:** <files/details>
- **This change introduces a new dependency:** <package(s)/details>
- **This change changes a dependency (or the lockfile):** <files/package(s)/details>
- **This change modifies auth/permission behavior:** <what changed and where>
- **This change introduces backwards-incompatible public schema/API/contract changes:** <what changed and where>
- **This change includes irreversible or destructive operations:** <operation and scope>
- **This change adds or removes feature flags:** <feature flags changed> (call out re-use of dormant feature flags!)
- **This change changes configuration defaults:** <config var changed>

Rules for this section:
1. These are informational callouts for the human reviewer, not fix items.
2. Do not include them in Findings unless there is an independent defect.
3. These callouts alone must not change the verdict.
4. Only include callouts that apply to the reviewed change.
5. Keep each emitted callout bold exactly as written.
6. If none apply, write "- (none)".

## Priority levels

Tag each finding with a priority level in the title:
- [P0] - Drop everything to fix. Blocking release/operations. Only for universal issues that do not depend on assumptions about inputs.
- [P1] - Urgent. Should be addressed in the next cycle.
- [P2] - Normal. To be fixed eventually.
- [P3] - Low. Nice to have.

## Output format

Provide your findings in a clear, structured format:
1. List each finding with its priority tag, file location, and explanation.
2. Findings must reference locations that overlap with the actual diff — don't flag pre-existing code.
3. Keep line references as short as possible (avoid ranges over 5-10 lines; pick the most suitable subrange).
4. Provide an overall verdict: "correct" (no blocking issues) or "needs attention" (has blocking issues).
5. Ignore trivial style issues unless they obscure meaning or violate documented standards.
6. Do not generate a full PR fix — only flag issues and optionally provide short suggestion blocks.
7. End with the required "Human Reviewer Callouts (Non-Blocking)" section and all applicable bold callouts (no yes/no).

Output all findings the author would fix if they knew about them. If there are no qualifying findings, explicitly state the code looks good. Don't stop at the first finding - list every qualifying issue. Then append the required non-blocking callouts section.`;

async function readOptionalTrimmedFile(path: string): Promise<string | null> {
  const fileStats = await stat(path).catch(() => null);
  if (!fileStats?.isFile()) {
    return null;
  }

  const content = await readFile(path, "utf8").catch(() => null);
  const trimmed = content?.trim();
  return trimmed ? trimmed : null;
}

async function loadProjectReviewPromptOverride(workspaceRoot: string): Promise<string | null> {
  const resolvedRoot = resolve(workspaceRoot);

  for (const candidate of [
    join(resolvedRoot, "REVIEW.md"),
    join(resolvedRoot, ".pi", "REVIEW.md"),
  ]) {
    const prompt = await readOptionalTrimmedFile(candidate);
    if (prompt) {
      return prompt;
    }
  }

  return null;
}

async function loadProjectReviewGuidelines(workspaceRoot: string): Promise<string | null> {
  let currentDir = resolve(workspaceRoot);

  while (true) {
    const piDir = join(currentDir, ".pi");
    const guidelinesPath = join(currentDir, "REVIEW_GUIDELINES.md");

    const piStats = await stat(piDir).catch(() => null);
    if (piStats?.isDirectory()) {
      return readOptionalTrimmedFile(guidelinesPath);
    }

    const parent = dirname(currentDir);
    if (parent === currentDir) {
      return null;
    }
    currentDir = parent;
  }
}

function visiblePrompt(
  action: WorkspaceReviewSessionAction,
  reviewPromptOverride?: string | null,
  projectGuidelines?: string | null,
): string {
  switch (action) {
    case "review": {
      if (reviewPromptOverride) {
        return reviewPromptOverride;
      }

      let prompt = `${REVIEW_RUBRIC}\n\n---\n\nPlease perform a code review with the following focus:\n\nReview the selected files for bugs, regressions, and risky patterns. Cite file and line number for each finding.`;
      if (projectGuidelines) {
        prompt += `\n\nThis project has additional instructions for code reviews:\n\n${projectGuidelines}`;
      }
      return prompt;
    }
    case "reflect":
      return "Reflect on the changes in the selected files. Identify missing follow-ups, cleanup work, and next steps.";
    case "prepare_commit":
      return "Prepare a commit for the selected changes. Suggest a conventional commit title and body.";
  }
}

function displayTemplateName(name: string): string {
  return name
    .split(/[-_\s]+/g)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

function sessionTitle(action: WorkspaceReviewSessionAction): string {
  switch (action) {
    case "review":
      return "Review";
    case "reflect":
      return "Reflect";
    case "prepare_commit":
      return "Prepare commit";
  }
}

export async function prepareWorkspaceReviewSession(args: {
  workspaceId: string;
  workspace: Workspace;
  action: WorkspaceReviewSessionAction;
  paths: string[];
  selectedSession?: Session;
  promptTemplateName?: string;
}): Promise<ReviewSessionSelection> {
  const { workspace, action, paths, selectedSession, promptTemplateName } = args;

  if (!workspace.hostMount) {
    throw new WorkspaceReviewSessionError(404, "Workspace review unavailable");
  }

  const gitStatus = await getGitStatus(workspace.hostMount);
  if (!gitStatus.isGitRepo) {
    throw new WorkspaceReviewSessionError(409, "Workspace is not a git repository");
  }

  const review = buildWorkspaceReviewFilesResponse({
    workspaceId: args.workspaceId,
    gitStatus,
    selectedSession,
    workspaceRoot: workspace.hostMount,
  });
  let templatePrompt: string | null = null;
  if (promptTemplateName) {
    const templates = await loadWorkspacePromptTemplates(workspace);
    const template = templates.find((candidate) => candidate.name === promptTemplateName);
    if (!template) {
      throw new WorkspaceReviewSessionError(400, `Unknown prompt template: ${promptTemplateName}`);
    }
    templatePrompt = template.content.trim();
  }

  const reviewPromptOverride =
    !templatePrompt && action === "review"
      ? await loadProjectReviewPromptOverride(workspace.hostMount)
      : null;
  const projectGuidelines =
    !templatePrompt && action === "review" && !reviewPromptOverride
      ? await loadProjectReviewGuidelines(workspace.hostMount)
      : null;

  const uniquePaths = Array.from(
    new Set(paths.map((p) => normalizePath(p)).filter((value) => value.length > 0)),
  );

  if (uniquePaths.length === 0) {
    throw new WorkspaceReviewSessionError(400, "paths array required");
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
    throw new WorkspaceReviewSessionError(
      400,
      `Selected files are no longer available in the current review: ${missingPaths.join(", ")}`,
    );
  }

  const title = promptTemplateName ? displayTemplateName(promptTemplateName) : sessionTitle(action);
  const onlyFile = requestedFiles.length === 1 ? requestedFiles[0] : undefined;
  const sessionName = (
    onlyFile ? `${title}: ${basename(onlyFile.path)}` : `${title}: ${requestedFiles.length} files`
  ).slice(0, 160);

  return {
    files: requestedFiles,
    visiblePrompt: templatePrompt ?? visiblePrompt(action, reviewPromptOverride, projectGuidelines),
    sessionName,
    promptTemplateName,
  };
}
