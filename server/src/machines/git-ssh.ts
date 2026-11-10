import { sshArguments, type SshTarget } from "@earendil-works/pi-env";

const quote = (argument: string): string => `'${argument.replaceAll("'", "'\\''")}'`;

/**
 * `GIT_SSH_COMMAND` for git over the same key, known-hosts, ssh config and host-key alias as the
 * machine's pi-env connection. `sshArguments` ends with `-- <host>`: git adds the host and the
 * remote command itself, so those two go.
 */
export function gitSshCommand(target: SshTarget): string {
  const args = sshArguments(target);
  const tail = args.slice(-2);
  if (tail[0] !== "--" || tail[1] !== target.host)
    throw new Error("pi-env's ssh arguments no longer end with `-- <host>`");
  return [target.ssh ?? "ssh", ...args.slice(0, -2)].map(quote).join(" ");
}

/** The git remote URL of a bare repository at `path` on the target. */
export function gitRemoteUrl(
  target: Pick<SshTarget, "host" | "user" | "port">,
  path: string,
): string {
  const user = target.user === undefined ? "" : `${encodeURIComponent(target.user)}@`;
  const port = target.port === undefined ? "" : `:${target.port}`;
  return `ssh://${user}${target.host}${port}${path.startsWith("/") ? "" : "/"}${path}`;
}
