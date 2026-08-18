export type ParsedCliArgs = {
  command: string;
  flags: Record<string, string>;
  positional: string[];
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
      const next = args[i + 1];
      const value =
        next && next !== "--" && !next.startsWith("--") ? (args[++i] ?? "true") : "true";
      flags[key] = value;
    } else if (parseFlags && arg.startsWith("-") && arg !== "-") {
      const spec = SHORT_FLAGS[arg.slice(1)];
      if (!spec) throw new Error(`Unknown flag: ${arg}`);
      if (Object.hasOwn(flags, spec.name)) throw new Error(`Duplicate flag: --${spec.name}`);
      if (spec.boolean) {
        flags[spec.name] = "true";
      } else {
        const next = args[i + 1];
        const value =
          next && next !== "--" && !next.startsWith("--") ? (args[++i] ?? "true") : "true";
        flags[spec.name] = value;
      }
    } else {
      positional.push(arg);
    }
  }

  return { command, flags, positional };
}

export function isHelpFlag(flags: Record<string, string>): boolean {
  return Object.keys(flags).some(
    (name) => name === "help" || name === "h" || name.startsWith("help=") || name.startsWith("h="),
  );
}
