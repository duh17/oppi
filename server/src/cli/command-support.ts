/* eslint-disable no-console */
import * as c from "../ansi.js";
import {
  localApiRequest,
  type LocalApiConnection,
  type LocalApiRequestOptions,
} from "./local-api-client.js";
import {
  isCliModelResolutionError,
  modelResolutionErrorEnvelope,
  printModelResolutionError,
} from "./model-resolution.js";
import {
  captureHumanCliOutput,
  cliExitCodeFromUnknown,
  cliJsonErrorFromUnknown,
  setCapturedCliExitCode,
  writeJsonEnvelope,
} from "./output.js";
import { apiStatus } from "./resources.js";

export function createLocalApiCommandContext(
  storage: LocalApiConnection,
  jsonOutput: boolean,
  signal?: AbortSignal,
): {
  call: <T>(path: string, options?: LocalApiRequestOptions) => Promise<T>;
  output: (data: Record<string, unknown>, human: () => void) => void;
} {
  return {
    call: <T>(path: string, options?: LocalApiRequestOptions) =>
      localApiRequest<T>(storage, path, signal ? { ...options, signal } : options),
    output: (data, human) => {
      if (jsonOutput) {
        writeJsonEnvelope({ ok: true, data });
        captureHumanCliOutput(human);
      } else human();
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
        : cliJsonErrorFromUnknown(err, message, status),
    });
    setCapturedCliExitCode(cliExitCodeFromUnknown(err));
    return;
  }
  if (isCliModelResolutionError(err)) {
    printModelResolutionError(err);
  } else {
    console.log(c.red(`  Error: ${message}`));
  }
  process.exit(cliExitCodeFromUnknown(err));
}
