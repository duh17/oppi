import { existsSync, readFileSync, readdirSync } from "node:fs";
import path from "node:path";

import ts from "typescript";

export const SERVER_ARCHITECTURE_GUIDE =
  "dev/architecture-server.md#server-boundary-rules-current-code";
export const IOS_ARCHITECTURE_GUIDE =
  "dev/architecture-client.md#client-boundary-rules-current-code";
export const MAC_ARCHITECTURE_GUIDE =
  "dev/architecture-client.md#client-boundary-rules-current-code";

const SERVER_COMPOSITION_ROOT = "server/src/server.ts";
const SERVER_ENTRY_FILE = "server/src/cli.ts";
const SERVER_TYPES_CONTRACT_FILE = "server/src/types.ts";
const SERVER_TYPES_CONTRACT_BARREL_PREFIX = "./types/";
const SERVER_SESSION_FACADE_FILE = "server/src/sessions.ts";
const SERVER_MIRROR_SESSION_RESUME_FILE = "server/src/mirror-session-resume.ts";
const SERVER_CLI_APP_STATE_API_FIRST_FILES = new Set([
  "server/src/cli/local-api-client.ts",
  "server/src/cli/resources.ts",
]);
const SERVER_CLI_APP_STATE_API_FIRST_PREFIXES = ["server/src/cli/commands/"];
const SERVER_CLI_APP_STATE_DB_IMPORT_TARGETS = new Set([
  "server/src/storage.ts",
  "server/src/sqlite-compat.ts",
]);

const SERVER_ROUTE_TO_ROUTE_ALLOWED_IMPORTERS = new Set(["server/src/routes/index.ts"]);
const SERVER_ROUTE_TO_ROUTE_ALLOWED_TARGETS = new Set([
  "server/src/routes/http.ts",
  "server/src/routes/server-stats.ts",
  "server/src/routes/session-files.ts",
  "server/src/routes/session-list-handlers.ts",
  "server/src/routes/session-trace-handlers.ts",
  "server/src/routes/theme-convert.ts",
  "server/src/routes/types.ts",
]);

const SERVER_MIRROR_RESUME_IMPORT_ALLOWED_FILES = new Set([
  "server/src/session-lifecycle-service.ts",
]);

const SERVER_PI_TUI_RUNTIME_CHECK_ALLOWED_FILES = new Set([
  "server/src/session-lifecycle-service.ts",
  "server/src/runtime-router.ts",
  "server/src/pi-tui-mirror-runtime.ts",
  "server/src/pi-tui-session-classification.ts",
  "server/src/mirror-session-resume.ts",
  "server/src/session-runtime-capabilities.ts",
]);

const APPLE_SHARED_CORE_ROOT = "clients/apple/OppiCore/";
const APPLE_SHARED_CORE_PLATFORM_ADAPTER_PREFIXES = [`${APPLE_SHARED_CORE_ROOT}PlatformAdapters/`];
const MAC_APP_ROOT = "clients/apple/OppiMac/";
const MAC_PROJECT_YML = "clients/apple/project.yml";
const MAC_FORBIDDEN_APP_IMPORTS = new Set(["UIKit"]);
const MAC_ALLOWED_SOURCE_ROOTS = new Set(["OppiMac", "OppiCore", "Shared"]);
const MAC_OPPI_TREE_ALLOWED_PATHS = new Set([
  "Oppi/Resources/Fonts",
  "Oppi/Core/AppIdentifiers.swift",
  "Oppi/Core/Extensions/Color+Theme.swift",
  "Oppi/Core/Theme/AppTheme.swift",
  "Oppi/Core/Theme/RemoteTheme.swift",
  "Oppi/Core/Theme/ThemeCatalog.swift",
  "Oppi/Core/Theme/ThemeStore.swift",
]);
const APPLE_SHARED_CORE_FORBIDDEN_IMPORTS = new Set([
  "UIKit",
  "AppKit",
  "SwiftUI",
  "ActivityKit",
  "UserNotifications",
  "Speech",
  "AVFoundation",
  "WebKit",
  "MetricKit",
]);

const IOS_RUNTIME_UI_FREE_FILES = [
  "clients/apple/OppiCore/Runtime/TimelineReducer.swift",
  "clients/apple/OppiCore/Runtime/DeltaCoalescer.swift",
];

const IOS_VIEW_LAYER_PATH_PREFIXES = [
  "clients/apple/Oppi/Core/Views/",
  "clients/apple/Oppi/Features/Chat/Timeline/",
];

const IOS_FORBIDDEN_VIEW_NETWORK_TYPES = ["APIClient", "WebSocketClient"];

const GENERIC_EXTENSION_SURFACE_IDENTITY_BRANCH_FULL_FILES = new Set([
  "clients/apple/Oppi/Features/Chat/Support/ExtensionSurfacePanel.swift",
  "clients/apple/OppiMac/Views/MacExtensionSurfacePanel.swift",
  "clients/apple/Oppi/Core/Networking/ServerConnection+MessageRouter.swift",
  "clients/apple/Oppi/Core/Networking/ServerConnection+AppEvents.swift",
  "clients/apple/OppiCore/Runtime/ExtensionSurfaceState.swift",
  "clients/apple/OppiCore/Models/ExtensionUIWireDecoding.swift",
  "clients/apple/OppiCore/Models/ServerMessage.swift",
  "server/src/app-event-stream.ts",
  "server/src/extension-ui-contract.ts",
  "server/src/extension-ui-state.ts",
  "server/src/live-activity.ts",
  "server/src/pi-tui-mirror-runtime.ts",
  "server/src/sdk-ui-bridge.ts",
  "server/src/session-attention.ts",
  "server/src/stream.ts",
]);

const GENERIC_EXTENSION_SURFACE_IDENTITY_BRANCH_RANGES = [
  {
    file: "pi-extensions/oppi-mirror/extensions/oppi-mirror.ts",
    startMarker: "function installExtensionUIProxy",
    endMarker: "  function renderIndicator",
  },
];

const IOS_COLD_LIST_PROJECTION_CONSUMER_PATH_PREFIXES = [
  "clients/apple/Oppi/Features/Workspaces/",
  "clients/apple/Oppi/Features/QuickSession/",
];

const IOS_ISOLATED_STORES = [
  { file: "clients/apple/Oppi/Core/Services/SessionStore.swift", typeName: "SessionStore" },
  { file: "clients/apple/Oppi/Core/Services/WorkspaceStore.swift", typeName: "WorkspaceStore" },
  {
    file: "clients/apple/OppiCore/Stores/AskRequestStore.swift",
    typeName: "AskRequestStore",
  },
  {
    file: "clients/apple/OppiCore/Stores/MessageQueueStore.swift",
    typeName: "MessageQueueStore",
  },
  {
    file: "clients/apple/OppiCore/Stores/ReviewCommentStore.swift",
    typeName: "ReviewCommentStore",
  },
  {
    file: "clients/apple/OppiCore/Stores/FileIndexStore.swift",
    typeName: "FileIndexStore",
  },
  {
    file: "clients/apple/OppiCore/Stores/GitStatusStore.swift",
    typeName: "GitStatusStore",
  },
];

export function normalizeRepoPath(filePath) {
  return filePath.split(path.sep).join("/");
}

function listFilesRecursively(dir, extension, files = []) {
  if (!existsSync(dir)) {
    return files;
  }

  const entries = readdirSync(dir, { withFileTypes: true }).sort((a, b) =>
    a.name.localeCompare(b.name),
  );

  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      listFilesRecursively(fullPath, extension, files);
      continue;
    }

    if (entry.isFile() && fullPath.endsWith(extension)) {
      files.push(fullPath);
    }
  }

  return files;
}

function readImportEntriesFromFile(filePath) {
  const source = readFileSync(filePath, "utf8");
  const sourceFile = ts.createSourceFile(filePath, source, ts.ScriptTarget.Latest, true);
  const imports = [];

  function pushImport(node, specifier) {
    const start = node.getStart(sourceFile);
    const { line, character } = sourceFile.getLineAndCharacterOfPosition(start);
    imports.push({
      specifier,
      line: line + 1,
      column: character + 1,
    });
  }

  function visit(node) {
    if ((ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) && node.moduleSpecifier) {
      if (ts.isStringLiteralLike(node.moduleSpecifier)) {
        pushImport(node.moduleSpecifier, node.moduleSpecifier.text);
      }
    }

    if (ts.isImportEqualsDeclaration(node) && ts.isExternalModuleReference(node.moduleReference)) {
      const expression = node.moduleReference.expression;
      if (expression && ts.isStringLiteralLike(expression)) {
        pushImport(expression, expression.text);
      }
    }

    if (
      ts.isCallExpression(node) &&
      node.expression.kind === ts.SyntaxKind.ImportKeyword &&
      node.arguments.length >= 1 &&
      ts.isStringLiteralLike(node.arguments[0])
    ) {
      pushImport(node.arguments[0], node.arguments[0].text);
    }

    ts.forEachChild(node, visit);
  }

  visit(sourceFile);

  return imports.sort((a, b) => {
    if (a.line !== b.line) {
      return a.line - b.line;
    }

    if (a.column !== b.column) {
      return a.column - b.column;
    }

    return a.specifier.localeCompare(b.specifier);
  });
}

export function readImportsFromFile(filePath) {
  return readImportEntriesFromFile(filePath).map((entry) => entry.specifier);
}

export function resolveRelativeModule(repoRoot, importerRelativePath, specifier) {
  if (!specifier.startsWith(".")) {
    return null;
  }

  const importerAbsolutePath = path.join(repoRoot, importerRelativePath);
  const rawResolved = path.resolve(path.dirname(importerAbsolutePath), specifier);

  const extension = path.extname(rawResolved);
  const candidates = [];

  if (extension.length > 0) {
    candidates.push(rawResolved);

    if ([".js", ".mjs", ".cjs"].includes(extension)) {
      candidates.push(rawResolved.slice(0, -extension.length) + ".ts");
      candidates.push(rawResolved.slice(0, -extension.length) + ".tsx");
      candidates.push(rawResolved.slice(0, -extension.length) + ".mts");
      candidates.push(rawResolved.slice(0, -extension.length) + ".cts");
    }
  } else {
    candidates.push(rawResolved);
    candidates.push(`${rawResolved}.ts`);
    candidates.push(`${rawResolved}.tsx`);
    candidates.push(`${rawResolved}.mts`);
    candidates.push(`${rawResolved}.cts`);
    candidates.push(`${rawResolved}.js`);
    candidates.push(`${rawResolved}.mjs`);
    candidates.push(path.join(rawResolved, "index.ts"));
    candidates.push(path.join(rawResolved, "index.tsx"));
    candidates.push(path.join(rawResolved, "index.js"));
  }

  for (const candidate of candidates) {
    if (!existsSync(candidate)) {
      continue;
    }

    return normalizeRepoPath(path.relative(repoRoot, candidate));
  }

  return normalizeRepoPath(path.relative(repoRoot, rawResolved));
}

function isServerSourceFile(filePath) {
  return filePath.startsWith("server/src/") && filePath.endsWith(".ts");
}

function isServerSessionRuntimeFile(filePath) {
  return (
    filePath === SERVER_SESSION_FACADE_FILE || /server\/src\/session-[^/]+\.ts$/.test(filePath)
  );
}

function isServerRouteFile(filePath) {
  return filePath.startsWith("server/src/routes/") && filePath.endsWith(".ts");
}

function isServerCliAppStateApiFirstFile(filePath) {
  return (
    SERVER_CLI_APP_STATE_API_FIRST_FILES.has(filePath) ||
    SERVER_CLI_APP_STATE_API_FIRST_PREFIXES.some((prefix) => filePath.startsWith(prefix))
  );
}

function isServerCliAppStateDbImportTarget(filePath) {
  return (
    SERVER_CLI_APP_STATE_DB_IMPORT_TARGETS.has(filePath) ||
    filePath.startsWith("server/src/storage/")
  );
}

function sortArchitectureViolations(violations) {
  return [...violations].sort((a, b) => {
    const aFile = a.file ?? a.importer ?? "";
    const bFile = b.file ?? b.importer ?? "";

    if (aFile !== bFile) {
      return aFile.localeCompare(bFile);
    }

    if ((a.line ?? 1) !== (b.line ?? 1)) {
      return (a.line ?? 1) - (b.line ?? 1);
    }

    if ((a.column ?? 1) !== (b.column ?? 1)) {
      return (a.column ?? 1) - (b.column ?? 1);
    }

    if (a.rule !== b.rule) {
      return a.rule.localeCompare(b.rule);
    }

    return (a.target ?? "").localeCompare(b.target ?? "");
  });
}

function makeServerViolation({ rule, importer, target, line, column, reason, remediation }) {
  return {
    rule,
    file: importer,
    importer,
    target,
    line,
    column,
    reason,
    remediation,
    guide: SERVER_ARCHITECTURE_GUIDE,
  };
}

export function findServerLayerViolations(repoRoot, files = undefined) {
  const candidateFiles = (
    files ??
    listFilesRecursively(path.join(repoRoot, "server", "src"), ".ts").map((absolutePath) =>
      normalizeRepoPath(path.relative(repoRoot, absolutePath)),
    )
  )
    .map(normalizeRepoPath)
    .filter(isServerSourceFile)
    .sort();

  const violations = [];

  for (const importer of candidateFiles) {
    const absolutePath = path.join(repoRoot, importer);
    if (!existsSync(absolutePath)) {
      continue;
    }

    if (importer.endsWith(".test.ts")) {
      violations.push(
        makeServerViolation({
          rule: "server-test-placement",
          importer,
          target: "server/tests/**",
          line: 1,
          column: 1,
          reason: "Server tests should not live under server/src.",
          remediation:
            "Move the test into server/tests/** and import production code from ../src/**.",
        }),
      );
      continue;
    }

    const rawSource = readFileSync(absolutePath, "utf8");
    const strippedSource = stripCommentsPreservingStrings(rawSource);
    const runtimeCheck = findFirstPiTuiRuntimeOwnershipCheck(strippedSource);
    if (runtimeCheck && !SERVER_PI_TUI_RUNTIME_CHECK_ALLOWED_FILES.has(importer)) {
      const location = lineAndColumnForIndex(strippedSource, runtimeCheck.index);
      violations.push(
        makeServerViolation({
          rule: "pi-tui-runtime-ownership-boundary",
          importer,
          target: 'runtime == "pi-tui" or runtime = "pi-tui"',
          line: location.line,
          column: location.column,
          reason: "Pi TUI ownership checks must stay inside runtime or session lifecycle modules.",
          remediation:
            "Return semantic capabilities or typed results from SessionLifecycleService instead of branching on session.runtime in this module.",
        }),
      );
    }

    const importEntries = readImportEntriesFromFile(absolutePath);

    if (importer === SERVER_TYPES_CONTRACT_FILE) {
      for (const entry of importEntries) {
        if (entry.specifier.startsWith(SERVER_TYPES_CONTRACT_BARREL_PREFIX)) {
          continue;
        }

        violations.push(
          makeServerViolation({
            rule: "types-protocol-leaf",
            importer,
            target: entry.specifier,
            line: entry.line,
            column: entry.column,
            reason: "types.ts is the stable protocol barrel and may only re-export type modules.",
            remediation:
              "Move shared type definitions into server/src/types/ and re-export them from server/src/types.ts.",
          }),
        );
      }
    }

    for (const entry of importEntries) {
      if (entry.specifier === "@earendil-works/pi-ai/compat") {
        violations.push(
          makeServerViolation({
            rule: "pi-ai-compat-boundary",
            importer,
            target: entry.specifier,
            line: entry.line,
            column: entry.column,
            reason: "Oppi server code must use provider-owned Pi model APIs.",
            remediation:
              "Use ModelRuntime for configured model/auth requests or @earendil-works/pi-ai/providers/all for static built-in catalog reads.",
          }),
        );
      }

      const target = resolveRelativeModule(repoRoot, importer, entry.specifier);
      if (target === null) {
        continue;
      }

      if (isServerCliAppStateApiFirstFile(importer) && isServerCliAppStateDbImportTarget(target)) {
        violations.push(
          makeServerViolation({
            rule: "cli-app-state-api-first",
            importer,
            target,
            line: entry.line,
            column: entry.column,
            reason:
              "CLI app-state commands must get Oppi state through the local HTTP API, not direct or transitive SQLite storage imports.",
            remediation:
              "Use the thin CLI connection config reader for local token/TLS settings and call local API helpers for app state.",
          }),
        );
      }

      if (
        target === SERVER_MIRROR_SESSION_RESUME_FILE &&
        !SERVER_MIRROR_RESUME_IMPORT_ALLOWED_FILES.has(importer)
      ) {
        violations.push(
          makeServerViolation({
            rule: "mirror-resume-boundary",
            importer,
            target,
            line: entry.line,
            column: entry.column,
            reason:
              "Mirror resume/promotion policy must be owned by the session lifecycle service.",
            remediation:
              "Call SessionLifecycleService open/resume methods instead of importing mirror-session-resume directly.",
          }),
        );
      }

      if (
        importer !== SERVER_COMPOSITION_ROOT &&
        importer !== SERVER_ENTRY_FILE &&
        target === SERVER_COMPOSITION_ROOT
      ) {
        violations.push(
          makeServerViolation({
            rule: "single-composition-root",
            importer,
            target,
            line: entry.line,
            column: entry.column,
            reason: "Only server/src/server.ts may act as the composition root.",
            remediation:
              "Inject dependencies from server.ts instead of importing server.ts from lower layers.",
          }),
        );
      }

      if (
        isServerRouteFile(importer) &&
        isServerRouteFile(target) &&
        !SERVER_ROUTE_TO_ROUTE_ALLOWED_IMPORTERS.has(importer) &&
        !SERVER_ROUTE_TO_ROUTE_ALLOWED_TARGETS.has(target)
      ) {
        violations.push(
          makeServerViolation({
            rule: "route-to-route-boundary",
            importer,
            target,
            line: entry.line,
            column: entry.column,
            reason: "Concrete route modules must not depend on each other.",
            remediation:
              "Move shared route-independent policy into server/src modules, or compose route handlers from routes/index.ts.",
          }),
        );
      }

      if (
        importer !== SERVER_COMPOSITION_ROOT &&
        !importer.startsWith("server/src/routes/") &&
        target.startsWith("server/src/routes/")
      ) {
        violations.push(
          makeServerViolation({
            rule: "route-boundary",
            importer,
            target,
            line: entry.line,
            column: entry.column,
            reason: "Core modules must not depend on route handlers.",
            remediation:
              "Route code should stay at the HTTP boundary. Move shared logic into non-route modules.",
          }),
        );
      }

      if (path.basename(importer).startsWith("session-") && target === SERVER_SESSION_FACADE_FILE) {
        violations.push(
          makeServerViolation({
            rule: "session-facade-direction",
            importer,
            target,
            line: entry.line,
            column: entry.column,
            reason: "session-* modules must not import the sessions.ts facade.",
            remediation:
              "Move shared orchestration into session coordinators or injected interfaces.",
          }),
        );
      }

      if (importer.startsWith("server/src/storage/")) {
        const importsRouteModule = target.startsWith("server/src/routes/");
        const importsStreamModule = target === "server/src/stream.ts";
        const importsSessionModule = isServerSessionRuntimeFile(target);

        if (importsRouteModule || importsStreamModule || importsSessionModule) {
          violations.push(
            makeServerViolation({
              rule: "storage-leaf-layer",
              importer,
              target,
              line: entry.line,
              column: entry.column,
              reason: "storage/* modules must remain infrastructure leaf modules.",
              remediation:
                "Move orchestration to higher layers and keep storage modules focused on persistence.",
            }),
          );
        }
      }
    }
  }

  const genericExtensionFiles = files
    ? files.map(normalizeRepoPath)
    : genericExtensionSurfaceIdentityBranchFiles({ swift: false });
  violations.push(
    ...findGenericExtensionSurfaceIdentityBranchViolations(
      repoRoot,
      genericExtensionFiles,
      (violation) =>
        makeServerViolation({
          ...violation,
          importer: violation.file,
          target: "extension identity literal",
        }),
    ),
  );

  return sortArchitectureViolations(violations);
}

function lineAndColumnForIndex(source, index) {
  let line = 1;
  let column = 1;

  const end = Math.max(0, Math.min(index, source.length));
  for (let cursor = 0; cursor < end; cursor += 1) {
    if (source[cursor] === "\n") {
      line += 1;
      column = 1;
      continue;
    }

    column += 1;
  }

  return { line, column };
}

function stripCommentsPreservingStrings(source) {
  let output = "";
  let index = 0;
  let state = "code";
  let quote = "";
  let blockCommentDepth = 0;

  while (index < source.length) {
    const char = source[index];
    const next = source[index + 1] ?? "";

    if (state === "line-comment") {
      if (char === "\n") {
        output += "\n";
        state = "code";
      } else {
        output += " ";
      }
      index += 1;
      continue;
    }

    if (state === "block-comment") {
      if (char === "/" && next === "*") {
        blockCommentDepth += 1;
        output += "  ";
        index += 2;
        continue;
      }

      if (char === "*" && next === "/") {
        blockCommentDepth -= 1;
        output += "  ";
        index += 2;
        if (blockCommentDepth === 0) {
          state = "code";
        }
        continue;
      }

      output += char === "\n" ? "\n" : " ";
      index += 1;
      continue;
    }

    if (state === "string") {
      output += char;
      index += 1;

      if (char === "\\") {
        if (index < source.length) {
          output += source[index];
          index += 1;
        }
        continue;
      }

      if (char === quote) {
        state = "code";
        quote = "";
      }
      continue;
    }

    if (char === "/" && next === "/") {
      output += "  ";
      index += 2;
      state = "line-comment";
      continue;
    }

    if (char === "/" && next === "*") {
      output += "  ";
      index += 2;
      blockCommentDepth = 1;
      state = "block-comment";
      continue;
    }

    if (char === '"' || char === "'" || char === "`") {
      output += char;
      index += 1;
      quote = char;
      state = "string";
      continue;
    }

    output += char;
    index += 1;
  }

  return output;
}

const IDENTITY_BRANCH_EXPRESSION = String.raw`(?:\b(?:\w+\.)*(?:tool|toolName|statusKey|widgetKey|extensionScopeId|extensionDisplayName)\b)`;
const KEY_ALIAS_BRANCH_EXPRESSION = String.raw`(?:\bkey\b)`;
const STRING_LITERAL_EXPRESSION = String.raw`(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')`;

const PI_TUI_RUNTIME_OWNERSHIP_PATTERNS = [
  /(?:\b[\w$.)\]]+\s*(?:\?\.|\.)\s*)?\bruntime\s*(?:={2,3}|!={1,2})\s*["']pi-tui["']/g,
  /["']pi-tui["']\s*(?:={2,3}|!={1,2})\s*(?:\b[\w$.)\]]+\s*(?:\?\.|\.)\s*)?\bruntime\b/g,
  /(?:\b[\w$.)\]]+\s*(?:\?\.|\.)\s*)?\bruntime\s*=\s*["']pi-tui["']/g,
];

function findFirstPiTuiRuntimeOwnershipCheck(source) {
  let firstMatch = null;
  for (const pattern of PI_TUI_RUNTIME_OWNERSHIP_PATTERNS) {
    pattern.lastIndex = 0;
    const match = pattern.exec(source);
    if (!match) {
      continue;
    }

    if (!firstMatch || match.index < firstMatch.index) {
      firstMatch = { text: match[0], index: match.index };
    }
  }

  return firstMatch;
}

const GENERIC_EXTENSION_IDENTITY_BRANCH_PATTERNS = [
  new RegExp(
    String.raw`${IDENTITY_BRANCH_EXPRESSION}\s*(?:={2,3}|!={1,2})\s*${STRING_LITERAL_EXPRESSION}`,
    "g",
  ),
  new RegExp(
    String.raw`${STRING_LITERAL_EXPRESSION}\s*(?:={2,3}|!={1,2})\s*${IDENTITY_BRANCH_EXPRESSION}`,
    "g",
  ),
  new RegExp(
    String.raw`${KEY_ALIAS_BRANCH_EXPRESSION}\s*(?:={2,3}|!={1,2})\s*${STRING_LITERAL_EXPRESSION}`,
    "g",
  ),
  new RegExp(
    String.raw`${STRING_LITERAL_EXPRESSION}\s*(?:={2,3}|!={1,2})\s*${KEY_ALIAS_BRANCH_EXPRESSION}`,
    "g",
  ),
  new RegExp(
    String.raw`switch\s+(?:\([^)]*${IDENTITY_BRANCH_EXPRESSION}[^)]*\)|${IDENTITY_BRANCH_EXPRESSION})[\s\S]{0,800}?\bcase\s+${STRING_LITERAL_EXPRESSION}`,
    "g",
  ),
  new RegExp(
    String.raw`switch\s+(?:\([^)]*${KEY_ALIAS_BRANCH_EXPRESSION}[^)]*\)|${KEY_ALIAS_BRANCH_EXPRESSION})[\s\S]{0,800}?\bcase\s+${STRING_LITERAL_EXPRESSION}`,
    "g",
  ),
  new RegExp(String.raw`\.(?:has|includes|contains)\(\s*${IDENTITY_BRANCH_EXPRESSION}\s*\)`, "g"),
];

function genericExtensionSurfaceIdentityBranchFiles({ swift }) {
  const files = new Set([
    ...GENERIC_EXTENSION_SURFACE_IDENTITY_BRANCH_FULL_FILES,
    ...GENERIC_EXTENSION_SURFACE_IDENTITY_BRANCH_RANGES.map((range) => range.file),
  ]);

  return [...files].filter((file) => file.endsWith(".swift") === swift).sort();
}

function sourceRangesForGenericExtensionSurfaceIdentityBranches(source, file) {
  const ranges = [];
  if (GENERIC_EXTENSION_SURFACE_IDENTITY_BRANCH_FULL_FILES.has(file)) {
    ranges.push({ source, offset: 0 });
  }

  for (const range of GENERIC_EXTENSION_SURFACE_IDENTITY_BRANCH_RANGES) {
    if (range.file !== file) {
      continue;
    }

    const start = source.indexOf(range.startMarker);
    if (start < 0) {
      continue;
    }

    const end = source.indexOf(range.endMarker, start + range.startMarker.length);
    ranges.push({
      source: source.slice(start, end < 0 ? undefined : end),
      offset: start,
    });
  }

  return ranges;
}

function findGenericExtensionSurfaceIdentityBranchViolations(repoRoot, files, makeViolation) {
  const violations = [];

  for (const rawFile of files) {
    const file = normalizeRepoPath(rawFile);
    if (
      !GENERIC_EXTENSION_SURFACE_IDENTITY_BRANCH_FULL_FILES.has(file) &&
      !GENERIC_EXTENSION_SURFACE_IDENTITY_BRANCH_RANGES.some((range) => range.file === file)
    ) {
      continue;
    }

    const absolutePath = path.join(repoRoot, file);
    if (!existsSync(absolutePath)) {
      continue;
    }

    const rawSource = readFileSync(absolutePath, "utf8");
    const strippedSource = stripCommentsPreservingStrings(rawSource);
    const sourceRanges = sourceRangesForGenericExtensionSurfaceIdentityBranches(
      strippedSource,
      file,
    );

    for (const range of sourceRanges) {
      let found = false;
      for (const pattern of GENERIC_EXTENSION_IDENTITY_BRANCH_PATTERNS) {
        pattern.lastIndex = 0;
        const match = pattern.exec(range.source);
        if (!match) {
          continue;
        }

        const location = lineAndColumnForIndex(strippedSource, range.offset + match.index);
        violations.push(
          makeViolation({
            rule: "extension-surface-no-identity-branch",
            file,
            line: location.line,
            column: location.column,
            reason:
              "Generic extension-surface code must not branch on concrete tool, extension, status, widget, or display names.",
            remediation:
              "Add semantic protocol metadata at the producer boundary and route on that metadata instead of hardcoded identities.",
          }),
        );
        found = true;
        break;
      }

      if (found) {
        break;
      }
    }
  }

  return violations;
}

export function stripSwiftCommentsAndStrings(source) {
  let output = "";
  let index = 0;
  let state = "code";
  let blockCommentDepth = 0;

  while (index < source.length) {
    const char = source[index];
    const next = source[index + 1] ?? "";
    const nextTwo = source[index + 2] ?? "";

    if (state === "line-comment") {
      if (char === "\n") {
        output += "\n";
        state = "code";
      } else {
        output += " ";
      }
      index += 1;
      continue;
    }

    if (state === "block-comment") {
      if (char === "/" && next === "*") {
        blockCommentDepth += 1;
        output += "  ";
        index += 2;
        continue;
      }

      if (char === "*" && next === "/") {
        blockCommentDepth -= 1;
        output += "  ";
        index += 2;
        if (blockCommentDepth === 0) {
          state = "code";
        }
        continue;
      }

      output += char === "\n" ? "\n" : " ";
      index += 1;
      continue;
    }

    if (state === "string") {
      if (char === "\\") {
        output += " ";
        index += 1;
        if (index < source.length) {
          output += source[index] === "\n" ? "\n" : " ";
          index += 1;
        }
        continue;
      }

      output += char === "\n" ? "\n" : " ";
      index += 1;

      if (char === '"') {
        state = "code";
      }
      continue;
    }

    if (state === "multiline-string") {
      if (char === '"' && next === '"' && nextTwo === '"') {
        output += "   ";
        index += 3;
        state = "code";
        continue;
      }

      output += char === "\n" ? "\n" : " ";
      index += 1;
      continue;
    }

    if (char === "/" && next === "/") {
      output += "  ";
      index += 2;
      state = "line-comment";
      continue;
    }

    if (char === "/" && next === "*") {
      output += "  ";
      index += 2;
      state = "block-comment";
      blockCommentDepth = 1;
      continue;
    }

    if (char === '"' && next === '"' && nextTwo === '"') {
      output += "   ";
      index += 3;
      state = "multiline-string";
      continue;
    }

    if (char === '"') {
      output += " ";
      index += 1;
      state = "string";
      continue;
    }

    output += char;
    index += 1;
  }

  return output;
}

function makeIosViolation({ rule, file, line, column, reason, remediation }) {
  return {
    rule,
    file,
    line,
    column,
    reason,
    remediation,
    guide: IOS_ARCHITECTURE_GUIDE,
  };
}

function isAppleClientSwiftFile(filePath) {
  return (
    (filePath.startsWith("clients/apple/Oppi/") || filePath.startsWith(APPLE_SHARED_CORE_ROOT)) &&
    filePath.endsWith(".swift")
  );
}

function collectIosSwiftFiles(repoRoot, files = undefined) {
  if (files) {
    return files.map(normalizeRepoPath).filter(isAppleClientSwiftFile).sort();
  }

  return [
    ...listFilesRecursively(path.join(repoRoot, "clients", "apple", "Oppi"), ".swift"),
    ...listFilesRecursively(path.join(repoRoot, "clients", "apple", "OppiCore"), ".swift"),
  ]
    .map((absolutePath) => normalizeRepoPath(path.relative(repoRoot, absolutePath)))
    .sort();
}

function readSwiftSource(repoRoot, relativePath) {
  const absolutePath = path.join(repoRoot, relativePath);
  if (!existsSync(absolutePath)) {
    return null;
  }

  const source = readFileSync(absolutePath, "utf8");
  return {
    source,
    stripped: stripSwiftCommentsAndStrings(source),
  };
}

function findFirstMatch(source, regex) {
  regex.lastIndex = 0;
  const match = regex.exec(source);
  if (!match) {
    return null;
  }

  return {
    text: match[0],
    index: match.index,
  };
}

export function findIosLayerViolations(repoRoot, files = undefined) {
  const candidateFiles = collectIosSwiftFiles(repoRoot, files);
  const candidateSet = new Set(candidateFiles);
  const violations = [];

  for (const file of candidateFiles) {
    if (!file.startsWith(APPLE_SHARED_CORE_ROOT)) {
      continue;
    }

    if (APPLE_SHARED_CORE_PLATFORM_ADAPTER_PREFIXES.some((prefix) => file.startsWith(prefix))) {
      continue;
    }

    const parsed = readSwiftSource(repoRoot, file);
    if (!parsed) {
      continue;
    }

    for (const framework of APPLE_SHARED_CORE_FORBIDDEN_IMPORTS) {
      const match = findFirstMatch(
        parsed.stripped,
        new RegExp(`^\\s*import\\s+${framework}\\b`, "m"),
      );
      if (!match) {
        continue;
      }

      const location = lineAndColumnForIndex(parsed.stripped, match.index);
      violations.push(
        makeIosViolation({
          rule: "apple-shared-core-platform-import",
          file,
          line: location.line,
          column: location.column,
          reason: `OppiCore non-adapter files must not import ${framework}.`,
          remediation:
            "Move UI, device, trust-delegate, notification, audio, or rendering code into OppiCore/PlatformAdapters/** or an app-specific adapter under Oppi/** or OppiMac/**.",
        }),
      );
    }
  }

  for (const runtimeFile of IOS_RUNTIME_UI_FREE_FILES) {
    if (!candidateSet.has(runtimeFile)) {
      continue;
    }

    const parsed = readSwiftSource(repoRoot, runtimeFile);
    if (!parsed) {
      continue;
    }

    const match = findFirstMatch(parsed.stripped, /^\s*import\s+UIKit\b/m);
    if (!match) {
      continue;
    }

    const location = lineAndColumnForIndex(parsed.stripped, match.index);
    violations.push(
      makeIosViolation({
        rule: "runtime-no-uikit",
        file: runtimeFile,
        line: location.line,
        column: location.column,
        reason: "Runtime reducer/coalescer files must remain UIKit-free.",
        remediation:
          "Move UIKit logic into Features/Chat/Timeline host views; keep runtime reducers on Foundation-only dependencies.",
      }),
    );
  }

  for (const file of candidateFiles) {
    if (!IOS_VIEW_LAYER_PATH_PREFIXES.some((prefix) => file.startsWith(prefix))) {
      continue;
    }

    const parsed = readSwiftSource(repoRoot, file);
    if (!parsed) {
      continue;
    }

    for (const forbiddenType of IOS_FORBIDDEN_VIEW_NETWORK_TYPES) {
      const match = findFirstMatch(parsed.stripped, new RegExp(`\\b${forbiddenType}\\b`));
      if (!match) {
        continue;
      }

      const location = lineAndColumnForIndex(parsed.stripped, match.index);
      violations.push(
        makeIosViolation({
          rule: "view-layer-network-boundary",
          file,
          line: location.line,
          column: location.column,
          reason: `View-layer files must not reference ${forbiddenType} directly.`,
          remediation:
            "Route network operations through stores/session managers and keep view files focused on rendering + user intent.",
        }),
      );
    }
  }

  for (const file of candidateFiles) {
    if (
      !IOS_COLD_LIST_PROJECTION_CONSUMER_PATH_PREFIXES.some((prefix) => file.startsWith(prefix))
    ) {
      continue;
    }

    const parsed = readSwiftSource(repoRoot, file);
    if (!parsed) {
      continue;
    }

    const match = findFirstMatch(parsed.stripped, /\bsessionStore\s*(?:[?!]\s*)?\.\s*sessions\b/);
    if (!match) {
      continue;
    }

    const location = lineAndColumnForIndex(parsed.stripped, match.index);
    violations.push(
      makeIosViolation({
        rule: "list-projection-consumer",
        file,
        line: location.line,
        column: location.column,
        reason: "Workspace and quick-session list views must not read full SessionStore.sessions.",
        remediation:
          "Read SessionStore.listProjectionSessions or listProjectionSessions(workspaceId:) so hot full-session changes do not rebuild list UI.",
      }),
    );
  }

  const isolatedStoreNames = IOS_ISOLATED_STORES.map((store) => store.typeName);
  for (const store of IOS_ISOLATED_STORES) {
    if (!candidateSet.has(store.file)) {
      continue;
    }

    const parsed = readSwiftSource(repoRoot, store.file);
    if (!parsed) {
      continue;
    }

    const disallowedStoreNames = isolatedStoreNames.filter((name) => name !== store.typeName);

    for (const disallowedStoreName of disallowedStoreNames) {
      const match = findFirstMatch(parsed.stripped, new RegExp(`\\b${disallowedStoreName}\\b`));
      if (!match) {
        continue;
      }

      const location = lineAndColumnForIndex(parsed.stripped, match.index);
      violations.push(
        makeIosViolation({
          rule: "store-isolation",
          file: store.file,
          line: location.line,
          column: location.column,
          reason: `${store.typeName} must not depend on ${disallowedStoreName}.`,
          remediation:
            "Keep stores isolated. Move shared behavior into helpers/services and coordinate cross-store workflows in ServerConnection.",
        }),
      );
    }
  }

  const genericExtensionFiles = files
    ? files.map(normalizeRepoPath)
    : genericExtensionSurfaceIdentityBranchFiles({ swift: true });
  violations.push(
    ...findGenericExtensionSurfaceIdentityBranchViolations(
      repoRoot,
      genericExtensionFiles,
      makeIosViolation,
    ),
  );

  return sortArchitectureViolations(violations);
}

function makeMacViolation({ rule, file, line, column, reason, remediation, target }) {
  return {
    rule,
    file,
    target,
    line,
    column,
    reason,
    remediation,
    guide: MAC_ARCHITECTURE_GUIDE,
  };
}

function isMacAppSwiftFile(filePath) {
  return filePath.startsWith(MAC_APP_ROOT) && filePath.endsWith(".swift");
}

function collectMacSwiftFiles(repoRoot, files = undefined) {
  if (files) {
    return files.map(normalizeRepoPath).filter(isMacAppSwiftFile).sort();
  }

  return listFilesRecursively(path.join(repoRoot, "clients", "apple", "OppiMac"), ".swift")
    .map((absolutePath) => normalizeRepoPath(path.relative(repoRoot, absolutePath)))
    .sort();
}

function isAllowedMacSourcePath(declaredPath) {
  if (!declaredPath || declaredPath.startsWith("/") || declaredPath.includes("..")) {
    return false;
  }

  for (const root of MAC_ALLOWED_SOURCE_ROOTS) {
    if (declaredPath === root || declaredPath.startsWith(`${root}/`)) {
      return true;
    }
  }

  for (const allowed of MAC_OPPI_TREE_ALLOWED_PATHS) {
    if (declaredPath === allowed || declaredPath.startsWith(`${allowed}/`)) {
      return true;
    }
  }

  return false;
}

function readOppiMacDeclaredSourcePaths(projectYml) {
  const paths = [];
  let inTarget = false;
  let inSources = false;

  for (const line of projectYml.split("\n")) {
    if (!inTarget) {
      if (/^  OppiMac:\s*$/.test(line)) {
        inTarget = true;
      }
      continue;
    }

    if (/^  \S/.test(line) && !line.startsWith("    ")) {
      break;
    }

    if (!inSources) {
      if (/^    sources:\s*$/.test(line)) {
        inSources = true;
      }
      continue;
    }

    if (/^    [A-Za-z]/.test(line)) {
      break;
    }

    const match = line.match(/^\s+- path:\s*(.+?)\s*$/) ?? line.match(/^\s+path:\s*(.+?)\s*$/);
    if (!match) {
      continue;
    }

    paths.push(match[1].replace(/^['"]|['"]$/g, ""));
  }

  return paths;
}

function collectAppleSharedCoreSwiftFiles(repoRoot, files = undefined) {
  if (files) {
    return files
      .map(normalizeRepoPath)
      .filter(
        (filePath) => filePath.startsWith(APPLE_SHARED_CORE_ROOT) && filePath.endsWith(".swift"),
      )
      .sort();
  }

  return listFilesRecursively(path.join(repoRoot, "clients", "apple", "OppiCore"), ".swift")
    .map((absolutePath) => normalizeRepoPath(path.relative(repoRoot, absolutePath)))
    .sort();
}

export function findMacLayerViolations(repoRoot, files = undefined) {
  const candidateFiles = collectMacSwiftFiles(repoRoot, files);
  const violations = [];

  for (const file of collectAppleSharedCoreSwiftFiles(repoRoot, files)) {
    if (APPLE_SHARED_CORE_PLATFORM_ADAPTER_PREFIXES.some((prefix) => file.startsWith(prefix))) {
      continue;
    }

    const parsed = readSwiftSource(repoRoot, file);
    if (!parsed) {
      continue;
    }

    for (const framework of APPLE_SHARED_CORE_FORBIDDEN_IMPORTS) {
      const match = findFirstMatch(
        parsed.stripped,
        new RegExp(`^\\s*import\\s+${framework}\\b`, "m"),
      );
      if (!match) {
        continue;
      }

      const location = lineAndColumnForIndex(parsed.stripped, match.index);
      violations.push(
        makeMacViolation({
          rule: "apple-shared-core-platform-import",
          file,
          line: location.line,
          column: location.column,
          reason: `OppiCore non-adapter files must not import ${framework}.`,
          remediation:
            "Move UI, device, trust-delegate, notification, audio, or rendering code into OppiCore/PlatformAdapters/** or an app-specific adapter under Oppi/** or OppiMac/**.",
        }),
      );
    }
  }

  for (const file of candidateFiles) {
    const parsed = readSwiftSource(repoRoot, file);
    if (!parsed) {
      continue;
    }

    for (const framework of MAC_FORBIDDEN_APP_IMPORTS) {
      const match = findFirstMatch(
        parsed.stripped,
        new RegExp(`^\\s*import\\s+${framework}\\b`, "m"),
      );
      if (!match) {
        continue;
      }

      const location = lineAndColumnForIndex(parsed.stripped, match.index);
      violations.push(
        makeMacViolation({
          rule: "mac-app-no-uikit",
          file,
          line: location.line,
          column: location.column,
          reason: `OppiMac files must not import ${framework}.`,
          remediation:
            "Keep Mac paint and adapters on AppKit/SwiftUI. Shared semantics belong in OppiCore without UIKit.",
        }),
      );
    }
  }

  const genericExtensionFiles = files ? files.map(normalizeRepoPath) : candidateFiles;
  violations.push(
    ...findGenericExtensionSurfaceIdentityBranchViolations(
      repoRoot,
      genericExtensionFiles,
      makeMacViolation,
    ),
  );

  const shouldCheckMembership = !files || files.map(normalizeRepoPath).includes(MAC_PROJECT_YML);
  const projectYmlPath = path.join(repoRoot, MAC_PROJECT_YML);
  if (shouldCheckMembership && existsSync(projectYmlPath)) {
    const projectYml = readFileSync(projectYmlPath, "utf8");
    const declaredPaths = readOppiMacDeclaredSourcePaths(projectYml);
    for (const declaredPath of declaredPaths) {
      if (isAllowedMacSourcePath(declaredPath)) {
        continue;
      }

      const location = lineAndColumnForIndex(projectYml, projectYml.indexOf(declaredPath));
      violations.push(
        makeMacViolation({
          rule: "mac-oppi-tree-membership",
          file: MAC_PROJECT_YML,
          target: declaredPath,
          line: location.line,
          column: location.column,
          reason: `OppiMac must not compile undeclared source roots (${declaredPath}).`,
          remediation:
            "Keep Mac sources under OppiMac/**, OppiCore/**, or Shared/**. Expand the established Mac Oppi/** allowlist only when that exact file is already a Mac adapter dependency.",
        }),
      );
    }
  }

  return sortArchitectureViolations(violations);
}
