import * as fs from "node:fs";

interface JContentBlock {
  type: string;
  text?: string;
  thinking?: string;
  name?: string;
  arguments?: Record<string, unknown>;
  id?: string;
}

export interface ParsedToolCall {
  index: number;
  name: string;
  argsPreview: string;
  fullArgs: Record<string, unknown>;
  isError: boolean;
  outputPreview: string;
  fullOutput: string;
}

export interface ParsedTurn {
  turnNumber: number;
  userMessage: string;
  toolCalls: ParsedToolCall[];
  assistantText: string;
  errorCount: number;
}

function truncate(text: string, max: number): string {
  if (text.length <= max) return text;
  return text.slice(0, max) + "…";
}

export function shortenPath(filePath: string): string {
  const home = process.env.HOME ?? "";
  if (filePath.startsWith(home)) return `~${filePath.slice(home.length)}`;
  const match = filePath.match(/workspace\/[^/]+\/(.+)/);
  return match?.[1] ?? filePath;
}

function formatToolArgs(name: string, args: Record<string, unknown>): string {
  switch (name) {
    case "bash": {
      const command = String(args.command ?? "");
      const firstLine = command.split("\n")[0] ?? "";
      return firstLine.length > 80 ? firstLine.slice(0, 77) + "..." : firstLine;
    }
    case "read": {
      const filePath = shortenPath(String(args.path ?? ""));
      const parts = [filePath];
      if (args.offset) parts.push(`:${args.offset}`);
      if (args.limit) parts.push(`+${args.limit}`);
      return parts.join("");
    }
    case "write": {
      const filePath = shortenPath(String(args.path ?? ""));
      const lines = String(args.content ?? "").split("\n").length;
      return `${filePath} (${lines} lines)`;
    }
    case "edit":
      return shortenPath(String(args.path ?? ""));
    default: {
      const firstStringArg = Object.values(args).find(
        (value) => typeof value === "string",
      );
      return firstStringArg
        ? String(firstStringArg).slice(0, 60)
        : JSON.stringify(args).slice(0, 60);
    }
  }
}

export function parseJsonlTrace(tracePath: string): ParsedTurn[] {
  let raw: string;
  try {
    raw = fs.readFileSync(tracePath, "utf-8");
  } catch {
    return [];
  }

  const lines = raw.trim().split("\n");
  const entries: Array<{ type: string; message?: Record<string, unknown> }> =
    [];
  for (const line of lines) {
    try {
      entries.push(JSON.parse(line));
    } catch {
      // Skip malformed lines.
    }
  }

  const turns: ParsedTurn[] = [];
  let current: ParsedTurn | null = null;
  const pending = new Map<string, ParsedToolCall>();

  for (const entry of entries) {
    if (entry.type !== "message" || !entry.message) continue;
    const message = entry.message as {
      role: string;
      content?: JContentBlock[];
      toolCallId?: string;
      toolName?: string;
      isError?: boolean;
    };
    const content = Array.isArray(message.content) ? message.content : [];

    if (message.role === "user") {
      const text = content
        .filter((block) => block.type === "text" && block.text)
        .map((block) => block.text ?? "")
        .join("\n");
      current = {
        turnNumber: turns.length + 1,
        userMessage: text,
        toolCalls: [],
        assistantText: "",
        errorCount: 0,
      };
      turns.push(current);
      continue;
    }

    if (message.role === "toolResult") {
      const resultText = content
        .filter((block) => block.type === "text" && block.text)
        .map((block) => block.text ?? "")
        .join("\n");
      const toolCallId = message.toolCallId ?? "";
      const toolCall = pending.get(toolCallId);
      if (toolCall) {
        toolCall.isError = message.isError ?? false;
        toolCall.outputPreview = truncate(resultText, 200);
        toolCall.fullOutput = resultText;
        if (toolCall.isError && current) current.errorCount++;
        pending.delete(toolCallId);
      }
      continue;
    }

    if (message.role === "assistant") {
      if (!current) {
        current = {
          turnNumber: 1,
          userMessage: "(session start)",
          toolCalls: [],
          assistantText: "",
          errorCount: 0,
        };
        turns.push(current);
      }

      for (const block of content) {
        if (block.type === "text" && block.text?.trim()) {
          current.assistantText = block.text;
        } else if (block.type === "toolCall" && block.name) {
          const index = current.toolCalls.length + 1;
          const toolCall: ParsedToolCall = {
            index,
            name: block.name,
            argsPreview: formatToolArgs(block.name, block.arguments ?? {}),
            fullArgs: block.arguments ?? {},
            isError: false,
            outputPreview: "",
            fullOutput: "",
          };
          current.toolCalls.push(toolCall);
          if (block.id) pending.set(block.id, toolCall);
        }
      }
    }
  }

  return turns;
}

export function renderOverview(turns: ParsedTurn[]): string {
  const totalTools = turns.reduce(
    (sum, turn) => sum + turn.toolCalls.length,
    0,
  );
  const totalErrors = turns.reduce((sum, turn) => sum + turn.errorCount, 0);

  const filesChanged = new Set<string>();
  const toolCounts: Record<string, number> = {};
  for (const turn of turns) {
    for (const toolCall of turn.toolCalls) {
      toolCounts[toolCall.name] = (toolCounts[toolCall.name] ?? 0) + 1;
      if (toolCall.name === "write" || toolCall.name === "edit") {
        const filePath = toolCall.argsPreview.split(" ")[0] ?? "";
        if (filePath) filesChanged.add(filePath);
      }
    }
  }

  const lines: string[] = [];
  lines.push(
    `${turns.length} turns, ${totalTools} tool calls, ${totalErrors} errors, ${filesChanged.size} files changed`,
  );

  if (Object.keys(toolCounts).length > 0) {
    const breakdown = Object.entries(toolCounts)
      .sort((a, b) => b[1] - a[1])
      .map(([name, count]) => `${name}:${count}`)
      .join("  ");
    lines.push(`Tools: ${breakdown}`);
  }
  lines.push("");

  for (const turn of turns) {
    const groupedCalls: Record<string, number> = {};
    for (const toolCall of turn.toolCalls) {
      groupedCalls[toolCall.name] = (groupedCalls[toolCall.name] ?? 0) + 1;
    }
    const toolSummary =
      Object.keys(groupedCalls).length > 0
        ? Object.entries(groupedCalls)
            .map(([name, count]) => (count > 1 ? `${name}x${count}` : name))
            .join(", ")
        : "text only";

    const errorMarker =
      turn.errorCount > 0
        ? ` <- ${turn.errorCount} error${turn.errorCount > 1 ? "s" : ""}`
        : "";

    const prompt = turn.userMessage.slice(0, 60).replace(/\n/g, " ");
    lines.push(`  Turn ${turn.turnNumber}: [${toolSummary}]${errorMarker}`);
    lines.push(`    "${prompt}${turn.userMessage.length > 60 ? "..." : ""}"`);
  }

  const lastTurn = turns[turns.length - 1];
  if (lastTurn?.assistantText) {
    lines.push("");
    lines.push(
      `Last response: "${truncate(lastTurn.assistantText.replace(/\n/g, " "), 200)}"`,
    );
  }

  return lines.join("\n");
}

export function renderTurnDetail(
  turns: ParsedTurn[],
  turnNumber: number,
): string {
  const turn = turns.find((entry) => entry.turnNumber === turnNumber);
  if (!turn) {
    return `Turn ${turnNumber} not found. ${turns.length} turns available (1-${turns.length}).`;
  }

  const lines: string[] = [];
  lines.push(
    `Turn ${turn.turnNumber} (${turn.toolCalls.length} tool calls, ${turn.errorCount} errors)`,
  );
  lines.push(
    `Prompt: "${truncate(turn.userMessage.replace(/\n/g, " "), 200)}"`,
  );
  lines.push("");

  for (const toolCall of turn.toolCalls) {
    const errorLabel = toolCall.isError ? " ERROR" : "";
    lines.push(
      `  [${toolCall.index}] ${toolCall.name}: ${toolCall.argsPreview}${errorLabel}`,
    );
    if (toolCall.isError && toolCall.outputPreview) {
      for (const previewLine of toolCall.outputPreview
        .split("\n")
        .slice(0, 3)) {
        lines.push(`       ${previewLine.slice(0, 120)}`);
      }
    }
  }

  if (turn.assistantText) {
    lines.push("");
    lines.push(`Response: "${truncate(turn.assistantText, 5000)}"`);
  }

  return lines.join("\n");
}

export function renderFullResponse(
  turns: ParsedTurn[],
  turnNumber?: number,
): string {
  if (turnNumber !== undefined) {
    const turn = turns.find((entry) => entry.turnNumber === turnNumber);
    if (!turn) {
      return `Turn ${turnNumber} not found. ${turns.length} turns available (1-${turns.length}).`;
    }
    if (!turn.assistantText)
      return `Turn ${turnNumber} has no assistant response text.`;
    return turn.assistantText;
  }

  const lastTurn = turns[turns.length - 1];
  if (!lastTurn?.assistantText) return "No assistant response found in trace.";
  return lastTurn.assistantText;
}

export function renderToolDetail(
  turns: ParsedTurn[],
  turnNumber: number,
  toolIndex: number,
): string {
  const turn = turns.find((entry) => entry.turnNumber === turnNumber);
  if (!turn) return `Turn ${turnNumber} not found.`;

  const toolCall = turn.toolCalls.find((entry) => entry.index === toolIndex);
  if (!toolCall) {
    return `Tool [${toolIndex}] not found in turn ${turnNumber}. ${turn.toolCalls.length} tools available (1-${turn.toolCalls.length}).`;
  }

  const lines: string[] = [];
  lines.push(`Turn ${turnNumber}, Tool [${toolCall.index}]`);
  lines.push(`Name: ${toolCall.name}`);
  lines.push(`Error: ${toolCall.isError}`);
  lines.push("");

  lines.push("Arguments:");
  for (const [key, value] of Object.entries(toolCall.fullArgs)) {
    const formatted = typeof value === "string" ? value : JSON.stringify(value);
    if (formatted.length > 500) {
      lines.push(
        `  ${key}: (${formatted.length} chars) ${formatted.slice(0, 200)}...`,
      );
    } else {
      lines.push(`  ${key}: ${formatted}`);
    }
  }

  lines.push("");
  const outputLines = toolCall.fullOutput.split("\n");
  const maxLines = 80;
  lines.push(
    `Output (${toolCall.fullOutput.length} chars, ${outputLines.length} lines):`,
  );
  if (outputLines.length > maxLines) {
    lines.push(`  ... (${outputLines.length - maxLines} lines omitted)`);
  }
  for (const line of outputLines.slice(-maxLines)) {
    lines.push(`  ${line}`);
  }

  return lines.join("\n");
}
