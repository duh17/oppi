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
  it("flags server tests placed under src", () => {
    const repoRoot = mkdtempSync(join(tmpdir(), "oppi-arch-src-tests-"));

    try {
      write(join(repoRoot, "server/src/leaked.test.ts"), "import { describe } from 'vitest';\n");

      const violations = findServerLayerViolations(repoRoot);
      expect(violations).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            rule: "server-test-placement",
            file: "server/src/leaked.test.ts",
            target: "server/tests/**",
          }),
        ]),
      );
    } finally {
      rmSync(repoRoot, { recursive: true, force: true });
    }
  });

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

  it("flags iOS runtime UIKit imports and view direct APIClient use", () => {
    const repoRoot = mkdtempSync(join(tmpdir(), "oppi-arch-ios-"));

    try {
      write(
        join(repoRoot, "clients/apple/OppiCore/Runtime/TimelineReducer.swift"),
        "import UIKit\n",
      );
      write(
        join(repoRoot, "clients/apple/OppiCore/Runtime/DeltaCoalescer.swift"),
        "import Foundation\n",
      );

      write(
        join(repoRoot, "clients/apple/Oppi/Core/Views/BadView.swift"),
        ["import Foundation", "struct BadView {", "  let client = APIClient()", "}"].join("\n"),
      );

      write(
        join(repoRoot, "clients/apple/Oppi/Core/Services/SessionStore.swift"),
        "import Foundation\n",
      );
      write(
        join(repoRoot, "clients/apple/Oppi/Core/Services/WorkspaceStore.swift"),
        "import Foundation\n",
      );
      write(
        join(repoRoot, "clients/apple/OppiCore/Stores/AskRequestStore.swift"),
        "import Foundation\n",
      );
      write(
        join(repoRoot, "clients/apple/OppiCore/Stores/MessageQueueStore.swift"),
        "import Foundation\n",
      );
      write(
        join(repoRoot, "clients/apple/OppiCore/Stores/ReviewCommentStore.swift"),
        "import Foundation\n",
      );
      write(
        join(repoRoot, "clients/apple/OppiCore/Stores/FileIndexStore.swift"),
        "import Foundation\n",
      );
      write(
        join(repoRoot, "clients/apple/OppiCore/Stores/GitStatusStore.swift"),
        "import Foundation\n",
      );

      const violations = findIosLayerViolations(repoRoot);

      expect(violations).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            rule: "runtime-no-uikit",
            file: "clients/apple/OppiCore/Runtime/TimelineReducer.swift",
          }),
          expect.objectContaining({
            rule: "view-layer-network-boundary",
            file: "clients/apple/Oppi/Core/Views/BadView.swift",
          }),
        ]),
      );

      const storeIsolationViolations = violations.filter(
        (violation) => violation.rule === "store-isolation",
      );
      expect(storeIsolationViolations).toHaveLength(0);
    } finally {
      rmSync(repoRoot, { recursive: true, force: true });
    }
  });

  it("flags platform imports in non-adapter shared Apple core files", () => {
    const repoRoot = mkdtempSync(join(tmpdir(), "oppi-arch-apple-core-"));

    try {
      write(
        join(repoRoot, "clients/apple/OppiCore/Models/BadDTO.swift"),
        ["import Foundation", "import SwiftUI", "struct BadDTO {}"].join("\n"),
      );
      write(
        join(repoRoot, "clients/apple/OppiCore/PlatformAdapters/MacImageAdapter.swift"),
        ["import AppKit", "struct MacImageAdapter {}"].join("\n"),
      );

      const violations = findIosLayerViolations(repoRoot);

      expect(violations).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            rule: "apple-shared-core-platform-import",
            file: "clients/apple/OppiCore/Models/BadDTO.swift",
          }),
        ]),
      );
      expect(violations).not.toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            rule: "apple-shared-core-platform-import",
            file: "clients/apple/OppiCore/PlatformAdapters/MacImageAdapter.swift",
          }),
        ]),
      );
    } finally {
      rmSync(repoRoot, { recursive: true, force: true });
    }
  });

  it("flags workspace and quick-session views that read full session lists", () => {
    const repoRoot = mkdtempSync(join(tmpdir(), "oppi-arch-ios-list-projection-"));

    try {
      write(
        join(repoRoot, "clients/apple/Oppi/Features/Workspaces/BadWorkspaceView.swift"),
        [
          "import SwiftUI",
          "struct BadWorkspaceView: View {",
          "  @Environment(SessionStore.self) private var sessionStore",
          "  var body: some View { Text(String(sessionStore.sessions.count)) }",
          "}",
        ].join("\n"),
      );

      write(
        join(repoRoot, "clients/apple/Oppi/Features/QuickSession/BadQuickSessionView.swift"),
        [
          "import SwiftUI",
          "struct BadQuickSessionView: View {",
          "  let conn: ServerConnection",
          "  var body: some View { Text(String(conn.sessionStore.sessions.count)) }",
          "}",
        ].join("\n"),
      );

      const violations = findIosLayerViolations(repoRoot);

      expect(violations).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            rule: "list-projection-consumer",
            file: "clients/apple/Oppi/Features/Workspaces/BadWorkspaceView.swift",
          }),
          expect.objectContaining({
            rule: "list-projection-consumer",
            file: "clients/apple/Oppi/Features/QuickSession/BadQuickSessionView.swift",
          }),
        ]),
      );
    } finally {
      rmSync(repoRoot, { recursive: true, force: true });
    }
  });

  it("flags Pi AI compat imports outside the Pi model/auth boundary", () => {
    const repoRoot = mkdtempSync(join(tmpdir(), "oppi-arch-pi-ai-compat-"));

    try {
      write(
        join(repoRoot, "server/src/random-title-helper.ts"),
        'import { completeSimple } from "@earendil-works/pi-ai/compat";\nexport { completeSimple };\n',
      );
      write(
        join(repoRoot, "server/src/pi-model-auth-service.ts"),
        'import { getModel } from "@earendil-works/pi-ai/compat";\nexport { getModel };\n',
      );

      const violations = findServerLayerViolations(repoRoot);

      expect(violations).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            rule: "pi-ai-compat-boundary",
            file: "server/src/random-title-helper.ts",
            target: "@earendil-works/pi-ai/compat",
          }),
        ]),
      );
      expect(violations).not.toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            rule: "pi-ai-compat-boundary",
            file: "server/src/pi-model-auth-service.ts",
          }),
        ]),
      );
    } finally {
      rmSync(repoRoot, { recursive: true, force: true });
    }
  });

  it("flags route modules importing other concrete route modules", () => {
    const repoRoot = mkdtempSync(join(tmpdir(), "oppi-arch-route-import-"));

    try {
      write(
        join(repoRoot, "server/src/routes/sessions.ts"),
        'import { createWorkspaceRoutes } from "./workspaces.js";\nexport { createWorkspaceRoutes };\n',
      );
      write(
        join(repoRoot, "server/src/routes/workspaces.ts"),
        "export function createWorkspaceRoutes(): void {}\n",
      );
      write(
        join(repoRoot, "server/src/routes/index.ts"),
        'import { createWorkspaceRoutes } from "./workspaces.js";\nexport { createWorkspaceRoutes };\n',
      );

      const violations = findServerLayerViolations(repoRoot);

      expect(violations).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            rule: "route-to-route-boundary",
            file: "server/src/routes/sessions.ts",
            target: "server/src/routes/workspaces.ts",
          }),
        ]),
      );
      expect(violations).not.toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            rule: "route-to-route-boundary",
            file: "server/src/routes/index.ts",
          }),
        ]),
      );
    } finally {
      rmSync(repoRoot, { recursive: true, force: true });
    }
  });

  it("flags mirror resume imports outside lifecycle/open policy modules", () => {
    const repoRoot = mkdtempSync(join(tmpdir(), "oppi-arch-mirror-resume-"));

    try {
      write(
        join(repoRoot, "server/src/random-open-helper.ts"),
        'import { canPromoteMirrorSession } from "./mirror-session-resume.js";\nexport { canPromoteMirrorSession };\n',
      );
      write(
        join(repoRoot, "server/src/session-lifecycle-service.ts"),
        'import { canPromoteMirrorSession } from "./mirror-session-resume.js";\nexport { canPromoteMirrorSession };\n',
      );
      write(
        join(repoRoot, "server/src/mirror-session-resume.ts"),
        "export function canPromoteMirrorSession(): boolean { return true; }\n",
      );

      const violations = findServerLayerViolations(repoRoot);

      expect(violations).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            rule: "mirror-resume-boundary",
            file: "server/src/random-open-helper.ts",
            target: "server/src/mirror-session-resume.ts",
          }),
        ]),
      );
      expect(violations).not.toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            rule: "mirror-resume-boundary",
            file: "server/src/session-lifecycle-service.ts",
          }),
        ]),
      );
    } finally {
      rmSync(repoRoot, { recursive: true, force: true });
    }
  });

  it("flags Pi TUI runtime ownership checks outside approved modules", () => {
    const repoRoot = mkdtempSync(join(tmpdir(), "oppi-arch-pi-tui-check-"));

    try {
      write(
        join(repoRoot, "server/src/random-session-helper.ts"),
        'export function isMirror(session: { runtime?: string }): boolean { return session.runtime === "pi-tui"; }\n',
      );
      write(
        join(repoRoot, "server/src/random-session-mutator.ts"),
        'export function markMirror(session: { runtime?: string }): void { session.runtime = "pi-tui"; }\n',
      );
      write(
        join(repoRoot, "server/src/session-lifecycle-service.ts"),
        'export function isMirror(session: { runtime?: string }): boolean { return session.runtime === "pi-tui"; }\n',
      );

      const violations = findServerLayerViolations(repoRoot);

      expect(violations).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            rule: "pi-tui-runtime-ownership-boundary",
            file: "server/src/random-session-helper.ts",
            target: 'runtime == "pi-tui" or runtime = "pi-tui"',
          }),
          expect.objectContaining({
            rule: "pi-tui-runtime-ownership-boundary",
            file: "server/src/random-session-mutator.ts",
            target: 'runtime == "pi-tui" or runtime = "pi-tui"',
          }),
        ]),
      );
      expect(violations).not.toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            rule: "pi-tui-runtime-ownership-boundary",
            file: "server/src/session-lifecycle-service.ts",
          }),
        ]),
      );
    } finally {
      rmSync(repoRoot, { recursive: true, force: true });
    }
  });

  it("flags concrete identity branches in generic extension-surface server files", () => {
    const repoRoot = mkdtempSync(join(tmpdir(), "oppi-arch-extension-server-"));

    try {
      write(
        join(repoRoot, "server/src/extension-ui-state.ts"),
        [
          "const hiddenStatusKeys = new Set(['local-only']);",
          "export function route(req: { method: string; statusKey?: string; widgetKey?: string }) {",
          "  if (req.method === 'setStatus') return 'protocol routing is okay';",
          "  if (hiddenStatusKeys.has(req.statusKey)) return 'bad';",
          "  if (req.widgetKey === 'summary') return 'bad';",
          "  return 'ok';",
          "}",
        ].join("\n"),
      );

      const violations = findServerLayerViolations(repoRoot);

      expect(violations).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            rule: "extension-surface-no-identity-branch",
            file: "server/src/extension-ui-state.ts",
          }),
        ]),
      );
    } finally {
      rmSync(repoRoot, { recursive: true, force: true });
    }
  });

  it("allows protocol method routing in generic extension-surface server files", () => {
    const repoRoot = mkdtempSync(join(tmpdir(), "oppi-arch-extension-method-"));

    try {
      write(
        join(repoRoot, "server/src/extension-ui-state.ts"),
        [
          "export function route(req: { method: string; statusKey?: string }) {",
          "  switch (req.method) {",
          "    case 'setStatus': return req.statusKey ? 'status' : 'none';",
          "    case 'setWidget': return 'widget';",
          "    default: return 'other';",
          "  }",
          "}",
        ].join("\n"),
      );

      const violations = findServerLayerViolations(repoRoot).filter(
        (violation) => violation.rule === "extension-surface-no-identity-branch",
      );

      expect(violations).toEqual([]);
    } finally {
      rmSync(repoRoot, { recursive: true, force: true });
    }
  });

  it("flags concrete key branches inside the mirror UI bridge proxy", () => {
    const repoRoot = mkdtempSync(join(tmpdir(), "oppi-arch-mirror-bridge-"));

    try {
      write(
        join(repoRoot, "pi-extensions/oppi-mirror/extensions/oppi-mirror.ts"),
        [
          "function installExtensionUIProxy(ctx: ExtensionContext): void {",
          "  const ui = ctx.ui;",
          "  ui.setWidget = (key: string, content: unknown) => {",
          "    if (key === 'local-only') return;",
          "    return content;",
          "  };",
          "}",
          "  function renderIndicator(ctx: ExtensionContext) { return ctx; }",
        ].join("\n"),
      );

      const violations = findServerLayerViolations(repoRoot);

      expect(violations).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            rule: "extension-surface-no-identity-branch",
            file: "pi-extensions/oppi-mirror/extensions/oppi-mirror.ts",
          }),
        ]),
      );
    } finally {
      rmSync(repoRoot, { recursive: true, force: true });
    }
  });

  it("ignores unrelated tool-renderer code in the mixed mirror file", () => {
    const repoRoot = mkdtempSync(join(tmpdir(), "oppi-arch-mirror-tool-renderer-"));

    try {
      write(
        join(repoRoot, "pi-extensions/oppi-mirror/extensions/oppi-mirror.ts"),
        [
          "const nativeToolNames = new Set(['read']);",
          "function renderTool(toolName: string) {",
          "  if (nativeToolNames.has(toolName)) return undefined;",
          "  return toolName;",
          "}",
          "function installExtensionUIProxy(ctx: ExtensionContext): void {",
          "  const ui = ctx.ui;",
          "  ui.setStatus = (key: string, text: string) => text;",
          "}",
          "  function renderIndicator(ctx: ExtensionContext) { return ctx; }",
        ].join("\n"),
      );

      const violations = findServerLayerViolations(repoRoot).filter(
        (violation) => violation.rule === "extension-surface-no-identity-branch",
      );

      expect(violations).toEqual([]);
    } finally {
      rmSync(repoRoot, { recursive: true, force: true });
    }
  });

  it("flags concrete identity branches in generic extension-surface Swift files", () => {
    const repoRoot = mkdtempSync(join(tmpdir(), "oppi-arch-extension-swift-"));

    try {
      write(
        join(repoRoot, "clients/apple/Oppi/Features/Chat/Support/ExtensionSurfacePanel.swift"),
        [
          "import SwiftUI",
          "func route(statusKey: String, widgetKey: String) -> String {",
          '  if statusKey == "local-only" { return "bad" }',
          "  switch widgetKey {",
          '  case "summary": return "bad"',
          '  default: return "ok"',
          "  }",
          "}",
        ].join("\n"),
      );

      const violations = findIosLayerViolations(repoRoot);

      expect(violations).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            rule: "extension-surface-no-identity-branch",
            file: "clients/apple/Oppi/Features/Chat/Support/ExtensionSurfacePanel.swift",
          }),
        ]),
      );
    } finally {
      rmSync(repoRoot, { recursive: true, force: true });
    }
  });
});
