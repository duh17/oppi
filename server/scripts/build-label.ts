/**
 * Label a client build for the telemetry review scripts: `build@commit`, or the
 * build number alone when the client sent no git commit, with ` debug` for a
 * Debug-configuration build. The build number is the same for every local
 * install, so the commit is what tells builds apart.
 */
export function buildLabel(record: {
  buildNumber?: string;
  gitCommit?: string;
  debugBuild?: boolean;
}): string {
  const build = record.buildNumber?.trim() || "unknown";
  const commit = record.gitCommit?.trim();
  const label = commit ? `${build}@${commit}` : build;
  return record.debugBuild === true ? `${label} debug` : label;
}
