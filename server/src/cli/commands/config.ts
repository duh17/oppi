import * as c from "../../ansi.js";
import { redactCredentialString, redactCredentialValue } from "../../credential-redaction.js";
import type { ServerConfig } from "../../types.js";
import type { CliConfigCommandStorage } from "../connection-config.js";
import {
  captureHumanCliOutput,
  setCapturedCliExitCode,
  writeHumanLine,
  writeHumanLineRaw,
  writeJsonEnvelope,
} from "../output.js";

type ConfigValueType = "string" | "number" | "boolean" | "json";

type SettableConfigPath = {
  type: ConfigValueType;
  desc: string;
};

export const SETTABLE_CONFIG_KEYS: Record<string, SettableConfigPath> = {
  port: { type: "number", desc: "Server port" },
  host: { type: "string", desc: "Bind address" },
  maxSessionsGlobal: { type: "number", desc: "Max concurrent sessions" },
  maxSessionsPerWorkspace: { type: "number", desc: "Max sessions per workspace" },
  sessionIdleTimeoutMs: { type: "number", desc: "Session idle timeout (ms)" },
  workspaceIdleTimeoutMs: { type: "number", desc: "Workspace idle timeout (ms)" },
  runtimePathEntries: { type: "json", desc: "Runtime PATH entries JSON array" },
  runtimeEnv: { type: "json", desc: "Runtime env JSON object" },
  oppiDocsPrompt: { type: "json", desc: "Oppi docs prompt config JSON object" },
  "oppiDocsPrompt.enabled": {
    type: "boolean",
    desc: "Append packaged Oppi docs hint to Oppi sessions",
  },
  oppiCliPrompt: { type: "json", desc: "Oppi CLI prompt experiment JSON object" },
  "oppiCliPrompt.enabled": {
    type: "boolean",
    desc: "Append a concise Oppi CLI management hint to Oppi sessions",
  },
  tls: { type: "json", desc: "TLS config JSON object" },
  "tls.mode": { type: "string", desc: "TLS mode" },
  "tls.certPath": { type: "string", desc: "Manual TLS certificate path" },
  "tls.keyPath": { type: "string", desc: "Manual TLS private key path" },
  "tls.caPath": { type: "string", desc: "Self-signed CA certificate path" },
  "tls.allowInsecureNetworkHttp": {
    type: "boolean",
    desc: "Allow plain HTTP on non-loopback interfaces",
  },
  autoTitle: { type: "json", desc: "Auto-title config JSON object" },
  "autoTitle.enabled": { type: "boolean", desc: "Enable automatic session titles" },
  "autoTitle.model": { type: "string", desc: "Auto-title model" },
  asr: { type: "json", desc: "ASR config JSON object" },
  "asr.sttEndpoint": { type: "string", desc: "STT backend base URL" },
  images: { type: "json", desc: "Image attachment preprocessing config JSON object" },
  "images.autoResize": { type: "boolean", desc: "Resize large image attachments before upload" },
  uploadStore: { type: "json", desc: "Upload store config JSON object" },
  "uploadStore.mode": { type: "string", desc: "Upload store mode" },
  "uploadStore.path": { type: "string", desc: "Upload store path" },
  "uploadStore.maxFileBytes": { type: "number", desc: "Max attachment file size" },
  "uploadStore.maxTurnBytes": { type: "number", desc: "Max attachment bytes per turn" },
  "uploadStore.unusedTtlMs": { type: "number", desc: "Unused upload TTL" },
  "uploadStore.retainedTtlMs": { type: "number", desc: "Retained upload TTL" },
  "uploadStore.allowedMimeTypes": { type: "json", desc: "Allowed MIME types JSON array" },
  extensions: {
    type: "json",
    desc: "Extension config JSON object",
  },
  "extensions.voice": { type: "json", desc: "Voice extension config JSON object" },
  "extensions.voice.defaultVoiceId": { type: "string", desc: "Default saved voice ID" },
};

export function cmdConfig(
  storage: CliConfigCommandStorage,
  action: string | undefined,
  positional: string[],
  flags: Record<string, string>,
): void {
  const mode = action || "show";
  const jsonOutput = flags.json === "true";

  try {
    if (mode === "get") {
      const key = positional[0];
      if (!key) throw new Error("Usage: oppi config get <key>");

      const config = storage.getConfig() as unknown as Record<string, unknown>;
      const value = readConfigPath(config, key);
      if (value === undefined) throw new Error(`Config key is unset: ${key}`);

      const displayValue = redactCredentialValue(value, configPathLeaf(key));
      output(jsonOutput, { key, value: displayValue }, () => {
        writeHumanLine(formatConfigValue(value, key));
      });
      return;
    }

    if (mode === "show") {
      const showDefault = flags.default === "true";
      const config = showDefault ? storage.getDefaultConfig() : storage.getConfig();
      const displayConfig = redactConfigForDisplay(config);

      output(
        jsonOutput,
        { config: displayConfig, source: showDefault ? "default" : "current" },
        () => {
          // displayConfig is already structurally redacted; line-oriented
          // re-redaction would collapse token summaries and nested objects.
          writeHumanLineRaw(`  ${c.bold(showDefault ? "Default config" : "Current config")}`);
          writeHumanLineRaw("");
          const pretty = JSON.stringify(displayConfig, null, 2)
            .split("\n")
            .map((line) => `  ${line}`)
            .join("\n");
          writeHumanLineRaw(pretty);
          writeHumanLineRaw("");
        },
      );
      return;
    }

    if (mode === "validate") {
      const target = flags["config-file"] || storage.getConfigPath();
      const result = storage.validateConfigFile(target);

      output(
        jsonOutput,
        {
          path: target,
          valid: result.valid,
          errors: result.errors.map((error) => redactCredentialString(error)),
          warnings: result.warnings,
        },
        () => {
          if (!result.valid) {
            writeHumanLine(c.red(`  ✗ Config validation failed: ${target}`));
            writeHumanLine("");
            for (const err of result.errors) {
              writeHumanLine(c.red(`  - ${redactCredentialString(err)}`));
            }
            writeHumanLine("");
            return;
          }

          writeHumanLine(c.green(`  ✓ Config valid: ${target}`));
          if (result.warnings.length > 0) {
            writeHumanLine("");
            for (const warning of result.warnings) {
              writeHumanLine(c.yellow(`  ! ${warning}`));
            }
          }
          writeHumanLine("");
        },
      );
      // Interactive validation keeps the failure exit code; JSON mode reports
      // validity as structured data with a clean run (ok: true, valid: false).
      if (!result.valid && !jsonOutput) fail(1);
      return;
    }

    if (mode === "set") {
      const key = positional[0];
      const value = positional[1];

      if (!key || value === undefined) {
        if (jsonOutput) {
          throw new Error(
            "Usage: oppi config set <key> <value>. Run without --json for the full supported-key list.",
          );
        }

        writeHumanLine(c.red("  Usage: oppi config set <key> <value>"));
        writeHumanLine("");
        writeHumanLine(c.bold("  Available keys:"));
        writeHumanLine("");
        const config = storage.getConfig() as unknown as Record<string, unknown>;
        for (const [k, meta] of Object.entries(SETTABLE_CONFIG_KEYS)) {
          const current = readConfigPath(config, k);
          writeHumanLine(`    ${c.cyan(k.padEnd(48))} ${c.dim(meta.desc)}`);
          if (current !== undefined) {
            writeHumanLine(
              `    ${"".padEnd(48)} ${c.dim("current:")} ${formatInlineConfigValue(current, k)}`,
            );
          }
        }
        writeHumanLine("");
        writeHumanLine(c.dim("  Dynamic keys are also supported for runtimeEnv.<NAME>."));
        writeHumanLine("");
        fail(1);
        return;
      }

      const meta = metadataForConfigPath(key);
      if (!meta) {
        throw new Error(
          `Unknown config key: ${key}. Run 'oppi config set' with no value to list supported keys.`,
        );
      }

      const coerced = coerceValue(value, meta.type);
      const nextConfig = setConfigPath(storage.getConfig(), key, coerced);
      storage.updateConfig(nextConfig);
      const displayValue = redactCredentialValue(coerced, configPathLeaf(key));

      output(
        jsonOutput,
        {
          key,
          value: displayValue,
          path: storage.getConfigPath(),
          restartHint:
            key.startsWith("asr") ||
            key.startsWith("tls") ||
            key.startsWith("runtimeEnv.") ||
            key === "runtimeEnv" ||
            key === "port" ||
            key === "host"
              ? "Restart the Oppi server for this change to take effect."
              : undefined,
        },
        () => {
          writeHumanLine(c.green(`  ✓ ${key} = ${formatConfigValue(coerced, key)}`));
          writeHumanLine(c.dim(`    Saved to ${storage.getConfigPath()}`));
          writeHumanLine("");
        },
      );
      return;
    }

    throw new Error("Usage: oppi config [show|get|set|validate]");
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    const safeMessage = redactCredentialString(message);
    if (jsonOutput) {
      writeJsonEnvelope({
        ok: false,
        error: { message: safeMessage },
      });
      captureHumanCliOutput(() => writeHumanLine(c.red(`  ✗ ${safeMessage}`)));
      fail(1);
      return;
    }
    writeHumanLine(c.red(`  ✗ ${safeMessage}`));
    writeHumanLine("");
    fail(1);
  }
}

function output(jsonOutput: boolean, data: Record<string, unknown>, human: () => void): void {
  if (jsonOutput) {
    writeJsonEnvelope({ ok: true, data });
    captureHumanCliOutput(human);
  } else {
    human();
  }
}

function fail(exitCode: number): void {
  // Under runCli capture this only updates the capture store. Outside capture it
  // sets process.exitCode for the interactive CLI process.
  setCapturedCliExitCode(exitCode);
}

function metadataForConfigPath(path: string): SettableConfigPath | undefined {
  if (SETTABLE_CONFIG_KEYS[path]) return SETTABLE_CONFIG_KEYS[path];
  if (path.startsWith("runtimeEnv.") && path.length > "runtimeEnv.".length) {
    return { type: "string", desc: "Runtime env entry" };
  }
  return undefined;
}

function coerceValue(raw: string, type: ConfigValueType): unknown {
  switch (type) {
    case "number": {
      const n = Number(raw);
      if (Number.isNaN(n)) throw new Error("Value is not a valid number");
      return n;
    }
    case "boolean": {
      const lower = raw.toLowerCase();
      if (["true", "1", "yes", "on"].includes(lower)) return true;
      if (["false", "0", "no", "off"].includes(lower)) return false;
      throw new Error("Value is not a valid boolean");
    }
    case "string":
      return raw;
    case "json": {
      try {
        return JSON.parse(raw);
      } catch {
        throw new Error("Value is not valid JSON");
      }
    }
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function splitConfigPath(path: string): string[] {
  return path.split(".").filter((part) => part.length > 0);
}

function readConfigPath(config: Record<string, unknown>, path: string): unknown {
  let cursor: unknown = config;
  for (const part of splitConfigPath(path)) {
    if (!isRecord(cursor) || !(part in cursor)) return undefined;
    cursor = cursor[part];
  }
  return cursor;
}

function cloneConfig(config: ServerConfig): Record<string, unknown> {
  return JSON.parse(JSON.stringify(config)) as Record<string, unknown>;
}

function setConfigPath(config: ServerConfig, path: string, value: unknown): ServerConfig {
  const parts = splitConfigPath(path);
  if (parts.length === 0) throw new Error("Config key cannot be empty");

  const next = cloneConfig(config);
  let cursor = next;
  for (const part of parts.slice(0, -1)) {
    const current = cursor[part];
    if (!isRecord(current)) {
      cursor[part] = {};
    }
    cursor = cursor[part] as Record<string, unknown>;
  }
  const lastPart = parts[parts.length - 1];
  if (!lastPart) throw new Error("Config key cannot be empty");
  cursor[lastPart] = value;
  return next as unknown as ServerConfig;
}

function configPathLeaf(path: string): string {
  return splitConfigPath(path).at(-1) ?? path;
}

function formatConfigValue(value: unknown, path?: string): string {
  const displayValue = redactCredentialValue(value, path ? configPathLeaf(path) : undefined);
  if (typeof displayValue === "object") return JSON.stringify(displayValue, null, 2);
  return String(displayValue);
}

function formatInlineConfigValue(value: unknown, path?: string): string {
  const displayValue = redactCredentialValue(value, path ? configPathLeaf(path) : undefined);
  const text =
    typeof displayValue === "object" ? JSON.stringify(displayValue) : String(displayValue);
  return text.length > 120 ? `${text.slice(0, 117)}...` : text;
}

function redactConfigForDisplay(config: ServerConfig): Record<string, unknown> {
  return redactCredentialValue(cloneConfig(config)) as Record<string, unknown>;
}
