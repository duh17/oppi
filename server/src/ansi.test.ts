import { describe, expect, it } from "vitest";
import { stripAnsiEscapes } from "./ansi.js";

describe("stripAnsiEscapes", () => {
  it("returns plain text unchanged", () => {
    expect(stripAnsiEscapes("hello world")).toBe("hello world");
  });

  it("returns empty string unchanged", () => {
    expect(stripAnsiEscapes("")).toBe("");
  });

  it("strips SGR color codes (16-color)", () => {
    expect(stripAnsiEscapes("\x1b[31mred text\x1b[0m")).toBe("red text");
  });

  it("strips SGR color codes (256-color)", () => {
    expect(stripAnsiEscapes("\x1b[38;5;59m─\x1b[39m")).toBe("─");
  });

  it("strips SGR color codes (24-bit)", () => {
    expect(stripAnsiEscapes("\x1b[38;2;255;100;0mhello\x1b[0m")).toBe("hello");
  });

  it("strips bold/dim/reverse", () => {
    expect(stripAnsiEscapes("\x1b[1mbold\x1b[0m \x1b[2mdim\x1b[0m \x1b[7mreverse\x1b[0m")).toBe(
      "bold dim reverse",
    );
  });

  it("strips cursor movement sequences", () => {
    // CUU (cursor up), CUD, CUF, CUB, CHA (cursor horizontal absolute)
    expect(stripAnsiEscapes("\x1b[3A\x1b[1G\x1b[2Khello")).toBe("hello");
  });

  it("strips erase sequences", () => {
    // EL (erase line), ED (erase display)
    expect(stripAnsiEscapes("\x1b[2Khello\x1b[Jworld")).toBe("helloworld");
  });

  it("strips private mode set/reset (DEC)", () => {
    // bracketed paste, cursor visibility, synchronized output
    expect(stripAnsiEscapes("\x1b[?2004h\x1b[?25l\x1b[?2026hhello\x1b[?25h\x1b[?2004l")).toBe(
      "hello",
    );
  });

  it("strips kitty keyboard protocol", () => {
    expect(stripAnsiEscapes("\x1b[?uhello")).toBe("hello");
  });

  it("strips OSC sequences terminated by BEL", () => {
    // Window title: OSC 0 ; title BEL
    expect(stripAnsiEscapes("\x1b]0;π - dotfiles\x07hello")).toBe("hello");
  });

  it("strips OSC sequences terminated by ST (ESC backslash)", () => {
    // Hyperlink: OSC 8 ;; url ST
    expect(stripAnsiEscapes("\x1b]8;;\x1b\\hello\x1b]8;;\x1b\\")).toBe("hello");
  });

  it("strips shell integration marks (FinalTerm/OSC 133)", () => {
    expect(stripAnsiEscapes("\x1b]133;A\x07prompt\x1b]133;B\x07")).toBe("prompt");
  });

  it("strips xterm modifyOtherKeys", () => {
    expect(stripAnsiEscapes("\x1b[>4;2mhello")).toBe("hello");
  });

  it("handles pi TUI output (real-world sample)", () => {
    // Simplified version of the bug report: colored box-drawing + status line
    const input =
      "\x1b[38;5;59m─\x1b[39m\x1b[38;5;59m─\x1b[39m\x1b[38;5;59m─\x1b[39m\n" +
      "\x1b[7m \x1b[0m cursor\n" +
      "\x1b[38;5;59m$0.000 (sub)\x1b[39m";
    expect(stripAnsiEscapes(input)).toBe("───\n  cursor\n$0.000 (sub)");
  });

  it("handles pi TUI error output", () => {
    const input = '\x1b[38;5;167mError: 404 {"type":"error"}\x1b[39m';
    expect(stripAnsiEscapes(input)).toBe('Error: 404 {"type":"error"}');
  });

  it("strips spinner output", () => {
    const input = "\x1b[38;5;179m⠋\x1b[39m \x1b[38;5;60mWorking...\x1b[39m";
    expect(stripAnsiEscapes(input)).toBe("⠋ Working...");
  });

  it("preserves newlines and whitespace", () => {
    expect(stripAnsiEscapes("line1\nline2\n  indented\n")).toBe("line1\nline2\n  indented\n");
  });

  it("strips mixed CSI and OSC in sequence", () => {
    const input =
      "\x1b[?2004h\x1b[?u\x1b[?25l\x1b[?2026h\x1b[0m\x1b]8;;\x1b\\hello\x1b]0;title\x07";
    expect(stripAnsiEscapes(input)).toBe("hello");
  });

  it("handles background color codes", () => {
    expect(stripAnsiEscapes("\x1b[48;5;16m text \x1b[49m")).toBe(" text ");
  });

  it("handles compound SGR (bold + color)", () => {
    expect(stripAnsiEscapes("\x1b[1;35mmagenta\x1b[0m")).toBe("magenta");
  });
});
