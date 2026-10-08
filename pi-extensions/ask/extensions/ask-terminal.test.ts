import { describe, expect, it } from "vitest";

import type { AskDialogResult, AskQuestion } from "./ask-shared.js";
import { runTerminalAskDialog, type AskDialogTui } from "./ask-terminal.js";

type TestComponent = {
  render: (width: number) => string[];
  handleInput: (data: string) => void;
};

async function createDialog(
  questions: AskQuestion[],
  allowCustom = true,
): Promise<{
  component: TestComponent;
  dialogPromise: Promise<AskDialogResult | undefined>;
}> {
  let component: TestComponent | undefined;
  let resolveResult: ((value: AskDialogResult | undefined) => void) | undefined;

  const dialogPromise = runTerminalAskDialog(
    async (factory) => {
      component = factory(
        { requestRender: () => {} },
        {
          fg: (_token, text) => text,
          bg: (_token, text) => text,
          bold: (text) => text,
        },
        null,
        (result) => resolveResult?.(result),
      );

      return new Promise<AskDialogResult | undefined>((resolve) => {
        resolveResult = resolve;
      });
    },
    questions,
    allowCustom,
  );

  if (!component) {
    throw new Error("Dialog component was not created");
  }

  return { component, dialogPromise };
}

describe("runTerminalAskDialog", () => {
  it("shows answers so far and a visible back action after advancing", async () => {
    const { component, dialogPromise } = await createDialog([
      {
        id: "approach",
        question: "Testing approach?",
        options: [
          { value: "unit", label: "Unit tests" },
          { value: "integration", label: "Integration tests" },
        ],
      },
      {
        id: "frameworks",
        question: "Which frameworks?",
        options: [
          { value: "jest", label: "Jest" },
          { value: "vitest", label: "Vitest" },
        ],
        multiSelect: true,
      },
    ]);

    component.handleInput("\r");

    const output = component.render(120).join("\n");
    expect(output).toContain("Answers so far");
    expect(output).toContain("Testing approach?: Unit tests");
    expect(output).toContain("← Back to previous question");

    component.handleInput("\x1b");
    await dialogPromise;
  });

  it("lets the user go back to the previous question from the action list", async () => {
    const { component, dialogPromise } = await createDialog(
      [
        {
          id: "q1",
          question: "First question?",
          options: [
            { value: "a", label: "Option A" },
            { value: "b", label: "Option B" },
          ],
        },
        {
          id: "q2",
          question: "Second question?",
          options: [
            { value: "x", label: "Option X" },
            { value: "y", label: "Option Y" },
          ],
        },
      ],
      false,
    );

    component.handleInput("\r");
    component.handleInput("\x1b[B");
    component.handleInput("\x1b[B");
    component.handleInput("\x1b[B");
    component.handleInput("\r");

    const output = component.render(120).join("\n");
    expect(output).toContain("Clarify before I proceed • 1/2");
    expect(output).toContain("First question?");
    expect(output).not.toContain("← Back to previous question");

    component.handleInput("\x1b");
    await dialogPromise;
  });

  it("supports entering a custom answer in the terminal dialog", async () => {
    const { component, dialogPromise } = await createDialog([
      {
        id: "notes",
        question: "Anything else?",
        options: [
          { value: "none", label: "Nothing else" },
          { value: "later", label: "Follow up later" },
        ],
      },
    ]);

    component.handleInput("\x1b[B");
    component.handleInput("\x1b[B");
    component.handleInput("\r");

    for (const char of "Keep the receipts") {
      component.handleInput(char);
    }
    component.handleInput("\r");

    await expect(dialogPromise).resolves.toEqual({
      answers: { notes: "Keep the receipts" },
      allIgnored: false,
    });
  });
});

type Status = {
  state: string;
  app?: string;
  kind?: string;
  message?: string;
};

/**
 * Fake terminal plus a stand-in for Pi's ProgramStatusReporter. The reporter
 * looks up `terminal.setProgramStatus` on every report (as Pi does) and, like
 * Pi, skips a report identical to its previous one.
 */
function createStatusHarness() {
  const written: Status[] = [];
  const terminal = {
    setProgramStatus: (status: Status) => {
      written.push(status);
    },
  };
  const original = terminal.setProgramStatus;
  let lastReported: string | undefined;
  const piReports = (status: Status): void => {
    const key = JSON.stringify(status);
    if (key === lastReported) return;
    lastReported = key;
    terminal.setProgramStatus(status);
  };
  return { terminal, original, written, piReports };
}

const oneQuestion: AskQuestion[] = [
  {
    id: "q",
    question: "Which\napproach?",
    options: [
      { value: "a", label: "A" },
      { value: "b", label: "B" },
    ],
  },
];

async function openDialog(
  tui: AskDialogTui,
  signal?: AbortSignal,
  getSessionName?: () => string | undefined,
) {
  let component: TestComponent | undefined;
  let resolveResult: ((value: AskDialogResult | undefined) => void) | undefined;
  const dialogPromise = runTerminalAskDialog(
    async (factory, options) => {
      component = factory(
        tui,
        { fg: (_t, text) => text, bg: (_t, text) => text, bold: (t) => t },
        null,
        (result) => resolveResult?.(result),
      );
      return new Promise<AskDialogResult | undefined>((resolve) => {
        resolveResult = resolve;
        // Pi's custom() settles with undefined when its signal aborts.
        options?.signal?.addEventListener("abort", () => resolve(undefined));
      });
    },
    oneQuestion,
    true,
    signal ? { signal } : undefined,
    getSessionName ? { getSessionName } : undefined,
  );
  if (!component) throw new Error("Dialog component was not created");
  return { component, dialogPromise };
}

const blocked: Status = {
  state: "blocked",
  kind: "question",
  app: "pi",
  message: "Which approach?",
};

describe("runTerminalAskDialog program status", () => {
  it("blocks while waiting, then returns to working with the session name when Pi sent nothing", async () => {
    const h = createStatusHarness();
    h.piReports({ state: "working", app: "pi", message: "Refactor" });
    expect(h.written).toHaveLength(1);

    const { component, dialogPromise } = await openDialog(
      { requestRender: () => {}, terminal: h.terminal },
      undefined,
      () => "Refactor",
    );
    // Pi re-reports the same status mid-dialog: its reporter skips it, so
    // nothing is held and nothing is written.
    h.piReports({ state: "working", app: "pi", message: "Refactor" });

    component.handleInput("\r");
    await expect(dialogPromise).resolves.toEqual({
      answers: { q: "a" },
      allIgnored: false,
    });

    expect(h.written.slice(1)).toEqual([
      blocked,
      { state: "working", app: "pi", message: "Refactor" },
    ]);
    expect(h.terminal.setProgramStatus).toBe(h.original);
  });

  it("omits the message from the working fallback when the session is unnamed", async () => {
    const h = createStatusHarness();
    const { component, dialogPromise } = await openDialog({
      requestRender: () => {},
      terminal: h.terminal,
    });

    component.handleInput("\r");
    await dialogPromise;

    expect(h.written).toEqual([blocked, { state: "working", app: "pi" }]);
  });

  it("replays Pi's latest report made during the dialog instead of staying blocked", async () => {
    const h = createStatusHarness();
    const { component, dialogPromise } = await openDialog(
      { requestRender: () => {}, terminal: h.terminal },
      undefined,
      () => "Ignored",
    );

    h.piReports({ state: "working", app: "pi", message: "first" });
    h.piReports({ state: "working", app: "pi", message: "second" });
    expect(h.written).toEqual([blocked]);

    component.handleInput("\r");
    await dialogPromise;

    expect(h.written).toEqual([
      blocked,
      { state: "working", app: "pi", message: "second" },
    ]);
  });

  it("restores Pi's status when the dialog is cancelled", async () => {
    const h = createStatusHarness();
    const { component, dialogPromise } = await openDialog(
      { requestRender: () => {}, terminal: h.terminal },
      undefined,
      () => "Named",
    );

    component.handleInput("\x1b");
    await expect(dialogPromise).resolves.toEqual({
      answers: {},
      allIgnored: true,
    });

    expect(h.written).toEqual([
      blocked,
      { state: "working", app: "pi", message: "Named" },
    ]);
    expect(h.terminal.setProgramStatus).toBe(h.original);
  });

  it("ends idle when the run is aborted and Pi reports idle after the dialog released", async () => {
    const h = createStatusHarness();
    const controller = new AbortController();
    const { dialogPromise } = await openDialog(
      { requestRender: () => {}, terminal: h.terminal },
      controller.signal,
      () => "Named",
    );

    controller.abort();
    await expect(dialogPromise).resolves.toBeUndefined();
    h.piReports({ state: "idle", app: "pi" });

    expect(h.written).toEqual([
      blocked,
      { state: "working", app: "pi", message: "Named" },
      { state: "idle", app: "pi" },
    ]);
  });

  it("ends idle when Pi reports idle during the dialog before the abort reaches it", async () => {
    const h = createStatusHarness();
    const controller = new AbortController();
    const { dialogPromise } = await openDialog(
      { requestRender: () => {}, terminal: h.terminal },
      controller.signal,
      () => "Named",
    );

    h.piReports({ state: "idle", app: "pi" });
    controller.abort();
    await dialogPromise;

    expect(h.written).toEqual([blocked, { state: "idle", app: "pi" }]);
    expect(h.terminal.setProgramStatus).toBe(h.original);
  });

  it("restores the terminal once even if several close paths fire", async () => {
    const h = createStatusHarness();
    const controller = new AbortController();
    const { component, dialogPromise } = await openDialog(
      { requestRender: () => {}, terminal: h.terminal },
      controller.signal,
    );

    component.handleInput("\r");
    await dialogPromise;
    controller.abort();

    expect(h.written).toHaveLength(2);
  });

  it("restores the terminal when the custom runner rejects", async () => {
    const h = createStatusHarness();
    await expect(
      runTerminalAskDialog(
        async (factory) => {
          factory(
            { requestRender: () => {}, terminal: h.terminal },
            { fg: (_t, text) => text, bg: (_t, text) => text, bold: (t) => t },
            null,
            () => {},
          );
          throw new Error("ui torn down");
        },
        oneQuestion,
        true,
      ),
    ).rejects.toThrow("ui torn down");

    expect(h.written).toEqual([blocked, { state: "working", app: "pi" }]);
    expect(h.terminal.setProgramStatus).toBe(h.original);
  });

  it("strips control characters from the question and session name before reporting", async () => {
    const h = createStatusHarness();
    const questions: AskQuestion[] = [
      {
        id: "q",
        question: "ok\x1b\\\x1b]52;c;AAAA\x07 \x9cnow",
        options: [
          { value: "a", label: "A" },
          { value: "b", label: "B" },
        ],
      },
    ];

    await runTerminalAskDialog(
      async (factory) => {
        factory(
          { requestRender: () => {}, terminal: h.terminal },
          { fg: (_t, text) => text, bg: (_t, text) => text, bold: (t) => t },
          null,
          () => {},
        );
        return undefined;
      },
      questions,
      true,
      undefined,
      { getSessionName: () => "na\x07me\x1b[2J" },
    );

    expect(h.written.map((status) => status.message)).toEqual([
      "ok \\ ]52;c;AAAA now",
      "na me [2J",
    ]);
  });

  it("still delivers the answer and restores the method when the replay write throws", async () => {
    const writes: Status[] = [];
    const terminal = {
      setProgramStatus: (status: Status) => {
        writes.push(status);
        if (status.state !== "blocked") throw new Error("write failed");
      },
    };
    const original = terminal.setProgramStatus;
    const { component, dialogPromise } = await openDialog({
      requestRender: () => {},
      terminal,
    });

    component.handleInput("\r");
    await expect(dialogPromise).resolves.toEqual({
      answers: { q: "a" },
      allIgnored: false,
    });
    expect(terminal.setProgramStatus).toBe(original);
    expect(writes.map((status) => status.state)).toEqual([
      "blocked",
      "working",
    ]);
  });

  it("restores the method and rethrows the original error when the blocked write fails", async () => {
    const terminal = {
      setProgramStatus: (_status: Status) => {
        throw new Error("write failed");
      },
    };
    const original = terminal.setProgramStatus;

    await expect(
      runTerminalAskDialog(
        async (factory) =>
          factory(
            { requestRender: () => {}, terminal },
            { fg: (_t, text) => text, bg: (_t, text) => text, bold: (t) => t },
            null,
            () => {},
          ) && undefined,
        oneQuestion,
        true,
      ),
    ).rejects.toThrow("write failed");
    expect(terminal.setProgramStatus).toBe(original);
  });

  it("works without setProgramStatus on older Pi", async () => {
    const { component, dialogPromise } = await openDialog({
      requestRender: () => {},
      terminal: {},
    });

    component.handleInput("\r");
    await expect(dialogPromise).resolves.toEqual({
      answers: { q: "a" },
      allIgnored: false,
    });
  });
});
