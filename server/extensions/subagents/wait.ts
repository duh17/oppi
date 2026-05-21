import type { ServerMessage, Session } from "./model-types.js";
import { parseJsonlTrace, shortenPath } from "./trace.js";
import type { SpawnAgentDetails, SubagentsContext } from "./types.js";

function formatDuration(ms: number): string {
  const seconds = Math.floor(ms / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  const remaining = seconds % 60;
  return remaining > 0 ? `${minutes}m${remaining}s` : `${minutes}m`;
}

function formatCost(cost: number): string {
  if (cost === 0) return "$0";
  if (cost < 0.01) return `$${cost.toFixed(4)}`;
  return `$${cost.toFixed(2)}`;
}

export function isTerminal(status: string): boolean {
  return status === "stopped" || status === "error";
}

function hasCompletedWaitTurn(
  session: Session,
  baselineOutputTokens: number,
  baselineMessageCount: number,
): boolean {
  if (session.status !== "ready") return false;
  return (
    session.tokens.output > baselineOutputTokens || session.messageCount > baselineMessageCount
  );
}

export function isSessionBusy(session: Session | undefined): boolean {
  return session?.status === "busy" || session?.status === "starting";
}

export interface WaitResult {
  status: string;
  lastMessage?: string;
  cost: number;
  changeStats?: Session["changeStats"];
  messageCount: number;
  durationMs: number;
  timedOut: boolean;
}

function appendChangeStatsLines(
  lines: string[],
  changeStats: Session["changeStats"] | undefined,
): void {
  if (!changeStats || changeStats.filesChanged <= 0) {
    return;
  }

  lines.push(
    `Changes: ${changeStats.filesChanged} file${changeStats.filesChanged !== 1 ? "s" : ""}, +${changeStats.addedLines}/-${changeStats.removedLines} lines`,
  );
  if (changeStats.changedFiles.length > 0) {
    for (const filePath of changeStats.changedFiles.slice(0, 10)) {
      lines.push(`  ${shortenPath(filePath)}`);
    }
    if (changeStats.changedFilesOverflow && changeStats.changedFilesOverflow > 0) {
      lines.push(`  ... and ${changeStats.changedFilesOverflow} more`);
    }
  }
}

function appendLastResponseLines(
  lines: string[],
  session: Session | undefined,
  fallbackLastMessage?: string,
): void {
  const tracePath = session?.piSessionFile;
  if (tracePath) {
    const turns = parseJsonlTrace(tracePath);
    const lastTurn = turns[turns.length - 1];
    if (lastTurn?.assistantText) {
      lines.push("");
      lines.push("Last response:");
      lines.push(lastTurn.assistantText);
      return;
    }
  }

  if (fallbackLastMessage) {
    lines.push("");
    lines.push("Last message:");
    lines.push(fallbackLastMessage);
  }
}

export function buildChildCompletionText(
  ctx: SubagentsContext,
  childId: string,
  childName: string,
  durationMs: number,
  options?: {
    timedOut?: boolean;
    timeoutMs?: number;
    fallbackLastMessage?: string;
  },
): { text: string; status: string; cost: number; durationMs: number } {
  const session = ctx.getSession(childId);
  const lines: string[] = [];
  const status = session?.status ?? "unknown";
  const cost = session?.cost ?? 0;

  lines.push(`Agent "${childName}" (${childId}) finished: ${status.toUpperCase()}`);
  lines.push(
    `${session?.messageCount ?? 0} messages, ${formatCost(cost)}, ${formatDuration(durationMs)}`,
  );

  if (options?.timedOut) {
    lines.push(
      `WARNING: Timed out after ${formatDuration(options.timeoutMs ?? durationMs)}. The child may still be running.`,
    );
  }

  appendChangeStatsLines(lines, session?.changeStats);
  appendLastResponseLines(
    lines,
    session,
    options?.fallbackLastMessage ?? session?.lastMessage ?? undefined,
  );

  return {
    text: lines.join("\n"),
    status,
    cost,
    durationMs,
  };
}

export function waitForChildCompletion(
  ctx: SubagentsContext,
  childId: string,
  baselineOutputTokens: number,
  baselineMessageCount: number,
  timeoutMs: number,
  signal: AbortSignal | undefined,
  onUpdate?: (update: {
    content: Array<{ type: "text"; text: string }>;
    details: SpawnAgentDetails;
  }) => void,
  childName?: string,
): Promise<WaitResult> {
  return new Promise<WaitResult>((resolve, reject) => {
    const startTime = Date.now();
    let lastStatus = "";
    let lastMessageCount = 0;
    let resolved = false;
    let stoppingAfterCompletion = false;
    let unsubscribe: () => void = () => {};

    const onAbort = (): void => finalize(false);

    const timeoutTimer = setTimeout(() => {
      if (!resolved) finalize(true);
    }, timeoutMs);

    const cleanup = (): void => {
      resolved = true;
      clearTimeout(timeoutTimer);
      unsubscribe();
      signal?.removeEventListener("abort", onAbort);
    };

    const finalize = (timedOut: boolean): void => {
      if (resolved) return;
      const session = ctx.getSession(childId);
      cleanup();
      resolve({
        status: session?.status ?? "unknown",
        lastMessage: session?.lastMessage ?? undefined,
        cost: session?.cost ?? 0,
        changeStats: session?.changeStats,
        messageCount: session?.messageCount ?? 0,
        durationMs: Date.now() - startTime,
        timedOut,
      });
    };

    const stopAfterCompletedTurn = async (): Promise<void> => {
      if (resolved || stoppingAfterCompletion) return;
      stoppingAfterCompletion = true;
      try {
        await ctx.stopSession(childId);
      } catch (error: unknown) {
        cleanup();
        const message = error instanceof Error ? error.message : String(error);
        reject(
          new Error(`Child agent completed its waited turn but could not be stopped: ${message}`),
        );
        return;
      }
      finalize(false);
    };

    const emitProgress = (session: Session): void => {
      const statusChanged = session.status !== lastStatus;
      const messageCountChanged = session.messageCount !== lastMessageCount;
      if (!statusChanged && !messageCountChanged) return;

      lastStatus = session.status;
      lastMessageCount = session.messageCount;

      const elapsed = formatDuration(Date.now() - startTime);
      const cost = formatCost(session.cost);
      const name = childName ?? childId.slice(0, 8);
      const progressText = `[${name}] ${session.status} — ${session.messageCount} msgs, ${cost}, ${elapsed}`;

      onUpdate?.({
        content: [{ type: "text", text: progressText }],
        details: {
          agentId: childId,
          name: childName ?? childId.slice(0, 8),
          status: session.status,
        },
      });
    };

    const handleState = (session: Session): void => {
      if (isTerminal(session.status)) {
        finalize(false);
        return;
      }
      if (hasCompletedWaitTurn(session, baselineOutputTokens, baselineMessageCount)) {
        void stopAfterCompletedTurn();
        return;
      }
      emitProgress(session);
    };

    unsubscribe = ctx.subscribe(childId, (message: ServerMessage) => {
      if (resolved) return;
      if (message.type === "session_ended") {
        finalize(false);
        return;
      }
      if (message.type === "state") {
        handleState(message.session);
      }
    });

    const initial = ctx.getSession(childId);
    if (initial && isTerminal(initial.status)) {
      resolved = true;
      clearTimeout(timeoutTimer);
      unsubscribe();
      signal?.removeEventListener("abort", onAbort);
      resolve({
        status: initial.status,
        lastMessage: initial.lastMessage ?? undefined,
        cost: initial.cost,
        changeStats: initial.changeStats,
        messageCount: initial.messageCount,
        durationMs: 0,
        timedOut: false,
      });
      return;
    }
    if (initial) {
      handleState(initial);
      if (resolved || stoppingAfterCompletion) {
        return;
      }
    }

    signal?.addEventListener("abort", onAbort, { once: true });
  });
}
