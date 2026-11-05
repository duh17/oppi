/**
 * Pi owns the Skills and Extensions settings, and Oppi writes them through two route families:
 * the server-global `/server/resources/*` and the workspace-scoped `/workspaces/:id/skills/*`.
 * Both map a failure to an HTTP status here, so the same failure answers the same status.
 */
import { HttpStatusError } from "../http-status-error.js";
import {
  ServerResourceConflictError,
  ServerResourceNotFoundError,
  ServerResourceServiceError,
  ServerResourceValidationError,
} from "../server-resource-service.js";
import { SettingValidationError } from "./registry.js";

/** Reading or writing Pi's settings files failed. */
export class PiSettingsOperationError extends Error {
  constructor(operation: string, detail: string) {
    super(`Pi settings ${operation} failed: ${detail}`);
    this.name = "PiSettingsOperationError";
  }
}

export class PiResourceNotFoundError extends Error {
  constructor(message = "Pi resource not found for cwd") {
    super(message);
    this.name = "PiResourceNotFoundError";
  }
}

export class WorkspaceResourceScopeError extends HttpStatusError {
  constructor(message: string, status: number) {
    super(status, message);
  }
}

/**
 * The status for a Pi resource or settings failure. `fallback` answers an error none of these
 * name: 400 where a route's plain errors are the caller's mistakes (a bad request for a
 * workspace), 500 where they are the server's (the server-global catalog).
 */
export function httpStatusForPiResourceError(error: unknown, fallback: 400 | 500): number {
  if (error instanceof WorkspaceResourceScopeError) return error.status;
  if (error instanceof PiResourceNotFoundError || error instanceof ServerResourceNotFoundError) {
    return 404;
  }
  if (error instanceof SettingValidationError || error instanceof ServerResourceValidationError) {
    return 400;
  }
  if (error instanceof ServerResourceConflictError) return 409;
  if (error instanceof PiSettingsOperationError || error instanceof ServerResourceServiceError) {
    return 500;
  }
  return fallback;
}
