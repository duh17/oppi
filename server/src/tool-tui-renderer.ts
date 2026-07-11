import {
  Theme,
  type AgentToolResult,
  type ThemeColor,
  type ToolDefinition,
  type ToolRenderResultOptions,
} from "@earendil-works/pi-coding-agent";

export const TOOL_TUI_RENDER_VERSION = 1;
export const TOOL_TUI_RENDER_SOURCE = "renderResult";
export const TOOL_TUI_RENDER_WIDTH = 80;
const TOOL_TUI_RENDER_MAX_LINES = 500;
const TOOL_TUI_RENDER_MAX_CHARS = 80_000;
const TOOL_TUI_RENDER_NATIVE_TOOL_NAMES = new Set(["bash", "read", "write", "edit", "ask"]);

// eslint-disable-next-line no-control-regex
const ANSI_ESCAPE_REGEX = /\x1b\[[\d;]*m/g;

const SNAPSHOT_FG_COLORS: Record<ThemeColor, string> = {
  accent: "#7aa2f7",
  border: "#565f89",
  borderAccent: "#7aa2f7",
  borderMuted: "#414868",
  success: "#9ece6a",
  error: "#f7768e",
  warning: "#e0af68",
  muted: "#9aa5ce",
  dim: "#565f89",
  text: "#c0caf5",
  thinkingText: "#a9b1d6",
  userMessageText: "#c0caf5",
  customMessageText: "#c0caf5",
  customMessageLabel: "#7dcfff",
  toolTitle: "#7aa2f7",
  toolOutput: "#c0caf5",
  mdHeading: "#7aa2f7",
  mdLink: "#7dcfff",
  mdLinkUrl: "#9aa5ce",
  mdCode: "#bb9af7",
  mdCodeBlock: "#c0caf5",
  mdCodeBlockBorder: "#414868",
  mdQuote: "#9aa5ce",
  mdQuoteBorder: "#565f89",
  mdHr: "#565f89",
  mdListBullet: "#7aa2f7",
  toolDiffAdded: "#9ece6a",
  toolDiffRemoved: "#f7768e",
  toolDiffContext: "#9aa5ce",
  syntaxComment: "#565f89",
  syntaxKeyword: "#bb9af7",
  syntaxFunction: "#7aa2f7",
  syntaxVariable: "#c0caf5",
  syntaxString: "#9ece6a",
  syntaxNumber: "#ff9e64",
  syntaxType: "#2ac3de",
  syntaxOperator: "#89ddff",
  syntaxPunctuation: "#9aa5ce",
  thinkingOff: "#565f89",
  thinkingMinimal: "#7aa2f7",
  thinkingLow: "#2ac3de",
  thinkingMedium: "#9ece6a",
  thinkingHigh: "#e0af68",
  thinkingXhigh: "#f7768e",
  thinkingMax: "#ff5fff",
  bashMode: "#7dcfff",
};

const SNAPSHOT_BG_COLORS = {
  selectedBg: "#26324a",
  userMessageBg: "#1f2335",
  customMessageBg: "#1f2335",
  toolPendingBg: "#1f2335",
  toolSuccessBg: "#1f2f24",
  toolErrorBg: "#3b2228",
};

let snapshotTheme: Theme | undefined;

export interface ToolTuiRenderSnapshot {
  version: typeof TOOL_TUI_RENDER_VERSION;
  source: typeof TOOL_TUI_RENDER_SOURCE;
  width: number;
  expandedText: string;
  truncated?: boolean;
}

interface RenderableComponent {
  render(width: number): string[];
}

interface ToolRenderContextSnapshot {
  args: Record<string, unknown>;
  toolCallId: string;
  invalidate: () => void;
  lastComponent: RenderableComponent | undefined;
  state: unknown;
  cwd: string;
  executionStarted: boolean;
  argsComplete: boolean;
  isPartial: boolean;
  expanded: boolean;
  showImages: boolean;
  isError: boolean;
}

type ResultRenderer = (
  result: AgentToolResult<unknown>,
  options: ToolRenderResultOptions,
  theme: Theme,
  context: ToolRenderContextSnapshot,
) => RenderableComponent;

export function getToolTuiSnapshotTheme(): Theme {
  snapshotTheme ??= new Theme(SNAPSHOT_FG_COLORS, SNAPSHOT_BG_COLORS, "truecolor", {
    name: "oppi-tool-render-snapshot",
  });
  return snapshotTheme;
}

export function shouldAttachToolTuiRenderSnapshot(toolName: string): boolean {
  return !TOOL_TUI_RENDER_NATIVE_TOOL_NAMES.has(toolName.trim().toLowerCase());
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isRenderableComponent(value: unknown): value is RenderableComponent {
  return isRecord(value) && typeof value.render === "function";
}

function isBlankRenderedLine(line: string): boolean {
  return line.replace(ANSI_ESCAPE_REGEX, "").trim().length === 0;
}

function trimRenderedResultLines(lines: string[]): string[] {
  let start = 0;
  let end = lines.length;
  while (start < end && isBlankRenderedLine(lines[start] ?? "")) start++;
  while (end > start && isBlankRenderedLine(lines[end - 1] ?? "")) end--;
  return lines.slice(start, end);
}

function visibleText(text: string): string {
  return text.replace(ANSI_ESCAPE_REGEX, "").trim();
}

function limitRenderedLines(lines: string[]): { lines: string[]; truncated: boolean } {
  if (lines.length <= TOOL_TUI_RENDER_MAX_LINES) {
    return { lines, truncated: false };
  }
  return {
    lines: [...lines.slice(0, TOOL_TUI_RENDER_MAX_LINES), "… truncated …"],
    truncated: true,
  };
}

export function renderToolTuiResultSnapshot(options: {
  toolDefinition: Pick<ToolDefinition, "renderResult">;
  toolCallId?: string;
  content: unknown[];
  details: unknown;
  isError: boolean;
  args?: Record<string, unknown>;
  cwd: string;
  width?: number;
}): ToolTuiRenderSnapshot | undefined {
  const renderResult = options.toolDefinition.renderResult as ResultRenderer | undefined;
  if (!renderResult) {
    return undefined;
  }

  const width = options.width ?? TOOL_TUI_RENDER_WIDTH;
  const toolCallId = options.toolCallId ?? "";
  const agentToolResult = {
    content: options.content as AgentToolResult<unknown>["content"],
    details: options.details,
  } satisfies AgentToolResult<unknown>;
  const context: ToolRenderContextSnapshot = {
    args: options.args ?? {},
    toolCallId,
    invalidate: () => {},
    lastComponent: undefined,
    state: {},
    cwd: options.cwd,
    executionStarted: true,
    argsComplete: true,
    isPartial: false,
    expanded: true,
    showImages: false,
    isError: options.isError,
  };

  const component = renderResult(
    agentToolResult,
    { expanded: true, isPartial: false },
    getToolTuiSnapshotTheme(),
    context,
  );
  if (!isRenderableComponent(component)) {
    return undefined;
  }

  const renderedLines = trimRenderedResultLines(component.render(width));
  const limited = limitRenderedLines(renderedLines);
  let expandedText = limited.lines.join("\n");
  let truncated = limited.truncated;
  if (expandedText.length > TOOL_TUI_RENDER_MAX_CHARS) {
    expandedText = `${expandedText.slice(0, TOOL_TUI_RENDER_MAX_CHARS)}\n… truncated …`;
    truncated = true;
  }
  if (!visibleText(expandedText)) {
    return undefined;
  }

  return {
    version: TOOL_TUI_RENDER_VERSION,
    source: TOOL_TUI_RENDER_SOURCE,
    width,
    expandedText,
    ...(truncated ? { truncated: true } : {}),
  };
}

export function mergeToolTuiRenderSnapshot(
  details: unknown,
  snapshot: ToolTuiRenderSnapshot,
): Record<string, unknown> | undefined {
  if (!isRecord(details)) {
    return undefined;
  }

  if (details.tuiRender !== undefined) {
    return details;
  }

  return { ...details, tuiRender: snapshot };
}
