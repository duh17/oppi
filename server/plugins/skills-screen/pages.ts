// The Skills screen's pages, drawn from the server's Skills catalog: the list by what needs
// attention, one Skill's page with its server default, and its files as folder pages whose file
// rows open in the app's own viewer. Pure: the facet (`server.ts`) reads the catalog and writes
// these into each page's document; tests read them directly.
import { basename, dirname, join } from "node:path";
import type { ServerSkillDetail, ServerSkillSummary } from "../../src/server-resource-service.js";
import type {
  ScreenPage,
  ScreenRow,
  ScreenSection,
  ScreenSidebarEntry,
  ScreenStatus,
} from "../../src/types/screens.js";

export const SKILLS_SCREEN_ID = "oppi.skills";

/** The sidebar entry: the server's Skills, server-wide. */
export const SKILLS_SIDEBAR_ENTRY: ScreenSidebarEntry = {
  id: SKILLS_SCREEN_ID,
  title: "Skills",
  icon: "sparkles.rectangle.stack",
  order: 30,
  scopes: ["server"],
  feature: "skills",
};

const SKILL_SYMBOL = "sparkles.rectangle.stack";

/** What a page is drawn from: the catalog or one Skill's detail, or why there is none yet. */
export interface SkillsRead<T> {
  readonly value?: T;
  readonly error?: string;
}

const needsAttention = (skill: ServerSkillSummary): boolean => skill.state === "error";

function statusOf(skill: ServerSkillSummary): ScreenStatus {
  if (needsAttention(skill))
    return { text: "Error", symbol: "exclamationmark.triangle.fill", tone: "warning" };
  return skill.state === "enabled"
    ? { text: "Enabled", symbol: "checkmark.circle", tone: "secondary" }
    : { text: "Disabled", symbol: "minus.circle", tone: "secondary" };
}

const byName = (a: ServerSkillSummary, b: ServerSkillSummary): number =>
  a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" }) ||
  (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

function pending(
  title: string,
  read: SkillsRead<unknown>,
  failure: string,
  loading: string,
): ScreenPage {
  if (read.error)
    return { title, state: { kind: "failed", title: failure, message: read.error }, sections: [] };
  return { title, state: { kind: "loading", message: loading }, sections: [] };
}

/** The catalog, grouped by what needs attention, searchable on the device. */
export function listPage(read: SkillsRead<{ skills: ServerSkillSummary[] }>): ScreenPage {
  const title = "Skills";
  if (!read.value) return pending(title, read, "Couldn't Load Skills", "Loading skills…");
  const skills = [...read.value.skills].sort(byName);
  if (skills.length === 0)
    return {
      title,
      state: {
        kind: "empty",
        title: "No Skills",
        message: "Pi did not resolve any skills on this server.",
      },
      sections: [],
    };
  const row = (skill: ServerSkillSummary): ScreenRow => ({
    kind: "item",
    id: `skill.${skill.id}`,
    title: skill.name,
    subtitle: [skill.description, skill.packageName, skill.provenance.label]
      .filter((line): line is string => Boolean(line))
      .join("\n"),
    symbol: SKILL_SYMBOL,
    status: statusOf(skill),
    push: `skill/${skill.id}`,
  });
  const groups: [string, string, ServerSkillSummary[]][] = [
    ["attention", "Needs Attention", skills.filter(needsAttention)],
    ["enabled", "Enabled", skills.filter((skill) => skill.state === "enabled")],
    ["disabled", "Disabled", skills.filter((skill) => skill.state === "disabled")],
  ];
  return {
    title,
    search: { prompt: "Search skills" },
    sections: groups
      .filter(([, , group]) => group.length > 0)
      .map(([id, header, group]) => ({ id, header, rows: group.map(row) })),
  };
}

/** One Skill: what it is, its server default, where it comes from, Pi's findings, its files. */
export function skillPage(read: SkillsRead<ServerSkillDetail>, id: string): ScreenPage {
  if (!read.value) return pending("Skill", read, "Couldn't Load This Skill", "Loading skill…");
  const { summary, files } = read.value;
  if (summary.id !== id) return pending("Skill", {}, "", "Loading skill…");
  const sections: ScreenSection[] = [];
  if (summary.description)
    sections.push({
      id: "summary",
      rows: [{ kind: "text", id: "description", text: summary.description, tone: "secondary" }],
    });
  const broken = needsAttention(summary);
  sections.push({
    id: "default",
    header: "Server Default",
    footer: "New sessions use this setting. Reload an active session to apply it now.",
    rows: [
      {
        kind: "toggle",
        id: "enabled",
        label: "Enabled",
        value: summary.state === "enabled",
        action: "enabled",
        disabled: broken,
      },
    ],
  });
  const source: ScreenRow[] = [];
  if (summary.packageName)
    source.push({ kind: "value", id: "package", label: "Package", value: summary.packageName });
  source.push(
    { kind: "value", id: "provenance", label: "Provenance", value: summary.provenance.label },
    { kind: "value", id: "scope", label: "Scope", value: "Server default" },
    {
      kind: "value",
      id: "files",
      label: "Files",
      value: summary.editable ? "Editable" : "Read-only",
    },
  );
  sections.push({ id: "source", header: "Source", rows: source });
  const validation: ScreenRow[] = [
    {
      kind: "value",
      id: "status",
      label: "Status",
      value: broken ? "Error" : summary.state === "enabled" ? "Loaded" : "Disabled",
    },
  ];
  const reason = summary.loadError ?? (broken ? "Pi could not read this Skill." : undefined);
  if (reason)
    validation.push({
      kind: "text",
      id: "load-error",
      text: reason,
      tone: "danger",
      selectable: true,
    });
  [...new Set(summary.warnings)].forEach((warning, index) =>
    validation.push({ kind: "text", id: `warning.${index}`, text: warning, tone: "warning" }),
  );
  sections.push({ id: "validation", header: "Validation", rows: validation });
  sections.push({
    id: "contents",
    header: "Contents",
    rows: [
      {
        kind: "item",
        id: "browse",
        title: "Browse Files",
        subtitle: files.length === 1 ? "1 file" : `${files.length} files`,
        symbol: "folder",
        push: `files/${id}`,
      },
    ],
  });
  return { title: summary.name, sections };
}

/**
 * The folder a Skill's files sit in: a `SKILL.md` Skill's directory, a top-level Markdown
 * Skill's directory (the Skill is that one file), or the Skill's directory itself.
 */
function skillDirectory(path: string): string {
  return path.endsWith(".md") ? dirname(path) : path;
}

/**
 * One folder of a Skill's files (`folder` is Skill-relative, empty for its root): folders first,
 * each a page of its own, then files, each opening on the host.
 */
export function filesPage(
  read: SkillsRead<ServerSkillDetail>,
  id: string,
  folder: string,
): ScreenPage | { gone: true } {
  if (!read.value) return pending("Files", read, "Couldn't Load Files", "Loading files…");
  const { summary, files } = read.value;
  if (summary.id !== id) return pending("Files", {}, "", "Loading files…");
  const prefix = folder ? `${folder}/` : "";
  if (folder && !files.some((file) => file.startsWith(prefix))) return { gone: true };
  const folders = new Set<string>();
  const here: string[] = [];
  for (const file of files) {
    if (!file.startsWith(prefix)) continue;
    const rest = file.slice(prefix.length);
    const slash = rest.indexOf("/");
    if (slash === -1) here.push(rest);
    else folders.add(rest.slice(0, slash));
  }
  const compare = (a: string, b: string): number =>
    a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" });
  const base = summary.path ? skillDirectory(summary.path) : undefined;
  const rows: ScreenRow[] = [
    ...[...folders].sort(compare).map((name): ScreenRow => ({
      kind: "item",
      id: `folder.${name}`,
      title: name,
      symbol: "folder",
      push: `files/${id}/${encodeURIComponent(`${prefix}${name}`)}`,
    })),
    ...here.sort(compare).map((name): ScreenRow => ({
      kind: "item",
      id: `file.${name}`,
      title: name,
      symbol: "doc.text",
      ...(base ? { file: join(base, `${prefix}${name}`) } : {}),
    })),
  ];
  return {
    title: folder ? basename(folder) : summary.name,
    sections: [
      {
        id: "files",
        footer: "Open a file to select text, stage comments, and revise it in an Oppi session.",
        rows:
          rows.length > 0
            ? rows
            : [{ kind: "text", id: "none", text: "No files", tone: "secondary" }],
      },
    ],
  };
}
