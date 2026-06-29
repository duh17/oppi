export type ParsedCliArgs = {
  command: string;
  flags: Record<string, string>;
  positional: string[];
};

export function parseCliArgs(args: string[]): ParsedCliArgs {
  const command = args[0] || "help";
  const flags: Record<string, string> = {};
  const positional: string[] = [];

  for (let i = 1; i < args.length; i++) {
    const arg = args[i];
    if (!arg) continue;
    if (arg === "-h") {
      flags.help = "true";
    } else if (arg.startsWith("--")) {
      const key = arg.slice(2);
      const next = args[i + 1];
      const value = next && !next.startsWith("--") ? (args[++i] ?? "true") : "true";
      flags[key] = value;
    } else {
      positional.push(arg);
    }
  }

  return { command, flags, positional };
}

export function isHelpFlag(flags: Record<string, string>): boolean {
  return flags.help === "true" || flags.h === "true";
}
