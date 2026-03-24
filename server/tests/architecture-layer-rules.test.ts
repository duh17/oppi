import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import {
  findIosLayerViolations,
  findServerLayerViolations,
} from "../scripts/architecture-layer-rules.mjs";

function write(path: string, content: string): void {
  mkdirSync(join(path, ".."), { recursive: true });
  writeFileSync(path, content);
}

describe("architecture layer rule helpers", () => {
  it("flags types.ts imports as protocol leaf violations", () => {
    const repoRoot = mkdtempSync(join(tmpdir(), "oppi-arch-server-"));

    try {
      write(join(repoRoot, "server/src/types.ts"), 'import type { X } from "./foo.js";\n');
      write(join(repoRoot, "server/src/foo.ts"), "export interface X { value: string; }\n");

      const violations = findServerLayerViolations(repoRoot);
      expect(violations).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            rule: "types-protocol-leaf",
            importer: "server/src/types.ts",
            target: "./foo.js",
          }),
        ]),
      );
    } finally {
      rmSync(repoRoot, { recursive: true, force: true });
    }
  });

  it("flags gate imports of session runtime modules", () => {
    const repoRoot = mkdtempSync(join(tmpdir(), "oppi-arch-gate-"));

    try {
      write(join(repoRoot, "server/src/gate.ts"), 'import "./session-lifecycle.js";\n');
      write(join(repoRoot, "server/src/session-lifecycle.ts"), "export const x = 1;\n");

      const violations = findServerLayerViolations(repoRoot);
      expect(violations).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            rule: "gate-runtime-boundary",
            importer: "server/src/gate.ts",
            target: "server/src/session-lifecycle.ts",
          }),
        ]),
      );
    } finally {
      rmSync(repoRoot, { recursive: true, force: true });
    }
  });

  it("flags iOS runtime UIKit imports and view direct APIClient use", () => {
    const repoRoot = mkdtempSync(join(tmpdir(), "oppi-arch-ios-"));

    try {
      write(join(repoRoot, "clients/apple/Oppi/Core/Runtime/TimelineReducer.swift"), "import UIKit\n");
      write(join(repoRoot, "clients/apple/Oppi/Core/Runtime/DeltaCoalescer.swift"), "import Foundation\n");

      write(
        join(repoRoot, "clients/apple/Oppi/Core/Views/BadView.swift"),
        [
          "import Foundation",
          "struct BadView {",
          "  let client = APIClient()",
          "}",
        ].join("\n"),
      );

      write(join(repoRoot, "clients/apple/Oppi/Core/Services/SessionStore.swift"), "import Foundation\n");
      write(join(repoRoot, "clients/apple/Oppi/Core/Services/WorkspaceStore.swift"), "import Foundation\n");
      write(
        join(repoRoot, "clients/apple/Oppi/Core/Services/PermissionStore.swift"),
        [
          "import Foundation",
          "/// Separate from SessionStore so permission ticks do not churn session UI.",
          "final class PermissionStore {}",
        ].join("\n"),
      );
      write(join(repoRoot, "clients/apple/Oppi/Core/Services/MessageQueueStore.swift"), "import Foundation\n");

      const violations = findIosLayerViolations(repoRoot);

      expect(violations).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            rule: "runtime-no-uikit",
            file: "clients/apple/Oppi/Core/Runtime/TimelineReducer.swift",
          }),
          expect.objectContaining({
            rule: "view-layer-network-boundary",
            file: "clients/apple/Oppi/Core/Views/BadView.swift",
          }),
        ]),
      );

      const storeIsolationViolations = violations.filter((violation) => violation.rule === "store-isolation");
      expect(storeIsolationViolations).toHaveLength(0);
    } finally {
      rmSync(repoRoot, { recursive: true, force: true });
    }
  });
});
