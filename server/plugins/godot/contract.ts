// The `godot_*` tools' words and the text their results show the model. Pure: imports protocol
// types only, so server tests read the same text the tools return. The server resolves projects
// and talks to players (`server/src/godot/godot-service.ts`).
import type {
  GodotCommandResult,
  GodotLogEntry,
  GodotLogPage,
  GodotPlayer,
  GodotProject,
  GodotProjectDetail,
} from "../../src/types.js";

export const GODOT_EXTENSION = "oppi.godot";

export const GODOT_TOOL_NAMES = {
  status: "godot_status",
  logs: "godot_logs",
  capture: "godot_capture",
  input: "godot_input",
  reload: "godot_reload",
  export: "godot_export",
} as const;

/** What `godot_export` builds. */
export const GODOT_EXPORT_TARGETS = ["web", "macos", "linux", "windows"] as const;
export type GodotExportTarget = (typeof GODOT_EXPORT_TARGETS)[number];
/** Targets the schema names so the model hears why they are refused. */
export const GODOT_UNSUPPORTED_TARGETS = ["ios", "android"] as const;

export const UNSUPPORTED_TARGET_ERROR =
  "godot_export does not build iOS or Android: they need signing identities, provisioning and " +
  "platform SDKs the server does not manage. Export web, macos, linux, or windows instead.";

export const TARGET_PARAMETER =
  "web: an HTML5 build the server serves to the owner and paired devices. macos: a zipped " +
  ".app (universal, ad-hoc signed). linux: an x86_64 executable. windows: an x86_64 .exe. " +
  "Desktop builds land in the project's build/<target>/ folder. ios and android are not supported.";

export const INSTALL_TEMPLATES_PARAMETER =
  "Download and install the matching official Godot export templates first when they are " +
  "missing (once per Godot version, about 1.3 GB, checked against the release's SHA-512 sums)";

export const PROJECT_PARAMETER =
  "The game: its id or name from godot_status, one of this workspace's games. Omit it when only " +
  "one of them is playing, or the workspace has only one.";

export const GODOT_DESCRIPTIONS = {
  status:
    "Show a Godot game in Oppi's Godot pane: its current release, the players running it and " +
    "their state, and its latest errors. Without a game that can be chosen, lists this " +
    "workspace's games.",
  logs:
    "Read a game's log as the device running it reports it: prints, warnings, and errors with " +
    "file, line, and backtrace. Pass since (the `next` of the last read) to read only what is new.",
  capture:
    "Take a screenshot of the game running in the Godot pane on the owner's device and look at it.",
  input:
    "Play the game: send taps, drags, keys, and input actions to the device running it, in " +
    "order. Points are fractions of the game view from its top-left (0.5, 0.5 is the middle). " +
    "Set capture to see the screen after the last step.",
  reload:
    "Apply the game's current release again on the device running it. Exports reload by " +
    "themselves; use this after a failed reload, or to restart the scene (tier scene).",
  export:
    "Build a game to play outside Oppi's Godot pane: web (served by this Oppi server at an " +
    "address only the owner and paired devices can open), or a macOS, Linux, or Windows build in " +
    "the project's build/ folder. Uses a preset of its own on a copy of the project; the " +
    "project's export_presets.cfg is neither read nor changed. Needs Godot's export templates, " +
    "which installTemplates downloads once.",
} as const;

/** `godot_export` without templates: the one-time step, said once, never done silently. */
export function templatesMissingError(version: string, folder: string): string {
  return (
    `Godot ${version} export templates are not installed (${folder}). Call godot_export again ` +
    "with installTemplates: true to download them once from the official Godot release " +
    "(about 1.3 GB, verified against its SHA-512 sums), or install them from the Godot editor."
  );
}

export const GODOT_GUIDELINES = [
  "Oppi's Godot pane plays Godot games on the owner's device, next to this chat. A game is a " +
    "folder with project.godot in a workspace; the pane plays the newest pack exported to its " +
    "build/ folder, or the pack an oppi-godot.json beside project.godot names. The godot_* tools " +
    "are offered while a session's workspace has a game; a game added during a session makes " +
    "them appear the next time that session is opened.",
  "After you change a game, export it from its folder: `mkdir -p build && godot --headless " +
    '--path . --export-pack "<preset>" build/<name>.pck`, with a preset from ' +
    "export_presets.cfg that excludes build/*. " +
    "Oppi notices the new pack and the pane reloads it by itself; do not ask the owner to " +
    "reload. Oppi never exports the pane's pack itself.",
  "A change to scripts only reloads in place and keeps the game's state; a scene or resource " +
    "change restarts the scene; a change to project settings or autoloads restarts the game.",
  "To check a change: godot_status for the release and the player's state, godot_logs with " +
    "level error for errors (fix the file and line, then export again), godot_capture to see " +
    "the screen, godot_input to tap, drag, press keys, or trigger actions.",
  "godot_export builds a game to play outside the pane: a web build this server serves to the " +
    "owner and paired devices, or a macOS, Linux, or Windows build in the project's build/ " +
    "folder. It needs Godot's export templates; when they are missing it says how to install them.",
];

const kb = (bytes: number): string =>
  bytes >= 1024 * 1024
    ? `${(bytes / (1024 * 1024)).toFixed(1)} MB`
    : `${Math.ceil(bytes / 1024)} KB`;

function age(at: number, now: number): string {
  const seconds = Math.max(0, Math.round((now - at) / 1000));
  if (seconds < 90) return `${seconds} s ago`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 90) return `${minutes} min ago`;
  return `${Math.round(minutes / 60)} h ago`;
}

function where(project: GodotProject): string {
  const source = project.source;
  if (!source) return "published";
  const folder = source.root === "" ? "the checkout root" : source.root;
  return `${folder} in workspace ${source.workspaceId}, checkout ${source.checkout}`;
}

export function formatPlayer(player: GodotPlayer): string {
  const { state } = player;
  const parts: string[] = [state.phase];
  if (state.release !== undefined) parts.push(`release ${state.release}`);
  if (state.tier) parts.push(`applied as ${state.tier}`);
  if (state.fps !== undefined) parts.push(`${Math.round(state.fps)} fps`);
  if (state.viewport) parts.push(`${state.viewport.width}x${state.viewport.height} pt`);
  const line = `- ${player.id}${player.device ? ` (${player.device})` : ""}: ${parts.join(", ")}`;
  return state.message ? `${line}. ${state.message}` : line;
}

/** One game as `godot_status` shows it. */
export function formatGodotStatus(
  detail: GodotProjectDetail,
  errors: GodotLogEntry[],
  now: number,
): string {
  const lines = [`${detail.name} (${detail.id}): ${where(detail)}.`];
  const release = detail.release;
  if (release) {
    const packs = release.packs.map((pack) => `${pack.format} ${kb(pack.size)}`).join(" + ");
    lines.push(
      `Release ${release.seq}, ${release.origin === "publish" ? "published" : "exported"} ` +
        `${age(release.createdAt, now)}: ${packs}, reload hint ${release.reload}` +
        `${release.label ? `, "${release.label}"` : ""}.`,
    );
  } else {
    const pack = detail.source?.pack ?? "build/<name>.pck";
    lines.push(`No build yet: export a pack to ${pack} in the project folder.`);
  }
  if (detail.players.length === 0) {
    lines.push("No player: the game is not open in a Godot pane.");
  } else {
    lines.push("Players:", ...detail.players.map(formatPlayer));
  }
  if (errors.length > 0) {
    lines.push("Latest errors:", ...errors.map(formatLogEntry));
  }
  return lines.join("\n");
}

/** The games to choose from when a tool could not tell which one was meant. */
export function formatGodotChoices(error: string, projects: GodotProject[]): string {
  if (projects.length === 0) return error;
  const rows = projects.map((project) => {
    const playing = project.players.length > 0 ? ", playing" : "";
    const build = project.release ? `release ${project.release.seq}` : "no build yet";
    return `- ${project.id}: ${project.name}, ${where(project)} (${build}${playing})`;
  });
  return [error, ...rows].join("\n");
}

export function formatLogEntry(entry: GodotLogEntry): string {
  const at = entry.source
    ? ` (${entry.source.file}${entry.source.line !== undefined ? `:${entry.source.line}` : ""}` +
      `${entry.source.function ? ` in ${entry.source.function}` : ""})`
    : "";
  const from = entry.origin === "server" ? "oppi" : entry.level;
  const head = `#${entry.seq} [${from}] ${entry.message}${at}`;
  const frames = (entry.backtrace ?? [])
    .slice(entry.source ? 1 : 0)
    .map(
      (frame) =>
        `    at ${frame.function ?? "?"} (${frame.file}${frame.line !== undefined ? `:${frame.line}` : ""})`,
    );
  return [head, ...frames].join("\n");
}

export function formatLogPage(page: GodotLogPage): string {
  const lines = page.entries.map(formatLogEntry);
  if (page.dropped > 0) lines.unshift(`(${page.dropped} older entries are gone from the log)`);
  if (lines.length === 0) lines.push("Nothing new in the log.");
  lines.push(`next: ${page.next}`);
  return lines.join("\n");
}

/** A failed command, or a short note of what the player did. */
export function formatCommandResult(result: GodotCommandResult): string {
  if (!result.ok) {
    return `${result.name} failed (${result.error?.code ?? "failed"}): ${result.error?.message ?? ""}`.trim();
  }
  const output = (result.output ?? {}) as Record<string, unknown>;
  switch (result.name) {
    case "reload":
      return `Reloaded release ${String(output.release)} as ${String(output.tier)}${
        typeof output.ms === "number" ? ` in ${Math.round(output.ms)} ms` : ""
      }.`;
    case "input":
      return `Sent ${String(output.steps)} input steps in ${Math.round(Number(output.ms) || 0)} ms.`;
    default:
      return `${result.name} done in ${Math.round(result.ms)} ms.`;
  }
}
