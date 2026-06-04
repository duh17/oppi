import { describe, expect, it } from "vitest";
import { sanitizeToolResultDetails } from "../src/visual-schema.js";

describe("sanitizeToolResultDetails", () => {
  it("preserves details that do not contain legacy ui payloads", () => {
    const details = {
      action: "release",
      expandedText: "# Released\n\nDone.",
      presentationFormat: "markdown",
      todo: { id: "TODO-1234", title: "Ship it" },
    };

    const result = sanitizeToolResultDetails(details);

    expect(result.details).toBe(details);
    expect(result.warnings).toEqual([]);
  });

  it("drops legacy ui payloads and preserves non-ui fields", () => {
    const result = sanitizeToolResultDetails({
      source: "plot-extension",
      expandedText: "Chart fallback text",
      presentationFormat: "markdown",
      ui: [
        {
          id: "chart-1",
          kind: "chart",
          version: 1,
          spec: {
            dataset: { rows: [{ x: 0, y: 1 }] },
            marks: [{ type: "line", x: "x", y: "y" }],
          },
        },
      ],
    });

    expect(result.details).toEqual({
      source: "plot-extension",
      expandedText: "Chart fallback text",
      presentationFormat: "markdown",
    });
    expect(result.warnings).toEqual(["dropped unsupported details.ui payload"]);
  });

  it("returns non-object details unchanged", () => {
    const result = sanitizeToolResultDetails("plain output details");

    expect(result.details).toBe("plain output details");
    expect(result.warnings).toEqual([]);
  });
});
