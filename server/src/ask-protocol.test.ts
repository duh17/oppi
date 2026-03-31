import { describe, expect, it } from "vitest";
import type { AskOption, AskQuestion, ServerMessage, ClientMessage } from "./types.js";

describe("AskOption", () => {
  it("accepts value and label only", () => {
    const opt: AskOption = { value: "unit", label: "Unit tests only" };
    expect(opt.value).toBe("unit");
    expect(opt.label).toBe("Unit tests only");
    expect(opt.description).toBeUndefined();
  });

  it("accepts optional description", () => {
    const opt: AskOption = {
      value: "integration",
      label: "Integration tests",
      description: "Test the full pipeline end-to-end",
    };
    expect(opt.description).toBe("Test the full pipeline end-to-end");
  });
});

describe("AskQuestion", () => {
  it("accepts a single-select question", () => {
    const q: AskQuestion = {
      id: "approach",
      question: "What testing approach do you prefer?",
      options: [
        { value: "unit", label: "Unit tests only" },
        { value: "integration", label: "Integration tests" },
      ],
    };
    expect(q.id).toBe("approach");
    expect(q.options).toHaveLength(2);
    expect(q.multiSelect).toBeUndefined();
  });

  it("accepts a multi-select question", () => {
    const q: AskQuestion = {
      id: "frameworks",
      question: "Which test frameworks should I set up?",
      options: [
        { value: "jest", label: "Jest", description: "Mature, wide ecosystem" },
        { value: "vitest", label: "Vitest", description: "Fast, Vite-native" },
      ],
      multiSelect: true,
    };
    expect(q.multiSelect).toBe(true);
    expect(q.options[0].description).toBe("Mature, wide ecosystem");
  });
});

describe("extension_ui_request with ask method", () => {
  it("type-checks a single-question ask request", () => {
    const msg: ServerMessage = {
      type: "extension_ui_request",
      id: "ask-uuid-1",
      sessionId: "session-abc",
      method: "ask",
      questions: [
        {
          id: "approach",
          question: "What testing approach do you prefer?",
          options: [
            { value: "unit", label: "Unit tests only", description: "Fast, isolated" },
            { value: "both", label: "Both" },
          ],
        },
      ],
    };
    expect(msg.type).toBe("extension_ui_request");
    if (msg.type === "extension_ui_request") {
      expect(msg.questions).toHaveLength(1);
      expect(msg.questions![0].id).toBe("approach");
      expect(msg.allowCustom).toBeUndefined();
    }
  });

  it("type-checks a multi-question ask request with mixed selection modes", () => {
    const msg: ServerMessage = {
      type: "extension_ui_request",
      id: "ask-uuid-2",
      sessionId: "session-abc",
      method: "ask",
      questions: [
        {
          id: "approach",
          question: "What testing approach?",
          options: [
            { value: "unit", label: "Unit tests" },
            { value: "integration", label: "Integration" },
          ],
          multiSelect: false,
        },
        {
          id: "frameworks",
          question: "Which frameworks?",
          options: [
            { value: "jest", label: "Jest" },
            { value: "vitest", label: "Vitest" },
            { value: "playwright", label: "Playwright" },
          ],
          multiSelect: true,
        },
      ],
      allowCustom: true,
    };
    if (msg.type === "extension_ui_request") {
      expect(msg.questions).toHaveLength(2);
      expect(msg.questions![0].multiSelect).toBe(false);
      expect(msg.questions![1].multiSelect).toBe(true);
      expect(msg.allowCustom).toBe(true);
    }
  });

  it("coexists with existing select method using string options", () => {
    const msg: ServerMessage = {
      type: "extension_ui_request",
      id: "select-uuid-1",
      sessionId: "session-abc",
      method: "select",
      title: "Pick a color",
      options: ["red", "green", "blue"],
    };
    if (msg.type === "extension_ui_request") {
      expect(msg.options).toEqual(["red", "green", "blue"]);
      expect(msg.questions).toBeUndefined();
    }
  });
});

describe("extension_ui_response with ask answers", () => {
  it("accepts JSON-encoded answers in the value field", () => {
    const answers = { approach: "unit", frameworks: ["jest", "vitest"] };
    const msg: ClientMessage = {
      type: "extension_ui_response",
      id: "ask-uuid-1",
      value: JSON.stringify(answers),
    };
    if (msg.type === "extension_ui_response") {
      const parsed = JSON.parse(msg.value as string);
      expect(parsed.approach).toBe("unit");
      expect(parsed.frameworks).toEqual(["jest", "vitest"]);
    }
  });

  it("accepts partial answers when user skips questions", () => {
    const answers = { approach: "unit" };
    const msg: ClientMessage = {
      type: "extension_ui_response",
      id: "ask-uuid-1",
      value: JSON.stringify(answers),
    };
    if (msg.type === "extension_ui_response") {
      const parsed = JSON.parse(msg.value as string);
      expect(parsed.approach).toBe("unit");
      expect(parsed.frameworks).toBeUndefined();
    }
  });

  it("accepts cancelled response when user ignores all questions", () => {
    const msg: ClientMessage = {
      type: "extension_ui_response",
      id: "ask-uuid-1",
      cancelled: true,
    };
    if (msg.type === "extension_ui_response") {
      expect(msg.cancelled).toBe(true);
    }
  });
});
