import { describe, expect, it } from "vitest";
import { execSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { encode, renderTerminal } from "../src/qr.js";

/** Write QR matrix as a scaled PGM image and decode with zbar. */
function zbarDecode(matrix: boolean[][]): string | null {
  const size = matrix.length;
  const border = 4;
  const mod = size + border * 2;
  const scale = 8;
  const total = mod * scale;

  const buf = Buffer.alloc(total * total, 255);
  for (let y = 0; y < mod; y++) {
    for (let x = 0; x < mod; x++) {
      const mx = x - border,
        my = y - border;
      const dark = mx >= 0 && mx < size && my >= 0 && my < size && matrix[my][mx];
      if (dark) {
        for (let dy = 0; dy < scale; dy++)
          for (let dx = 0; dx < scale; dx++) buf[(y * scale + dy) * total + (x * scale + dx)] = 0;
      }
    }
  }

  const header = `P5\n${total} ${total}\n255\n`;
  const path = `/tmp/qr-test-${Date.now()}.pgm`;
  writeFileSync(path, Buffer.concat([Buffer.from(header), buf]));

  try {
    const result = execSync(`zbarimg -q ${path}`, { encoding: "utf-8" }).trim();
    const match = result.match(/^QR-Code:(.*)$/s);
    return match ? match[1] : null;
  } catch {
    return null;
  }
}

/** Check if zbar is available. */
let hasZbar: boolean;
try {
  execSync("which zbarimg", { stdio: "ignore" });
  hasZbar = true;
} catch {
  hasZbar = false;
}

describe("QR encoder", () => {
  it("encodes short string as version 1 (21×21)", () => {
    const matrix = encode("Hello");
    expect(matrix.length).toBe(21);
    expect(matrix[0].length).toBe(21);
  });

  it("encodes medium string with correct version size", () => {
    const data = "https://example.com/pair?" + "x".repeat(80);
    const matrix = encode(data);
    const size = matrix.length;
    const version = (size - 17) / 4;
    expect(version).toBeGreaterThanOrEqual(5);
    expect(version).toBeLessThanOrEqual(8);
    expect(Number.isInteger(version)).toBe(true);
  });

  it("has correct finder patterns at three corners", () => {
    const matrix = encode("test");
    const n = matrix.length;

    // Top-left finder: outer ring dark
    for (let i = 0; i < 7; i++) {
      expect(matrix[0][i]).toBe(true);
      expect(matrix[6][i]).toBe(true);
      expect(matrix[i][0]).toBe(true);
      expect(matrix[i][6]).toBe(true);
    }
    // Center 3×3 dark
    for (let r = 2; r <= 4; r++) {
      for (let c = 2; c <= 4; c++) {
        expect(matrix[r][c]).toBe(true);
      }
    }

    // Top-right finder
    for (let i = 0; i < 7; i++) {
      expect(matrix[0][n - 7 + i]).toBe(true);
      expect(matrix[6][n - 7 + i]).toBe(true);
    }

    // Bottom-left finder
    for (let i = 0; i < 7; i++) {
      expect(matrix[n - 7][i]).toBe(true);
      expect(matrix[n - 1][i]).toBe(true);
    }
  });

  it("produces terminal output with consistent line widths", () => {
    const url = "oppi://connect?v=2&invite=eyJ0ZXN0IjoidmFsdWUifQ";
    const output = renderTerminal(url);
    const lines = output.split("\n");
    expect(lines.length).toBeGreaterThan(5);
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
    const matrixRows = Math.ceil(matrix.length / 2);
    expect(lines.length).toBeGreaterThan(matrixRows);
  });
});

describe.skipIf(!hasZbar)("QR encoder conformance (zbar)", () => {
  it("decodes short string", () => {
    expect(zbarDecode(encode("HELLO"))).toBe("HELLO");
  });

  it("decodes URL", () => {
    const url = "https://example.com/test?foo=bar&baz=42";
    expect(zbarDecode(encode(url))).toBe(url);
  });

  it("decodes 100-byte payload", () => {
    const data = "X".repeat(100);
    expect(zbarDecode(encode(data))).toBe(data);
  });

  it("decodes 300-byte payload", () => {
    const data = "Y".repeat(300);
    expect(zbarDecode(encode(data))).toBe(data);
  });

  it("decodes realistic invite JSON (~484 bytes)", () => {
    const invite = JSON.stringify({
      v: 2,
      alg: "Ed25519",
      kid: "srv-default",
      iat: 1771268687,
      exp: 1771269287,
      nonce: "LS-oc_4tVIv1LPQh",
      publicKey: "f_QFx-E-W44v653BYJ60uMOTMCB7eCRaN5_jZ23C2vk",
      payload: {
        host: "mac-studio.taila3ebc.ts.net",
        port: 7749,
        token: "sk_testtoken123456789012345",
        name: "mac-studio",
        fingerprint: "sha256:rHLwUOOWstvDHskxjWWWY2EQxQnouizidfxV7r3EWPw",
        securityProfile: "tailscale-permissive",
      },
      sig: "c37C8IG2BCzOEu8SyVYahYc1VMwT0s3c2bXe8WwsUgbkdZ3l1nFk6spsCd4qGuK8Hrd4ygeIg0LUNDjJgLeoAA",
    });
    expect(zbarDecode(encode(invite))).toBe(invite);
  });

  it("decodes UTF-8 content", () => {
    const text = "Hello 世界 🌍";
    expect(zbarDecode(encode(text))).toBe(text);
  });

  it("decodes Uint8Array input", () => {
    const bytes = new Uint8Array([72, 101, 108, 108, 111]); // "Hello"
    expect(zbarDecode(encode(bytes))).toBe("Hello");
  });
});
