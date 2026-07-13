/* eslint-disable no-console */
import * as c from "../ansi.js";
import {
  localApiRequest,
  type LocalApiConnection,
  type LocalApiHostResolvers,
  type LocalApiRequestOptions,
} from "./local-api-client.js";
import {
  isCliModelResolutionError,
  modelResolutionErrorEnvelope,
  printModelResolutionError,
} from "./model-resolution.js";
import { writeJsonEnvelope } from "./output.js";
import { apiStatus } from "./resources.js";

export function createLocalApiCommandContext(
  storage: LocalApiConnection,
  jsonOutput: boolean,
  hostResolvers: LocalApiHostResolvers,
): {
  call: <T>(path: string, options?: LocalApiRequestOptions) => Promise<T>;
  output: (data: Record<string, unknown>, human: () => void) => void;
} {
  return {
    call: <T>(path: string, options?: LocalApiRequestOptions) =>
      localApiRequest<T>(storage, path, options, hostResolvers),
    output: (data, human) => {
      if (jsonOutput) writeJsonEnvelope({ ok: true, data });
      else human();
    },
  };
}

export function handleModelResolvingCliError(err: unknown, jsonOutput: boolean): never | void {
  const status = apiStatus(err);
  const message = err instanceof Error ? err.message : String(err);
  if (jsonOutput) {
    writeJsonEnvelope({
      ok: false,
      error: isCliModelResolutionError(err)
        ? modelResolutionErrorEnvelope(err)
        : { message, ...(status ? { status } : {}) },
    });
    process.exitCode = 1;
    return;
  }
  if (isCliModelResolutionError(err)) {
    printModelResolutionError(err);
  } else {
    console.log(c.red(`  Error: ${message}`));
  }
  process.exit(1);
}
