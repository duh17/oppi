#!/usr/bin/env bun

/**
 * Generate the Swift side of the telemetry catalog.
 *
 *   bun server/scripts/generate-telemetry-catalog.ts          # write the file
 *   bun server/scripts/generate-telemetry-catalog.ts --check  # exit 1 when stale
 *
 * Output: clients/apple/Oppi/Core/Telemetry/TelemetryCatalog.generated.swift,
 * one struct per `app.*` event with typed fields and tag enums, the emit
 * policy, bucketing helpers, `name`-tag sanitizing, and the upload wire types.
 * Never edit the output by hand.
 */

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  EVENT_DEFS,
  NAME_TAG_FALLBACK,
  NAME_TAG_MAX_LENGTH,
  NAME_TAG_PUNCTUATION,
  TAG_DEFS,
  fieldSpec,
  type EmitRule,
  type FieldUnit,
  type TagDef,
} from "../src/telemetry/catalog.ts";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
export const GENERATED_SWIFT_PATH = join(
  repoRoot,
  "clients/apple/Oppi/Core/Telemetry/TelemetryCatalog.generated.swift",
);

const SWIFT_KEYWORDS = new Set([
  "associatedtype",
  "break",
  "case",
  "catch",
  "class",
  "continue",
  "default",
  "defer",
  "deinit",
  "do",
  "else",
  "enum",
  "extension",
  "fallthrough",
  "false",
  "for",
  "func",
  "guard",
  "if",
  "import",
  "in",
  "init",
  "inout",
  "internal",
  "is",
  "let",
  "nil",
  "operator",
  "private",
  "protocol",
  "public",
  "repeat",
  "return",
  "self",
  "static",
  "struct",
  "subscript",
  "super",
  "switch",
  "throw",
  "true",
  "try",
  "typealias",
  "var",
  "where",
  "while",
]);

function words(value: string): string[] {
  return value.split(/[^A-Za-z0-9]+/).filter(Boolean);
}

function upperCamel(value: string): string {
  return words(value)
    .map((word) => word[0]!.toUpperCase() + word.slice(1))
    .join("");
}

function lowerCamel(value: string): string {
  const upper = upperCamel(value);
  return upper[0]!.toLowerCase() + upper.slice(1);
}

/** A Swift identifier for a catalog key or value; the check fails on names Swift reserves. */
function identifier(value: string): string {
  const name = lowerCamel(value);
  if (!/^[a-z]/.test(name)) throw new Error(`"${value}" does not start with a letter`);
  if (SWIFT_KEYWORDS.has(name)) throw new Error(`"${value}" is a Swift keyword`);
  return name;
}

function swiftString(value: string): string {
  return JSON.stringify(value);
}

function swiftNumber(value: number): string {
  return String(value);
}

function docComment(text: string, indent: string): string {
  return `${indent}/// ${text}\n`;
}

function fieldSwiftType(unit: FieldUnit): string {
  switch (unit) {
    case "bool":
      return "Bool";
    case "count":
    case "bytes":
    case "usd_micros":
      return "Int";
    case "ms":
    case "mb":
    case "pct":
    case "ratio":
      return "Double";
  }
}

function fieldAsDouble(unit: FieldUnit, expr: string): string {
  switch (fieldSwiftType(unit)) {
    case "Bool":
      return `${expr} ? 1 : 0`;
    case "Int":
      return `Double(${expr})`;
    default:
      return expr;
  }
}

function enumBody(values: readonly string[], indent: string): string {
  return values
    .map((value) => {
      const name = identifier(value);
      return name === value
        ? `${indent}case ${name}\n`
        : `${indent}case ${name} = ${swiftString(value)}\n`;
    })
    .join("");
}

function tagEnumName(key: string): string {
  return upperCamel(key);
}

function globalTagEnum(key: string, def: TagDef): string {
  if (def.kind === "name") return "";
  const name = tagEnumName(key);
  let out = docComment(def.description, "    ");
  out += `    enum ${name}: String, Sendable, CaseIterable {\n`;
  if (def.kind === "enum") {
    out += enumBody(def.values, "        ");
  } else {
    out += enumBody(
      def.buckets.map((bucket) => bucket.name),
      "        ",
    );
    const label = def.source;
    const type = fieldSwiftType(def.source);
    out += `\n        /// The bucket for a measured value; edges are the server's.\n`;
    out += `        init(${label}: ${type}) {\n`;
    def.buckets.forEach((bucket, index) => {
      const keyword = index === 0 ? "if" : "} else if";
      if (bucket.below !== undefined) {
        out += `            ${keyword} ${label} < ${swiftNumber(bucket.below)} {\n`;
        out += `                self = .${identifier(bucket.name)}\n`;
      } else {
        out += `            } else {\n                self = .${identifier(bucket.name)}\n`;
      }
    });
    out += `            }\n        }\n`;
  }
  out += `    }\n`;
  return out;
}

function emitRuleLiteral(rule: EmitRule): string {
  const where = rule.where
    ? `[${Object.entries(rule.where)
        .map(([key, values]) => `${swiftString(key)}: [${values.map(swiftString).join(", ")}]`)
        .join(", ")}]`
    : "[:]";
  const min = rule.min === undefined ? "nil" : swiftNumber(rule.min);
  const max = rule.max === undefined ? "nil" : swiftNumber(rule.max);
  return `TelemetryEmitRule(field: ${swiftString(rule.field)}, min: ${min}, max: ${max}, matching: ${where})`;
}

interface Member {
  name: string;
  type: string;
  optional: boolean;
}

function eventStruct(eventName: string): string {
  const def = EVENT_DEFS[eventName]!;
  const structName = upperCamel(eventName);
  const nested: string[] = [];
  const members: Member[] = [];
  const fieldLines: string[] = [];
  const tagLines: string[] = [];

  for (const [key, raw] of Object.entries(def.fields)) {
    const spec = fieldSpec(raw);
    const name = identifier(key);
    const type = fieldSwiftType(spec.unit);
    members.push({ name, type, optional: spec.optional === true });
    if (spec.optional) {
      fieldLines.push(
        `        if let ${name} { values[${swiftString(key)}] = ${fieldAsDouble(spec.unit, name)} }`,
      );
    } else {
      fieldLines.push(`        values[${swiftString(key)}] = ${fieldAsDouble(spec.unit, name)}`);
    }
  }

  for (const [key, use] of Object.entries(def.tags ?? {})) {
    const tagDef = TAG_DEFS[key]!;
    const name = identifier(key);
    let type: string;
    let valueExpr: (expr: string) => string;
    if (tagDef.kind === "name") {
      type = "String";
      valueExpr = (expr) => `TelemetryName.sanitize(${expr})`;
    } else if (tagDef.kind === "enum" && use.values) {
      type = tagEnumName(key);
      nested.push(
        `    enum ${type}: String, Sendable, CaseIterable {\n${enumBody(use.values, "        ")}    }\n`,
      );
      valueExpr = (expr) => `${expr}.rawValue`;
    } else {
      type = `TelemetryTag.${tagEnumName(key)}`;
      valueExpr = (expr) => `${expr}.rawValue`;
    }
    const optional = use.required !== true;
    members.push({ name, type, optional });
    if (optional) {
      tagLines.push(`        if let ${name} { values[${swiftString(key)}] = ${valueExpr(name)} }`);
    } else {
      tagLines.push(`        values[${swiftString(key)}] = ${valueExpr(name)}`);
    }
  }

  let out = docComment(def.description, "");
  out += `struct ${structName}: TelemetryEvent {\n`;
  out += `    static let name = ${swiftString(eventName)}\n`;
  const rules = def.emit ?? [];
  out +=
    rules.length === 0
      ? `    static let emitRules: [TelemetryEmitRule] = []\n`
      : `    static let emitRules: [TelemetryEmitRule] = [\n${rules.map((rule) => `        ${emitRuleLiteral(rule)},\n`).join("")}    ]\n`;
  if (nested.length > 0) out += `\n${nested.join("\n")}`;
  if (members.length > 0) {
    out += "\n";
    for (const member of members) {
      out += `    let ${member.name}: ${member.type}${member.optional ? "?" : ""}\n`;
    }
    const params = members
      .map((member) =>
        member.optional
          ? `${member.name}: ${member.type}? = nil`
          : `${member.name}: ${member.type}`,
      )
      .join(",\n        ");
    out += `\n    init(\n        ${params}\n    ) {\n`;
    for (const member of members) {
      out += `        self.${member.name} = ${member.name}\n`;
    }
    out += `    }\n`;
  } else {
    out += `\n    init() {}\n`;
  }

  out += `\n    var fieldValues: [String: Double] {\n`;
  if (fieldLines.length === 0) {
    out += `        [:]\n`;
  } else {
    out += `        var values: [String: Double] = [:]\n${fieldLines.join("\n")}\n        return values\n`;
  }
  out += `    }\n\n    var tagValues: [String: String] {\n`;
  if (tagLines.length === 0) {
    out += `        [:]\n`;
  } else {
    out += `        var values: [String: String] = [:]\n${tagLines.join("\n")}\n        return values\n`;
  }
  out += `    }\n}\n`;
  return out;
}

const NAME_PUNCTUATION_BYTES = [...NAME_TAG_PUNCTUATION]
  .map((char) => char.charCodeAt(0))
  .sort((a, b) => a - b)
  .map((code) => `0x${code.toString(16).toUpperCase().padStart(2, "0")}`)
  .join(", ");

const PRELUDE = `// Generated by server/scripts/generate-telemetry-catalog.ts from
// server/src/telemetry/catalog.ts. Do not edit. After changing the catalog run
// \`bun server/scripts/generate-telemetry-catalog.ts\`; \`npm run check\` fails
// while this file is stale.

import Foundation

// MARK: - Event protocol and wire types

/// One catalog event the app records. \`fieldValues\` and \`tagValues\` are the
/// wire \`fields\` and \`tags\`; the server validates both against the catalog.
protocol TelemetryEvent: Sendable {
    static var name: String { get }
    /// Bounds outside which the event is not recorded. Ingest applies them too.
    static var emitRules: [TelemetryEmitRule] { get }
    var fieldValues: [String: Double] { get }
    var tagValues: [String: String] { get }
}

extension TelemetryEvent {
    /// False when the catalog emit policy drops this event.
    var passesEmitPolicy: Bool {
        TelemetryEmitRule.allows(Self.emitRules, fields: fieldValues, tags: tagValues)
    }
}

/// Drop the event when \`field\` is present and outside \`[min, max)\`. A rule
/// applies only when every \`matching\` tag has one of the listed values.
struct TelemetryEmitRule: Sendable {
    let field: String
    let min: Double?
    let max: Double?
    let matching: [String: [String]]

    static func allows(
        _ rules: [Self],
        fields: [String: Double],
        tags: [String: String]
    ) -> Bool {
        for rule in rules {
            guard let value = fields[rule.field] else { continue }
            let applies = rule.matching.allSatisfy { key, values in
                tags[key].map(values.contains) ?? false
            }
            guard applies else { continue }
            if let min = rule.min, value < min { return false }
            if let max = rule.max, value >= max { return false }
        }
        return true
    }
}

/// Open-but-bounded tag values (tool, model, screen, …) as the server stores
/// them: ASCII letters, digits, and \`${NAME_TAG_PUNCTUATION}\`, 1 to ${NAME_TAG_MAX_LENGTH} characters;
/// anything else becomes \`${NAME_TAG_FALLBACK}\`.
enum TelemetryName {
    static let fallback = ${swiftString(NAME_TAG_FALLBACK)}

    static func sanitize(_ value: String) -> String {
        let bytes = value.utf8
        guard (1...${NAME_TAG_MAX_LENGTH}).contains(bytes.count), bytes.allSatisfy(isAllowed) else { return fallback }
        return value
    }

    private static func isAllowed(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, ${NAME_PUNCTUATION_BYTES}:
            true
        default:
            false
        }
    }
}

/// One event in a \`POST /telemetry/events\` upload.
struct TelemetryEventPayload: Encodable, Sendable {
    let ts: Int64
    let name: String
    let fields: [String: Double]
    let tags: [String: String]?
    let sessionId: String?
    let workspaceId: String?

    init(_ event: some TelemetryEvent, ts: Int64, sessionId: String? = nil, workspaceId: String? = nil) {
        self.ts = ts
        name = type(of: event).name
        fields = event.fieldValues
        let tagValues = event.tagValues
        tags = tagValues.isEmpty ? nil : tagValues
        self.sessionId = sessionId
        self.workspaceId = workspaceId
    }
}

/// Who sent an upload. Shared by the events, client-log, and MetricKit uploads.
/// \`deviceModel\` is the hardware identifier (\`iPhone17,1\`).
struct TelemetryClientInfo: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case ios
        case mac
    }

    let kind: Kind
    let appVersion: String?
    let buildNumber: String?
    let gitCommit: String?
    let osVersion: String?
    let deviceModel: String?
    let appInstanceId: String?
    let bootId: String?
}

/// Body of \`POST /telemetry/events\`.
struct TelemetryEventUploadRequest: Encodable, Sendable {
    let generatedAt: Int64
    let client: TelemetryClientInfo
    let events: [TelemetryEventPayload]
}

/// Response of \`POST /telemetry/events\`. \`dropped\` counts events the server
/// refused, by reason; retrying them cannot succeed.
struct TelemetryEventUploadResponse: Decodable, Sendable {
    let ok: Bool
    let accepted: Int
    let dropped: [String: Int]
}
`;

export function generateSwift(): string {
  let out = PRELUDE;
  out += `\n// MARK: - Tag vocabulary\n\n/// Shared tag enums. Events that narrow a tag declare their own nested enum.\nenum TelemetryTag {\n`;
  const tagEnums = Object.entries(TAG_DEFS)
    .map(([key, def]) => globalTagEnum(key, def))
    .filter(Boolean);
  out += tagEnums.join("\n");
  out += `}\n\n// MARK: - App events\n`;
  for (const name of Object.keys(EVENT_DEFS).filter((event) => event.startsWith("app."))) {
    out += `\n${eventStruct(name)}`;
  }
  return out;
}

function main(): void {
  const check = process.argv.includes("--check");
  const generated = generateSwift();
  const displayPath = relative(process.cwd(), GENERATED_SWIFT_PATH);
  if (check) {
    let current = "";
    try {
      current = readFileSync(GENERATED_SWIFT_PATH, "utf8");
    } catch {
      // Missing counts as stale.
    }
    if (current !== generated) {
      console.error(
        `${displayPath} is stale. Run: bun server/scripts/generate-telemetry-catalog.ts`,
      );
      process.exit(1);
    }
    return;
  }
  writeFileSync(GENERATED_SWIFT_PATH, generated, "utf8");
  console.log(`wrote ${displayPath}`);
}

if (import.meta.main) {
  main();
}
