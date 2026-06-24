import type {
  ExtensionAPI,
  ExtensionContext,
  WorkingIndicatorOptions,
} from "@earendil-works/pi-coding-agent";

const PHRASES = [
  "Checking files…",
  "Reading context…",
  "Tracing references…",
  "Reviewing diffs…",
  "Inspecting tests…",
  "Updating the plan…",
  "Looking for edge cases…",
  "Verifying assumptions…",
  "Preparing the next step…",
  "Tightening the patch…",
  "Checking nearby code…",
  "Waiting on tools…",
  "Comparing options…",
  "Keeping state tidy…",
  "Reviewing output…",
  "Ready for the next move…",
];

const INDICATOR_FRAMES = ["·", "•", "●", "•"];
const STATUS_KEY = "working-words";
const STATUS_TEXT = `shuffled · ${PHRASES.length} phrases`;
const ROTATE_MS = 1_500;

function randomPhrase(): string {
  return PHRASES[Math.floor(Math.random() * PHRASES.length)] ?? PHRASES[0]!;
}

function workingIndicator(ctx: ExtensionContext): WorkingIndicatorOptions {
  const frames =
    ctx.mode === "tui"
      ? INDICATOR_FRAMES.map((frame) => ctx.ui.theme.fg("accent", frame))
      : INDICATOR_FRAMES;

  return { frames, intervalMs: 120 };
}

export default function workingWords(pi: ExtensionAPI) {
  let timer: ReturnType<typeof setInterval> | undefined;

  function stopTimer() {
    if (!timer) return;
    clearInterval(timer);
    timer = undefined;
  }

  function applyIdleUi(ctx: ExtensionContext) {
    ctx.ui.setWorkingIndicator(workingIndicator(ctx));
    ctx.ui.setStatus(STATUS_KEY, STATUS_TEXT);
  }

  function rotate(ctx: ExtensionContext) {
    ctx.ui.setWorkingMessage(randomPhrase());
  }

  pi.on("session_start", async (_event, ctx) => {
    applyIdleUi(ctx);
  });

  pi.on("agent_start", async (_event, ctx) => {
    applyIdleUi(ctx);
    rotate(ctx);
    stopTimer();
    timer = setInterval(() => rotate(ctx), ROTATE_MS);
  });

  pi.on("agent_end", async (_event, ctx) => {
    stopTimer();
    ctx.ui.setWorkingMessage();
    applyIdleUi(ctx);
  });

  pi.on("session_shutdown", async (_event, ctx) => {
    stopTimer();
    ctx.ui.setWorkingIndicator();
    ctx.ui.setWorkingMessage();
    ctx.ui.setStatus(STATUS_KEY, undefined);
  });

  pi.registerCommand("working-words", {
    description:
      "Preview randomized working phrases used to test Oppi extension UI projection.",
    handler: async (_args, ctx) => {
      applyIdleUi(ctx);
      rotate(ctx);
      ctx.ui.notify(`Working words enabled: ${STATUS_TEXT}`, "info");
    },
  });
}
