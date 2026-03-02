import { existsSync, readFileSync, readdirSync } from "node:fs";
import path from "node:path";

import ts from "typescript";

export const SERVER_ARCHITECTURE_GUIDE =
  "ARCHITECTURE.md#dependency-direction-rules-current-code";
export const IOS_ARCHITECTURE_GUIDE = "ARCHITECTURE.md#ios-layers";

const SERVER_COMPOSITION_ROOT = "server/src/server.ts";
const SERVER_ENTRY_FILE = "server/src/cli.ts";
const SERVER_TYPES_CONTRACT_FILE = "server/src/types.ts";
const SERVER_SESSION_FACADE_FILE = "server/src/sessions.ts";
const SERVER_GATE_FILE = "server/src/gate.ts";
const SERVER_POLICY_FILE = "server/src/policy.ts";

const IOS_RUNTIME_UI_FREE_FILES = [
  "ios/Oppi/Core/Runtime/TimelineReducer.swift",
  "ios/Oppi/Core/Runtime/DeltaCoalescer.swift",
];

const IOS_VIEW_LAYER_PATH_PREFIXES = [
  "ios/Oppi/Core/Views/",
  "ios/Oppi/Features/Chat/Timeline/",
];

const IOS_FORBIDDEN_VIEW_NETWORK_TYPES = ["APIClient", "WebSocketClient"];

const IOS_ISOLATED_STORES = [
  { file: "ios/Oppi/Core/Services/SessionStore.swift", typeName: "SessionStore" },
  { file: "ios/Oppi/Core/Services/WorkspaceStore.swift", typeName: "WorkspaceStore" },
  { file: "ios/Oppi/Core/Services/PermissionStore.swift", typeName: "PermissionStore" },
  { file: "ios/Oppi/Core/Services/MessageQueueStore.swift", typeName: "MessageQueueStore" },
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

function makeServerViolation({
  rule,
  importer,
  target,
  line,
  column,
  reason,
  remediation,
}) {
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
  const candidateFiles = (files ??
    listFilesRecursively(path.join(repoRoot, "server", "src"), ".ts").map((absolutePath) =>
      normalizeRepoPath(path.relative(repoRoot, absolutePath)),
    ))
    .map(normalizeRepoPath)
    .filter(isServerSourceFile)
    .sort();

  const violations = [];

  for (const importer of candidateFiles) {
    const absolutePath = path.join(repoRoot, importer);
    if (!existsSync(absolutePath)) {
      continue;
    }

    const importEntries = readImportEntriesFromFile(absolutePath);

    if (importer === SERVER_TYPES_CONTRACT_FILE) {
      for (const entry of importEntries) {
        violations.push(
          makeServerViolation({
            rule: "types-protocol-leaf",
            importer,
            target: entry.specifier,
            line: entry.line,
            column: entry.column,
            reason: "types.ts is the protocol boundary and must remain import-free.",
            remediation:
              "Move shared type definitions into server/src/types.ts and import from types.ts instead.",
          }),
        );
      }
    }

    for (const entry of importEntries) {
      const target = resolveRelativeModule(repoRoot, importer, entry.specifier);
      if (target === null) {
        continue;
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

      if (importer === SERVER_POLICY_FILE && target === SERVER_GATE_FILE) {
        violations.push(
          makeServerViolation({
            rule: "policy-flow-one-way",
            importer,
            target,
            line: entry.line,
            column: entry.column,
            reason: "policy.ts must not import gate.ts (policy flow is one-way).",
            remediation:
              "Keep policy evaluation independent; gate.ts may depend on policy.ts, not the reverse.",
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

      if (importer === SERVER_GATE_FILE && isServerSessionRuntimeFile(target)) {
        violations.push(
          makeServerViolation({
            rule: "gate-runtime-boundary",
            importer,
            target,
            line: entry.line,
            column: entry.column,
            reason: "gate.ts must not depend on session runtime modules.",
            remediation:
              "Keep gate.ts in the policy/permission layer; coordinate session lifecycle from sessions.ts or server.ts.",
          }),
        );
      }
    }
  }

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

function collectIosSwiftFiles(repoRoot, files = undefined) {
  if (files) {
    return files
      .map(normalizeRepoPath)
      .filter((filePath) => filePath.startsWith("ios/Oppi/") && filePath.endsWith(".swift"))
      .sort();
  }

  return listFilesRecursively(path.join(repoRoot, "ios", "Oppi"), ".swift")
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

  return sortArchitectureViolations(violations);
}
