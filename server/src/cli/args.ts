/**
 * The commands `runCli` dispatches; the CLI entry point hands these over unparsed. They live
 * here, not in runner.ts, so the entry point can route without loading the runner's commands.
 */
export const RUNNER_COMMANDS: ReadonlySet<string> = new Set([
  "status",
  "quota",
  "models",
  "agent",
  "dictionary",
  "workspace",
  "worktree",
  "session",
  "control",
  "extensions",
  "schedule",
  "wait",
  "config",
]);

export type ParsedCliArgs = {
  command: string;
  flags: Record<string, string>;
  positional: string[];
  /** The short a flag was typed as (`tools` → `-t`), so errors can name what the user typed. */
  shortSpellings: Record<string, string>;
};

type ShortFlagSpec = {
  name: string;
  boolean?: boolean;
};

// Explicit Pi-compatible shorts only. Unknown shorts must error, not become positionals.
const SHORT_FLAGS: Record<string, ShortFlagSpec> = {
  h: { name: "help", boolean: true },
  n: { name: "name" },
  t: { name: "tools" },
  xt: { name: "exclude-tools" },
  nt: { name: "no-tools", boolean: true },
  nbt: { name: "no-builtin-tools", boolean: true },
};

export function parseCliArgs(args: string[]): ParsedCliArgs {
  const command = args[0] || "help";
  const flags: Record<string, string> = {};
  const positional: string[] = [];
  const shortSpellings: Record<string, string> = {};

  let parseFlags = true;
  for (let i = 1; i < args.length; i++) {
    const arg = args[i];
    if (!arg) continue;
    if (parseFlags && arg === "--") {
      parseFlags = false;
    } else if (parseFlags && (arg === "-h" || arg === "--help")) {
      if (Object.hasOwn(flags, "help")) throw new Error("Duplicate flag: --help");
      flags.help = "true";
    } else if (parseFlags && arg.startsWith("--")) {
      const key = arg.slice(2);
      if (!key) throw new Error("Flag name cannot be empty");
      if (Object.hasOwn(flags, key)) throw new Error(`Duplicate flag: --${key}`);
      const consumed = consumeFlagValue(args, i);
      flags[key] = consumed.value;
      i = consumed.index;
    } else if (parseFlags && arg.startsWith("-") && arg !== "-") {
      const spec = SHORT_FLAGS[arg.slice(1)];
      if (!spec) throw new Error(`Unknown flag: ${arg}`);
      if (Object.hasOwn(flags, spec.name)) throw new Error(`Duplicate flag: --${spec.name}`);
      shortSpellings[spec.name] = arg;
      if (spec.boolean) {
        flags[spec.name] = "true";
      } else {
        const consumed = consumeFlagValue(args, i);
        flags[spec.name] = consumed.value;
        i = consumed.index;
      }
    } else {
      positional.push(arg);
    }
  }

  return { command, flags, positional, shortSpellings };
}

function consumeFlagValue(args: string[], index: number): { value: string; index: number } {
  const next = args[index + 1];
  if (next === undefined || next === "--" || next.startsWith("--")) {
    return { value: "true", index };
  }
  return { value: next, index: index + 1 };
}

export function isHelpFlag(flags: Record<string, string>): boolean {
  return Object.keys(flags).some(
    (name) => name === "help" || name === "h" || name.startsWith("help=") || name.startsWith("h="),
  );
}
