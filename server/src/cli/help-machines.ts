import type { HelpTopic } from "./help.js";

const json = { name: "--json", summary: "write the standard JSON envelope" };

/** `oppi machines` help; also the flag allow-list of its commands. */
export const MACHINE_HELP_TOPICS: HelpTopic[] = [
  {
    path: ["machines"],
    title: "Machines",
    summary: "Set up other computers that sessions can run their tools on.",
    usage: "oppi machines <subcommand> [args] [flags]",
    description: [
      "A machine runs the tools (bash, read, edit, write) of a subagent that names it with spawn host; the conversation, model keys and thread stay on this server.",
      "Machines are saved in the server data directory with this server's own SSH key; the command works without the server running.",
    ],
    subcommands: [
      {
        name: "add <name> --ssh [user@]host[:port]",
        summary: "install this server's key, trust the host key, set up and check the machine",
      },
      {
        name: "test <name>",
        summary: "connect and run one command; never prompts",
      },
      { name: "list", summary: "show machines, their last test and running workers" },
      { name: "remove <name>", summary: "forget a machine and remove the key from it" },
    ],
    examples: [
      { command: "oppi machines add build-mac --ssh alex@build-mac.local" },
      { command: "oppi machines test build-mac" },
    ],
  },
  {
    path: ["machines", "add"],
    title: "Add a machine",
    summary:
      "Install this server's SSH key on a machine, trust its host key, install the helper, capture its login PATH, and test the connection. Nothing is saved unless the test passes.",
    usage:
      "oppi machines add <name> --ssh [user@]host[:port] [--from <address>] [--yes] [--host-key <fingerprint>] [--json]",
    arguments: [{ name: "<name>", summary: "lowercase letters, digits and dashes" }],
    flags: [
      {
        name: "--ssh",
        value: "[user@]host[:port]",
        summary: "how to reach the machine; without a user, this account's name",
        required: true,
      },
      {
        name: "--from",
        value: "<address>",
        summary: "only accept the key from this address (sshd from= pattern)",
      },
      { name: "--yes", summary: "install the key with your own ssh without asking" },
      {
        name: "--host-key",
        value: "<fingerprint>",
        summary: "trust the host key with this SHA256 fingerprint without asking",
      },
      json,
    ],
    notes: [
      "The installed line starts with restrict (no forwarding) but gives a full shell as that user. Use a separate account on the machine to limit it.",
      "Your own ssh (and its config) installs the key; later connections use only this server's key, known-hosts and an empty ssh config.",
    ],
    examples: [{ command: "oppi machines add build-mac --ssh build-mac --yes" }],
  },
  {
    path: ["machines", "test"],
    title: "Test a machine",
    summary: "Connect, run one command, and save the result. Exits 1 when it fails.",
    usage: "oppi machines test <name> [--json]",
    arguments: [{ name: "<name>", summary: "a machine from oppi machines list" }],
    flags: [json],
    notes: [
      "Oppi does not inspect the machine: git, toolchains, disk and sleep settings are yours, and a command that needs a missing tool fails with its own error.",
    ],
  },
  {
    path: ["machines", "list"],
    title: "List machines",
    summary: "Show every machine with its last test and the number of running workers.",
    usage: "oppi machines list [--json]",
    flags: [json],
  },
  {
    path: ["machines", "remove"],
    title: "Remove a machine",
    summary:
      "Forget a machine and remove this server's key from it. Refuses while a worker runs there or a branch is not fetched yet.",
    usage: "oppi machines remove <name> [--force] [--yes] [--json]",
    arguments: [{ name: "<name>", summary: "a machine from oppi machines list" }],
    flags: [
      { name: "--force", summary: "remove even with running workers or unfetched branches" },
      { name: "--yes", summary: "remove the key with your own ssh without asking" },
      json,
    ],
    notes: [
      "Without approval to use your ssh, the command prints the key to delete from the machine's authorized_keys.",
    ],
  },
];
