import { describe, expect, it } from "vitest";
import {
  green,
  stripAllAnsiEscapes,
  stripAnsiEscapes,
  terminalLineToTextSpans,
  terminalLineVisibleText,
  withAnsiCapture,
} from "../src/ansi.js";

describe("ANSI capture", () => {
  it("enables ANSI styling inside non-TTY capture scopes", () => {
    const previous = process.env.NO_COLOR;
    delete process.env.NO_COLOR;
    try {
      const styled = withAnsiCapture(() => green("ready"));
      expect(styled).toBe("\x1b[32mready\x1b[0m");
    } finally {
      if (previous === undefined) delete process.env.NO_COLOR;
      else process.env.NO_COLOR = previous;
    }
  });

  it("honors NO_COLOR inside non-TTY capture scopes", () => {
    const previous = process.env.NO_COLOR;
    process.env.NO_COLOR = "1";
    try {
      expect(withAnsiCapture(() => green("ready"))).toBe("ready");
    } finally {
      if (previous === undefined) delete process.env.NO_COLOR;
      else process.env.NO_COLOR = previous;
    }
  });

  it("strips all ANSI styling from dynamic terminal values", () => {
    expect(stripAllAnsiEscapes("\x1b[31mred\x1b[0m text")).toBe("red text");
  });
});

describe("stripAnsiEscapes", () => {
  it("returns plain text unchanged", () => {
    expect(stripAnsiEscapes("hello world")).toBe("hello world");
  });

  it("returns empty string unchanged", () => {
    expect(stripAnsiEscapes("")).toBe("");
  });

  // ─── SGR codes are PRESERVED (iOS ANSIParser renders them) ───

  it("preserves SGR color codes (16-color)", () => {
    expect(stripAnsiEscapes("\x1b[31mred text\x1b[0m")).toBe("\x1b[31mred text\x1b[0m");
  });

  it("preserves SGR color codes (256-color)", () => {
    expect(stripAnsiEscapes("\x1b[38;5;59m─\x1b[39m")).toBe("\x1b[38;5;59m─\x1b[39m");
  });

  it("preserves SGR color codes (24-bit)", () => {
    expect(stripAnsiEscapes("\x1b[38;2;255;100;0mhello\x1b[0m")).toBe(
      "\x1b[38;2;255;100;0mhello\x1b[0m",
    );
  });

  it("preserves bold/dim/reverse SGR codes", () => {
    const input = "\x1b[1mbold\x1b[0m \x1b[2mdim\x1b[0m \x1b[7mreverse\x1b[0m";
    expect(stripAnsiEscapes(input)).toBe(input);
  });

  it("preserves background color codes", () => {
    expect(stripAnsiEscapes("\x1b[48;5;16m text \x1b[49m")).toBe("\x1b[48;5;16m text \x1b[49m");
  });

  it("preserves compound SGR (bold + color)", () => {
    expect(stripAnsiEscapes("\x1b[1;35mmagenta\x1b[0m")).toBe("\x1b[1;35mmagenta\x1b[0m");
  });

  it("preserves reset code", () => {
    expect(stripAnsiEscapes("\x1b[0m")).toBe("\x1b[0m");
  });

  // ─── Non-SGR sequences are STRIPPED ───

  it("strips cursor movement sequences", () => {
    expect(stripAnsiEscapes("\x1b[3A\x1b[1G\x1b[2Khello")).toBe("hello");
  });

  it("strips erase sequences", () => {
    expect(stripAnsiEscapes("\x1b[2Khello\x1b[Jworld")).toBe("helloworld");
  });

  it("strips private mode set/reset (DEC)", () => {
    expect(stripAnsiEscapes("\x1b[?2004h\x1b[?25l\x1b[?2026hhello\x1b[?25h\x1b[?2004l")).toBe(
      "hello",
    );
  });

  it("strips kitty keyboard protocol", () => {
    expect(stripAnsiEscapes("\x1b[?uhello")).toBe("hello");
  });

  it("strips OSC sequences terminated by BEL", () => {
    expect(stripAnsiEscapes("\x1b]0;π - dotfiles\x07hello")).toBe("hello");
  });

  it("strips OSC sequences terminated by ST (ESC backslash)", () => {
    expect(stripAnsiEscapes("\x1b]8;;\x1b\\hello\x1b]8;;\x1b\\")).toBe("hello");
  });

  it("strips shell integration marks (FinalTerm/OSC 133)", () => {
    expect(stripAnsiEscapes("\x1b]133;A\x07prompt\x1b]133;B\x07")).toBe("prompt");
  });

  it("strips xterm modifyOtherKeys", () => {
    expect(stripAnsiEscapes("\x1b[>4;2mhello")).toBe("hello");
  });

  // ─── Mixed: SGR preserved, non-SGR stripped ───

  it("preserves colors in pi TUI output while stripping cursor movement", () => {
    const input =
      "\x1b[38;5;59m─\x1b[39m\x1b[38;5;59m─\x1b[39m\x1b[38;5;59m─\x1b[39m\n" +
      "\x1b[7m \x1b[0m cursor\n" +
      "\x1b[38;5;59m$0.000 (sub)\x1b[39m";
    const expected =
      "\x1b[38;5;59m─\x1b[39m\x1b[38;5;59m─\x1b[39m\x1b[38;5;59m─\x1b[39m\n" +
      "\x1b[7m \x1b[0m cursor\n" +
      "\x1b[38;5;59m$0.000 (sub)\x1b[39m";
    expect(stripAnsiEscapes(input)).toBe(expected);
  });

  it("preserves error colors", () => {
    const input = '\x1b[38;5;167mError: 404 {"type":"error"}\x1b[39m';
    expect(stripAnsiEscapes(input)).toBe(input);
  });

  it("preserves spinner colors", () => {
    const input = "\x1b[38;5;179m⠋\x1b[39m \x1b[38;5;60mWorking...\x1b[39m";
    expect(stripAnsiEscapes(input)).toBe(input);
  });

  it("preserves newlines and whitespace", () => {
    expect(stripAnsiEscapes("line1\nline2\n  indented\n")).toBe("line1\nline2\n  indented\n");
  });

  it("strips non-SGR but preserves SGR in mixed sequence", () => {
    // DEC modes + kitty + OSC stripped; SGR reset preserved
    const input =
      "\x1b[?2004h\x1b[?u\x1b[?25l\x1b[?2026h\x1b[0m\x1b]8;;\x1b\\hello\x1b]0;title\x07";
    expect(stripAnsiEscapes(input)).toBe("\x1b[0mhello");
  });

  it("preserves vitest-style colored output", () => {
    // Green checkmark + test name — the real-world case that was broken
    const input =
      "\x1b[32m✓\x1b[39m src/file.test.ts \x1b[2m(5 tests)\x1b[22m \x1b[33m34ms\x1b[39m";
    expect(stripAnsiEscapes(input)).toBe(input);
  });

  it("preserves npm colored output", () => {
    const input = "\x1b[1;32mnpm\x1b[0m test";
    expect(stripAnsiEscapes(input)).toBe(input);
  });
});

describe("terminalLineToTextSpans", () => {
  it("preserves OSC-8 links terminated by BEL as semantic spans", () => {
    const input = "Open \x1b]8;;oppi://session/child-1\x07child\x1b]8;;\x07 now";

    expect(terminalLineToTextSpans(input)).toEqual([
      { text: "Open " },
      { text: "child", link: "oppi://session/child-1" },
      { text: " now" },
    ]);
    expect(terminalLineVisibleText(input)).toBe("Open child now");
  });

  it("preserves OSC-8 links terminated by ST as semantic spans", () => {
    const input = "\x1b]8;id=docs;https://example.com/docs\x1b\\Docs\x1b]8;;\x1b\\";

    expect(terminalLineToTextSpans(input)).toEqual([
      { text: "Docs", link: "https://example.com/docs" },
    ]);
    expect(terminalLineVisibleText(input)).toBe("Docs");
  });

  it("maps a small SGR subset to native semantic roles and traits", () => {
    const input = "\x1b[1;31mDanger\x1b[0m \x1b[4;36mlinkish\x1b[0m";

    expect(terminalLineToTextSpans(input)).toEqual([
      { text: "Danger", role: "danger", traits: ["bold"] },
      { text: " " },
      { text: "linkish", role: "accent", traits: ["underline"] },
    ]);
  });

  it("strips non-link OSC and cursor control from visible fallback text", () => {
    const input = "\x1b]0;window title\x07\x1b[2KReady";

    expect(terminalLineToTextSpans(input)).toEqual([{ text: "Ready" }]);
    expect(terminalLineVisibleText(input)).toBe("Ready");
  });
});
