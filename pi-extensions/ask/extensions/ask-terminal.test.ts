import { describe, expect, it } from "vitest";

import type { AskDialogResult, AskQuestion } from "./ask-shared.js";
import { runTerminalAskDialog } from "./ask-terminal.js";

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
