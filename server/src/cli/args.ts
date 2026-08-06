export type ParsedCliArgs = {
  command: string;
  flags: Record<string, string>;
  positional: string[];
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
