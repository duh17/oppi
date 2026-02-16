import { describe, expect, it } from "vitest";
import { encode, renderTerminal } from "../src/qr.js";

describe("QR encoder", () => {
  it("encodes short string as version 1 (21×21)", () => {
    const matrix = encode("Hello");
    expect(matrix.length).toBe(21);
    expect(matrix[0].length).toBe(21);
  });

  it("encodes medium string with correct version size", () => {
    // ~100 bytes → version 6 (41×41) or 7 (45×45)
    const data = "https://example.com/pair?" + "x".repeat(80);
    const matrix = encode(data);
    const size = matrix.length;
    // Version = (size - 17) / 4
    const version = (size - 17) / 4;
    expect(version).toBeGreaterThanOrEqual(5);
    expect(version).toBeLessThanOrEqual(8);
    expect(Number.isInteger(version)).toBe(true);
  });

  it("has correct finder patterns at three corners", () => {
    const matrix = encode("test");
    const n = matrix.length;

    // Top-left finder: 7×7 pattern with dark border, light inner, dark center
    // Outer ring should be dark
    for (let i = 0; i < 7; i++) {
      expect(matrix[0][i]).toBe(true); // top row
      expect(matrix[6][i]).toBe(true); // bottom row
      expect(matrix[i][0]).toBe(true); // left col
      expect(matrix[i][6]).toBe(true); // right col
    }
    // Center 3×3 should be dark
    for (let r = 2; r <= 4; r++) {
      for (let c = 2; c <= 4; c++) {
        expect(matrix[r][c]).toBe(true);
      }
    }

    // Top-right finder: same pattern at (0, n-7)
    for (let i = 0; i < 7; i++) {
      expect(matrix[0][n - 7 + i]).toBe(true); // top row
      expect(matrix[6][n - 7 + i]).toBe(true); // bottom row
    }

    // Bottom-left finder: same pattern at (n-7, 0)
    for (let i = 0; i < 7; i++) {
      expect(matrix[n - 7][i]).toBe(true); // top row
      expect(matrix[n - 1][i]).toBe(true); // bottom row
    }
  });

  it("produces scannable terminal output for a URL", () => {
    const url = "oppi://connect?v=2&invite=eyJ0ZXN0IjoidmFsdWUifQ";
    const output = renderTerminal(url);
    // Should produce multiple lines of unicode characters
    const lines = output.split("\n");
    expect(lines.length).toBeGreaterThan(5);
    // Every line should have the same width
    const widths = new Set(lines.map((l) => [...l].length));
    expect(widths.size).toBe(1);
  });

  it("handles large payloads (400+ bytes)", () => {
    const payload = "oppi://connect?v=2&invite=" + "A".repeat(400);
    const matrix = encode(payload);
    const version = (matrix.length - 17) / 4;
    expect(version).toBeGreaterThanOrEqual(10);
    expect(version).toBeLessThanOrEqual(25);
  });

  it("renders with quiet zone", () => {
    const matrix = encode("Hi");
    const output = renderTerminal("Hi");
    const lines = output.split("\n");
    // Output should be taller than matrix height / 2 (quiet zone adds rows)
    const matrixRows = Math.ceil(matrix.length / 2);
    expect(lines.length).toBeGreaterThan(matrixRows);
  });
});
