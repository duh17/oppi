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
  NAME_LOCATION_RULES,
  NAME_TAG_FALLBACK,
  NAME_TAG_MAX_LENGTH,
  NAME_TAG_PUNCTUATION,
  TAG_DEFS,
  fieldSpec,
  type EventDef,
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

/**
 * `passesEmitPolicy` for one event: the catalog's emit rules as comparisons on
 * the struct's own typed members, so the drop decision needs no dictionary,
 * sanitizing, or string building. A rule whose field is absent does not apply;
 * a `where` tag that is absent does not match.
 */
function emitPolicyBody(def: EventDef, members: Map<string, TagMember>): string {
  const rules = def.emit ?? [];
  if (rules.length === 0) return "        true\n";
  let out = "";
  for (const rule of rules) {
    const raw = def.fields[rule.field];
    if (raw === undefined) throw new Error(`emit rule field ${rule.field} is not declared`);
    const spec = fieldSpec(raw);
    const name = identifier(rule.field);
    const optional = spec.optional === true;
    const conditions: string[] = [];
    if (optional) conditions.push(`let ${name}`);
    for (const [key, values] of Object.entries(rule.where ?? {})) {
      const tag = members.get(key);
      if (!tag) throw new Error(`emit rule tag ${key} is not declared`);
      const expr = tag.enumLike ? `${tag.name}${tag.optional ? "?" : ""}.rawValue` : tag.name;
      conditions.push(
        values.length === 1
          ? `${expr} == ${swiftString(values[0]!)}`
          : `[${values.map(swiftString).join(", ")}].contains(${tag.optional ? `${expr} ?? ""` : expr})`,
      );
    }
    const value = fieldSwiftType(spec.unit) === "Double" ? name : `Double(${name})`;
    const bounds: string[] = [];
    if (rule.min !== undefined) bounds.push(`${value} < ${swiftNumber(rule.min)}`);
    if (rule.max !== undefined) bounds.push(`${value} >= ${swiftNumber(rule.max)}`);
    conditions.push(bounds.length === 1 ? bounds[0]! : `${bounds.join(" || ")}`);
    out += `        if ${conditions.join(", ")} { return false }\n`;
  }
  return `${out}        return true\n`;
}

interface Member {
  name: string;
  type: string;
  optional: boolean;
}

/** A tag member as the emit policy reads it: enum-like members compare by raw value. */
interface TagMember {
  name: string;
  optional: boolean;
  enumLike: boolean;
}

function eventStruct(eventName: string): string {
  const def = EVENT_DEFS[eventName]!;
  const structName = upperCamel(eventName);
  const nested: string[] = [];
  const members: Member[] = [];
  const fieldLines: string[] = [];
  const tagLines: string[] = [];
  const tagMembers = new Map<string, TagMember>();

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
    tagMembers.set(key, { name, optional, enumLike: tagDef.kind !== "name" });
    if (optional) {
      tagLines.push(`        if let ${name} { values[${swiftString(key)}] = ${valueExpr(name)} }`);
    } else {
      tagLines.push(`        values[${swiftString(key)}] = ${valueExpr(name)}`);
    }
  }

  let out = docComment(def.description, "");
  out += `struct ${structName}: TelemetryEvent {\n`;
  out += `    static let name = ${swiftString(eventName)}\n`;
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
  out += `    }\n\n    var passesEmitPolicy: Bool {\n${emitPolicyBody(def, tagMembers)}    }\n\n    var tagValues: [String: String] {\n`;
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

const LOCATION_RULES_SWIFT = NAME_LOCATION_RULES.map(
  (rule) =>
    `        // ${rule.id}: ${rule.description}\n        try! NSRegularExpression(pattern: ${swiftString(rule.source)}, options: [${rule.ignoreCase ? ".caseInsensitive" : ""}]),`,
).join("\n");

/** Single-character `needs` of the location rules, as UTF-8 bytes (non-letters, so case never matters). */
const LOCATION_TRIGGER_BYTES = [
  ...new Set(NAME_LOCATION_RULES.flatMap((rule) => rule.needs).filter((need) => need.length === 1)),
]
  .map((need) => need.charCodeAt(0))
  .sort((a, b) => a - b)
  .map((code) => `0x${code.toString(16).toUpperCase().padStart(2, "0")}`)
  .join(", ");

/** Longer `needs`, lowercased, matched ignoring ASCII case. */
const LOCATION_TRIGGER_WORDS = [
  ...new Set(
    NAME_LOCATION_RULES.flatMap((rule) => rule.needs)
      .filter((need) => need.length > 1)
      .map((need) => need.toLowerCase()),
  ),
]
  .map((word) => swiftString(word))
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
    /// False when the catalog emit policy drops this event. Generated per event
    /// from the struct's typed members, so a dropped event costs no allocation.
    var passesEmitPolicy: Bool { get }
    var fieldValues: [String: Double] { get }
    var tagValues: [String: String] { get }
}

/// Open-but-bounded tag values (tool, model, screen, …) as the server stores
/// them: ASCII letters, digits, and \`${NAME_TAG_PUNCTUATION}\`, 1 to ${NAME_TAG_MAX_LENGTH} characters, and
/// nothing shaped like a URL, host, address, or path. Anything else becomes
/// \`${NAME_TAG_FALLBACK}\`. The server applies the same rules (\`looksLikeLocation\`).
enum TelemetryName {
    static let fallback = ${swiftString(NAME_TAG_FALLBACK)}

    static func sanitize(_ value: String) -> String {
        let bytes = value.utf8
        guard (1...${NAME_TAG_MAX_LENGTH}).contains(bytes.count), bytes.allSatisfy(isAllowed) else { return fallback }
        return looksLikeLocation(value) ? fallback : value
    }

    private static func isAllowed(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, ${NAME_PUNCTUATION_BYTES}:
            true
        default:
            false
        }
    }

    /// A value an endpoint, address, or filesystem path would produce. The rules are
    /// the catalog's \`NAME_LOCATION_RULES\`, the same data the server applies. The app
    /// has no route templates, so a leading \`/\` is a path here.
    static func looksLikeLocation(_ value: String) -> Bool {
        guard mayLookLikeLocation(value) else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return locationRules.contains { $0.firstMatch(in: value, range: range) != nil }
    }

    /// The rules' \`needs\` prefilter: every rule needs one of these characters or
    /// words to match, so a value with none (\`bash\`, \`user_native\`) skips the
    /// regexes. A pure optimization: the shared fixture and a fuzz sweep check
    /// the server's identical prefilter against every rule.
    private static func mayLookLikeLocation(_ value: String) -> Bool {
        if value.utf8.contains(where: { triggerBytes.contains($0) }) { return true }
        return triggerWords.contains { containsIgnoringASCIICase(value, word: $0) }
    }

    private static let triggerBytes: Set<UInt8> = [${LOCATION_TRIGGER_BYTES}]
    private static let triggerWords: [[UInt8]] = [${LOCATION_TRIGGER_WORDS}].map { Array($0.utf8) }

    private static func containsIgnoringASCIICase(_ value: String, word: [UInt8]) -> Bool {
        var matched = 0
        for var byte in value.utf8 {
            if (0x41...0x5A).contains(byte) { byte += 0x20 }
            if byte == word[matched] {
                matched += 1
                if matched == word.count { return true }
            } else {
                matched = byte == word[0] ? 1 : 0
            }
        }
        return false
    }

    private static let locationRules: [NSRegularExpression] = [
${LOCATION_RULES_SWIFT}
    ]
}

/// One event in a \`POST /telemetry/events\` upload.
struct TelemetryEventPayload: Encodable, Sendable {
    let ts: Int64
    let name: String
    let fields: [String: Double]
    let tags: [String: String]?
    let sessionId: String?
    let workspaceId: String?

    /// \`fields\` is the event's \`fieldValues\` when the caller already computed them.
    init(
        _ event: some TelemetryEvent,
        fields: [String: Double]? = nil,
        ts: Int64,
        sessionId: String? = nil,
        workspaceId: String? = nil
    ) {
        self.ts = ts
        name = type(of: event).name
        self.fields = fields ?? event.fieldValues
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
