/**
 * What a machine failure reads as, for the model, the spawn answer and the CLI. `message` is
 * what pi-env or ssh reported; undefined leaves it as it is. The text names the machine and the
 * fix, never a command, path or key.
 */
export function machineFailure(machine: string, message: string): string | undefined {
  if (/host key|REMOTE HOST IDENTIFICATION|Host key verification failed/i.test(message))
    return `${machine}'s host key changed or is not trusted. Check the machine, then \`oppi machines add ${machine}\` again.`;
  if (/permission denied/i.test(message))
    return `${machine} refused Oppi's key; is the \`authorized_keys\` line installed?`;
  if (
    /sha256sum|shasum|openssl|No pi-env daemon|Unsupported remote|Unexpected answer|upload|deploy/i.test(
      message,
    )
  )
    return `Could not install Oppi's helper on ${machine}: ${message.split("\n")[0]?.slice(0, 200)}.`;
  if (
    /connection (lost|timed out)|did not answer|did not finish|ConnectTimeout|timed out|no route|could not resolve|connection refused|network is unreachable|exited with code|ssh .* failed|connection closed/i.test(
      message,
    )
  )
    return `${machine} is offline or unreachable; its files are kept. \`oppi machines test ${machine}\`.`;
  return undefined;
}
