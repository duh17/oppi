/**
 * Label a client build for the telemetry review scripts: `build@commit`, or the
 * build number alone when the client sent no git commit. The build number is the
 * same for every local install, so the commit is what tells builds apart.
 */
export function buildLabel(record: { buildNumber?: string; gitCommit?: string }): string {
  const build = record.buildNumber?.trim() || "unknown";
  const commit = record.gitCommit?.trim();
  return commit ? `${build}@${commit}` : build;
}
