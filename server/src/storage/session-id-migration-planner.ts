/**
 * Read-only preflight planner for the Session.id = Pi session UUID cutover.
 *
 * This module deliberately accepts evidence supplied by a caller. It neither
 * opens SQLite nor scans traces, attachments, uploads, schedules, or paths.
 * An executor and store-specific inventory belong to later slices.
 */

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface SessionIdMigrationFileEvidence {
  path: string;
  availability: "available" | "unavailable";
  /** Pi session UUID read from the JSONL session header, when the header was readable. */
  headerPiSessionId?: string;
  /** Boundary adapters preserve malformed or rejected evidence without guessing. */
  headerStatus?: "valid" | "unavailable" | "malformed" | "path_rejected";
  headerDetail?: string;
}

export interface SessionIdMigrationSessionRowInput {
  /** Existing Session.id. Must be stable within this planning input. */
  sourceRowId: string;
  /** Existing Session.piSessionId. This is the wrapper's current Pi identity. */
  piSessionId?: string;
  /** Existing Session.piSessionFile, represented by caller-collected evidence. */
  piSessionFile?: SessionIdMigrationFileEvidence;
  /** Existing Session.piSessionFiles, represented by caller-collected evidence. */
  piSessionFiles?: readonly SessionIdMigrationFileEvidence[];
}

export interface SessionIdMigrationDuplicateDispositionInput {
  /** Canonical Pi UUID shared by the duplicate source rows. */
  targetSessionId: string;
  /** Source row retained after coalescing. Field-level authority chooses this row. */
  survivorSourceRowId: string;
  /** Durable audit identifier for the human-approved disposition. */
  decisionId: string;
  /** Durable reason/policy identifier for the survivor decision. */
  reasonId: string;
}

export type SessionIdMigrationReferencePolicy = "rewrite" | "observe_only";

interface SessionIdMigrationReferenceFields {
  location: string;
  sourceSessionId?: string;
  /** Boundary adapters preserve why an otherwise opaque reference was rejected. */
  detail?: string;
}

/**
 * Valid reference-evidence matrix:
 * - classified current evidence: rewrite or observe_only, without observation;
 * - classified stale evidence: observe_only with observation: "stale";
 * - unclassified evidence: rewrite or observe_only, without observation.
 */
export type SessionIdMigrationReferenceInput =
  | (SessionIdMigrationReferenceFields & {
      classification: "classified";
      policy: SessionIdMigrationReferencePolicy;
      observation?: never;
    })
  | (SessionIdMigrationReferenceFields & {
      classification: "classified";
      policy: "observe_only";
      observation: "stale";
    })
  | (SessionIdMigrationReferenceFields & {
      classification: "unclassified";
      policy: SessionIdMigrationReferencePolicy;
      observation?: never;
    });

export type SessionIdMigrationPathInput = SessionIdMigrationReferenceInput & {
  path: string;
};

export interface SessionIdMigrationPlannerInput {
  sessionRows: readonly SessionIdMigrationSessionRowInput[];
  /**
   * Caller-provided UUIDs for rows with no current Pi identity. The planner
   * validates and uses these values; it never generates IDs.
   */
  plannedUuidsBySourceRowId?: Readonly<Record<string, string | undefined>>;
  /** Required to coalesce every target with more than one source row. */
  duplicateDispositions?: readonly SessionIdMigrationDuplicateDispositionInput[];
  /** Only explicitly supplied references are evaluated. */
  references?: readonly SessionIdMigrationReferenceInput[];
  /** Only explicitly supplied session-scoped paths are evaluated. */
  paths?: readonly SessionIdMigrationPathInput[];
  /** Inventory adapters must state both their inspected stores and known gaps. */
  inventoryCoverage?: {
    acceptedInputs: readonly string[];
    notInventoried: readonly string[];
    inspectedButAbsent?: readonly string[];
    unavailable?: readonly string[];
  };
}

export type SessionIdMigrationRowDisposition =
  | "adopt_stored_pi_id"
  | "recover_current_header_id"
  | "use_planned_uuid"
  | "unclassified";

export interface SessionIdMigrationRowPlan {
  sourceRowId: string;
  canonicalSessionId?: string;
  disposition: SessionIdMigrationRowDisposition;
  survivorSourceRowId?: string;
  duplicateGroupId?: string;
  duplicateDecisionId?: string;
  duplicateReasonId?: string;
  sourceEvidence: {
    storedPiSessionId?: string;
    currentFilePath?: string;
    currentFileHeaderPiSessionId?: string;
    plannedUuid?: string;
  };
}

export interface SessionIdMigrationDuplicateGroup {
  groupId: string;
  canonicalSessionId: string;
  memberSourceRowIds: string[];
  resolution: "approved" | "unresolved";
  survivorSourceRowId?: string;
  decisionId?: string;
  reasonId?: string;
}

export interface SessionIdMigrationHistoricalIdentityLoss {
  sourceRowId: string;
  canonicalSessionId?: string;
  discardedIdentityCount: number;
  /** All discarded historical traces, including unattributed traces. */
  availableTraceCount: number;
  unavailableTraceCount: number;
  attributedAvailableTraceCount: number;
  attributedUnavailableTraceCount: number;
  unattributedHistoricalTraceCount: number;
  unattributedHistoricalTraces: Array<{
    path: string;
    availability: "available" | "unavailable";
  }>;
  unattributedAvailableTracePaths: string[];
  unattributedUnavailableTracePaths: string[];
  discardedIdentities: Array<{
    piSessionId: string;
    availableTracePaths: string[];
    unavailableTracePaths: string[];
  }>;
  combinedHistoryVisibilityLost: boolean;
}

export interface SessionIdMigrationFinding {
  kind:
    | "target_collision"
    | "unresolved_duplicate_disposition"
    | "invalid_duplicate_disposition"
    | "invalid_planned_uuid_assignment"
    | "dangling_reference"
    | "unclassified_reference"
    | "invalid_reference_evidence"
    | "stale_reference"
    | "unclassified_session"
    | "unclassified_trace";
  severity: "blocking" | "warning";
  location: string;
  detail: string;
}

export interface SessionIdMigrationManifest {
  version: 1;
  mode: "read-only";
  status: "ready" | "blocked";
  metadata: {
    /** A ready plan is never authorization for a full cutover/executor. */
    readinessScope: "inventoried_partial_scope_only";
    inventoryCoverage: {
      acceptedInputs: string[];
      notInventoried: string[];
      inspectedButAbsent: string[];
      unavailable: string[];
    };
  };
  rows: SessionIdMigrationRowPlan[];
  duplicateGroups: SessionIdMigrationDuplicateGroup[];
  historicalIdentityLosses: SessionIdMigrationHistoricalIdentityLoss[];
  findings: SessionIdMigrationFinding[];
  plannedOperations: {
    sessionRows: Array<{
      kind: "rekey_session_row" | "discard_duplicate_row" | "unresolved_duplicate_row";
      sourceRowId: string;
      targetSessionId?: string;
      survivorSourceRowId?: string;
      decisionId?: string;
      reasonId?: string;
    }>;
    references: Array<{
      location: string;
      sourceSessionId?: string;
      targetSessionId?: string;
      policy: SessionIdMigrationReferencePolicy;
      outcome: "rewrite" | "observe_only" | "dangling" | "unclassified";
    }>;
    paths: Array<{
      location: string;
      path: string;
      sourceSessionId?: string;
      targetSessionId?: string;
      policy: SessionIdMigrationReferencePolicy;
      outcome: "rewrite" | "observe_only" | "dangling" | "unclassified";
    }>;
  };
}

interface PreparedRow {
  input: SessionIdMigrationSessionRowInput;
  plan: SessionIdMigrationRowPlan;
  historicalFiles: SessionIdMigrationFileEvidence[];
}

/**
 * Derive a deterministic manifest without mutating its input or touching disk.
 * Target collisions and required dangling/unclassified references block use of
 * the manifest; callers must resolve them before any future executor runs.
 */
export function planSessionIdMigration(
  input: SessionIdMigrationPlannerInput,
): SessionIdMigrationManifest {
  const findings: SessionIdMigrationFinding[] = [];
  const sortedRows = [...input.sessionRows].sort((left, right) =>
    compareDeterministic(left.sourceRowId, right.sourceRowId),
  );
  const seenSourceRows = new Set<string>();
  const preparedRows = sortedRows.map((row) => prepareRow(row, seenSourceRows, findings));
  auditPlannedUuidAssignments(input, preparedRows, findings);

  const duplicateGroups = buildDuplicateGroups(
    preparedRows,
    input.duplicateDispositions ?? [],
    findings,
  );
  const duplicateGroupBySourceRowId = new Map<string, SessionIdMigrationDuplicateGroup>();
  for (const group of duplicateGroups) {
    for (const sourceRowId of group.memberSourceRowIds) {
      duplicateGroupBySourceRowId.set(sourceRowId, group);
    }
  }

  const rows = preparedRows.map(({ plan }) => {
    const duplicateGroup = duplicateGroupBySourceRowId.get(plan.sourceRowId);
    return {
      ...plan,
      ...(duplicateGroup ? { duplicateGroupId: duplicateGroup.groupId } : {}),
      ...(duplicateGroup?.resolution === "approved" && duplicateGroup.survivorSourceRowId
        ? { survivorSourceRowId: duplicateGroup.survivorSourceRowId }
        : {}),
      ...(duplicateGroup?.decisionId ? { duplicateDecisionId: duplicateGroup.decisionId } : {}),
      ...(duplicateGroup?.reasonId ? { duplicateReasonId: duplicateGroup.reasonId } : {}),
    };
  });
  const canonicalBySourceRowId = new Map(
    rows.flatMap((row) =>
      row.canonicalSessionId ? [[row.sourceRowId, row.canonicalSessionId]] : [],
    ),
  );
  findUnsafeOccupiedTargets(preparedRows, duplicateGroups, findings);

  const historicalIdentityLosses = preparedRows
    .map(({ plan, historicalFiles }) =>
      buildHistoricalIdentityLoss(plan, historicalFiles, findings),
    )
    .filter((loss): loss is SessionIdMigrationHistoricalIdentityLoss => loss !== undefined);

  const plannedOperations = {
    sessionRows: rows.map((row) => {
      const duplicateGroup = row.duplicateGroupId
        ? duplicateGroups.find((group) => group.groupId === row.duplicateGroupId)
        : undefined;
      const kind =
        duplicateGroup?.resolution === "unresolved"
          ? ("unresolved_duplicate_row" as const)
          : row.survivorSourceRowId && row.survivorSourceRowId !== row.sourceRowId
            ? ("discard_duplicate_row" as const)
            : ("rekey_session_row" as const);
      return {
        kind,
        sourceRowId: row.sourceRowId,
        ...(row.canonicalSessionId ? { targetSessionId: row.canonicalSessionId } : {}),
        ...(row.survivorSourceRowId && row.survivorSourceRowId !== row.sourceRowId
          ? { survivorSourceRowId: row.survivorSourceRowId }
          : {}),
        ...(row.duplicateDecisionId ? { decisionId: row.duplicateDecisionId } : {}),
        ...(row.duplicateReasonId ? { reasonId: row.duplicateReasonId } : {}),
      };
    }),
    references: planReferences(input.references ?? [], canonicalBySourceRowId, findings),
    paths: planPaths(input.paths ?? [], canonicalBySourceRowId, findings),
  };

  return {
    version: 1,
    mode: "read-only",
    status: findings.some((finding) => finding.severity === "blocking") ? "blocked" : "ready",
    metadata: {
      readinessScope: "inventoried_partial_scope_only",
      inventoryCoverage: input.inventoryCoverage
        ? {
            acceptedInputs: [...input.inventoryCoverage.acceptedInputs].sort(compareDeterministic),
            notInventoried: [...input.inventoryCoverage.notInventoried].sort(compareDeterministic),
            inspectedButAbsent: [...(input.inventoryCoverage.inspectedButAbsent ?? [])].sort(
              compareDeterministic,
            ),
            unavailable: [...(input.inventoryCoverage.unavailable ?? [])].sort(
              compareDeterministic,
            ),
          }
        : {
            acceptedInputs: [
              "session rows with caller-collected Pi header/file evidence",
              "explicit session-ID references",
              "explicit session-scoped paths",
            ],
            notInventoried: [
              "SQLite tables and production Session rows",
              "Pi JSONL files and trace directories",
              "session attachments, uploads, schedules, search indexes, and runtime state",
            ],
            inspectedButAbsent: [],
            unavailable: [],
          },
    },
    rows,
    duplicateGroups,
    historicalIdentityLosses,
    findings: findings.sort(compareFindings),
    plannedOperations,
  };
}

function prepareRow(
  input: SessionIdMigrationSessionRowInput,
  seenSourceRows: Set<string>,
  findings: SessionIdMigrationFinding[],
): PreparedRow {
  const sourceRowId = input.sourceRowId.trim();
  if (!sourceRowId || seenSourceRows.has(sourceRowId)) {
    findings.push({
      kind: "unclassified_session",
      severity: "blocking",
      location: `session-row:${input.sourceRowId}`,
      detail: "sourceRowId is empty or duplicated",
    });
  }
  seenSourceRows.add(sourceRowId);

  const storedPiSessionId = normalizeUuid(input.piSessionId);
  const currentFile = input.piSessionFile;
  const currentFileHeaderPiSessionId = normalizeUuid(currentFile?.headerPiSessionId);
  let canonicalSessionId: string | undefined;
  let disposition: SessionIdMigrationRowDisposition = "unclassified";

  if (storedPiSessionId) {
    canonicalSessionId = storedPiSessionId;
    disposition = "adopt_stored_pi_id";
  } else if (currentFileHeaderPiSessionId) {
    canonicalSessionId = currentFileHeaderPiSessionId;
    disposition = "recover_current_header_id";
  }

  if (input.piSessionId?.trim() && !storedPiSessionId) {
    findings.push({
      kind: "unclassified_session",
      severity: "blocking",
      location: `session-row:${input.sourceRowId}`,
      detail: "stored Pi session ID is not a UUID",
    });
  }
  if (currentFile?.availability === "available" && currentFile.headerStatus === "unavailable") {
    findings.push({
      kind: "unclassified_trace",
      severity: "blocking",
      location: `session-row:${input.sourceRowId}:current-file:${currentFile.path}`,
      detail: "current trace availability and header status contradict",
    });
  } else if (
    currentFile?.availability === "unavailable" &&
    currentFile.headerStatus !== "path_rejected"
  ) {
    findings.push({
      kind: "unclassified_trace",
      severity: "blocking",
      location: `session-row:${input.sourceRowId}:current-file:${currentFile.path}`,
      detail: "declared current trace is unavailable",
    });
  } else if (
    currentFile?.headerStatus === "malformed" ||
    currentFile?.headerStatus === "path_rejected"
  ) {
    findings.push({
      kind: "unclassified_trace",
      severity: "blocking",
      location: `session-row:${input.sourceRowId}:current-file:${currentFile.path}`,
      detail:
        currentFile.headerDetail ??
        (currentFile.headerStatus === "path_rejected"
          ? "current trace path was rejected by the inventory boundary"
          : "current trace header is malformed"),
    });
  } else if (currentFile?.headerStatus === "valid" && !currentFileHeaderPiSessionId) {
    findings.push({
      kind: "unclassified_trace",
      severity: "blocking",
      location: `session-row:${input.sourceRowId}:current-file:${currentFile.path}`,
      detail: "current trace is marked valid without a valid Pi session UUID",
    });
  } else if (currentFile?.headerPiSessionId?.trim() && !currentFileHeaderPiSessionId) {
    findings.push({
      kind: "unclassified_trace",
      severity: "blocking",
      location: `session-row:${input.sourceRowId}:current-file:${currentFile.path}`,
      detail: "current trace header Pi session ID is not a UUID",
    });
  }
  if (
    canonicalSessionId &&
    currentFileHeaderPiSessionId &&
    currentFileHeaderPiSessionId !== canonicalSessionId
  ) {
    findings.push({
      kind: "unclassified_session",
      severity: "blocking",
      location: `session-row:${input.sourceRowId}:current-file:${currentFile?.path}`,
      detail: "current file header UUID disagrees with the selected current Pi identity",
    });
  }

  const historicalFiles = (input.piSessionFiles ?? []).filter(
    (file) => file.path !== currentFile?.path,
  );
  return {
    input,
    plan: {
      sourceRowId: input.sourceRowId,
      ...(canonicalSessionId ? { canonicalSessionId } : {}),
      disposition,
      sourceEvidence: {
        ...(storedPiSessionId ? { storedPiSessionId } : {}),
        ...(currentFile ? { currentFilePath: currentFile.path } : {}),
        ...(currentFileHeaderPiSessionId ? { currentFileHeaderPiSessionId } : {}),
      },
    },
    historicalFiles,
  };
}

function auditPlannedUuidAssignments(
  input: SessionIdMigrationPlannerInput,
  rows: PreparedRow[],
  findings: SessionIdMigrationFinding[],
): void {
  const assignments = input.plannedUuidsBySourceRowId ?? {};
  const rowBySourceId = new Map(rows.map((row) => [row.input.sourceRowId, row]));
  for (const sourceRowId of Object.keys(assignments).sort(compareDeterministic)) {
    const supplied = assignments[sourceRowId];
    const row = rowBySourceId.get(sourceRowId);
    const plannedUuid = normalizeUuid(supplied);
    const location = `planned-uuid:${sourceRowId}`;
    if (!row) {
      findings.push({
        kind: "invalid_planned_uuid_assignment",
        severity: "blocking",
        location,
        detail: "assignment does not match an inventoried Session row",
      });
      continue;
    }
    if (!plannedUuid) {
      findings.push({
        kind: "invalid_planned_uuid_assignment",
        severity: "blocking",
        location,
        detail: "assigned UUID is invalid",
      });
      continue;
    }
    const stored = normalizeUuid(row.input.piSessionId);
    const header = normalizeUuid(row.input.piSessionFile?.headerPiSessionId);
    if (stored || header) {
      findings.push({
        kind: "invalid_planned_uuid_assignment",
        severity: "blocking",
        location,
        detail: "assignment is unused because the row already has a current Pi identity",
      });
      continue;
    }
    if (row.plan.canonicalSessionId) {
      findings.push({
        kind: "invalid_planned_uuid_assignment",
        severity: "blocking",
        location,
        detail: "assignment is unused because the row already has a canonical identity",
      });
      continue;
    }
    row.plan.canonicalSessionId = plannedUuid;
    row.plan.disposition = "use_planned_uuid";
    row.plan.sourceEvidence.plannedUuid = plannedUuid;
  }
  for (const row of rows) {
    if (row.plan.canonicalSessionId) continue;
    findings.push({
      kind: "unclassified_session",
      severity: "blocking",
      location: `session-row:${row.input.sourceRowId}`,
      detail: "no valid stored Pi UUID, current header UUID, or approved planned UUID",
    });
  }
}

function buildDuplicateGroups(
  rows: PreparedRow[],
  dispositions: readonly SessionIdMigrationDuplicateDispositionInput[],
  findings: SessionIdMigrationFinding[],
): SessionIdMigrationDuplicateGroup[] {
  const byTarget = new Map<string, PreparedRow[]>();
  for (const row of rows) {
    const target = row.plan.canonicalSessionId;
    if (!target) continue;
    const group = byTarget.get(target) ?? [];
    group.push(row);
    byTarget.set(target, group);
  }

  const decisionsByTarget = new Map<string, SessionIdMigrationDuplicateDispositionInput[]>();
  for (const disposition of dispositions) {
    const target = normalizeUuid(disposition.targetSessionId);
    if (!target) {
      findings.push({
        kind: "invalid_duplicate_disposition",
        severity: "blocking",
        location: `duplicate-disposition:${disposition.targetSessionId}`,
        detail: "targetSessionId is not a UUID",
      });
      continue;
    }
    const decisions = decisionsByTarget.get(target) ?? [];
    decisions.push(disposition);
    decisionsByTarget.set(target, decisions);
  }

  const groups = Array.from(byTarget.entries())
    .filter(([, rowsForTarget]) => rowsForTarget.length > 1)
    .sort(([left], [right]) => compareDeterministic(left, right))
    .map(([canonicalSessionId, rowsForTarget]) => {
      const memberSourceRowIds = rowsForTarget
        .map((member) => member.input.sourceRowId)
        .sort(compareDeterministic);
      const decisions = decisionsByTarget.get(canonicalSessionId) ?? [];
      const decision = decisions.length === 1 ? decisions[0] : undefined;
      const validDecision =
        decision !== undefined &&
        memberSourceRowIds.includes(decision.survivorSourceRowId) &&
        decision.decisionId.trim().length > 0 &&
        decision.reasonId.trim().length > 0;
      if (!validDecision) {
        findings.push({
          kind:
            decisions.length > 0
              ? "invalid_duplicate_disposition"
              : "unresolved_duplicate_disposition",
          severity: "blocking",
          location: `target:${canonicalSessionId}`,
          detail:
            decisions.length > 1
              ? "multiple duplicate dispositions supplied"
              : decision
                ? "survivor must be a member and decisionId/reasonId must be present"
                : "duplicate disposition is required",
        });
      }
      return {
        groupId: `duplicate:${canonicalSessionId}`,
        canonicalSessionId,
        memberSourceRowIds,
        resolution: validDecision ? ("approved" as const) : ("unresolved" as const),
        ...(validDecision
          ? {
              survivorSourceRowId: decision.survivorSourceRowId,
              decisionId: decision.decisionId,
              reasonId: decision.reasonId,
            }
          : {}),
      };
    });

  for (const [target, decisions] of decisionsByTarget) {
    const matchingRows = byTarget.get(target);
    if (matchingRows && matchingRows.length > 1) continue;
    findings.push({
      kind: "invalid_duplicate_disposition",
      severity: "blocking",
      location: `target:${target}`,
      detail: `duplicate disposition does not match a duplicate target (${decisions.length} supplied)`,
    });
  }
  return groups;
}

function findUnsafeOccupiedTargets(
  rows: PreparedRow[],
  duplicateGroups: SessionIdMigrationDuplicateGroup[],
  findings: SessionIdMigrationFinding[],
): void {
  const approvedMembersByTarget = new Map(
    duplicateGroups
      .filter((group) => group.resolution === "approved")
      .map((group) => [group.canonicalSessionId, new Set(group.memberSourceRowIds)]),
  );
  const bySourceRowId = new Map(rows.map((row) => [normalizeUuid(row.input.sourceRowId), row]));
  const targets = new Set(
    rows.flatMap((row) => (row.plan.canonicalSessionId ? [row.plan.canonicalSessionId] : [])),
  );
  for (const target of targets) {
    const occupant = bySourceRowId.get(target);
    if (!occupant || occupant.plan.canonicalSessionId === target) continue;
    if (approvedMembersByTarget.get(target)?.has(occupant.input.sourceRowId)) continue;
    findings.push({
      kind: "target_collision",
      severity: "blocking",
      location: `target:${target}`,
      detail: `target is occupied by source row ${occupant.input.sourceRowId} outside an approved duplicate disposition`,
    });
  }
}

function buildHistoricalIdentityLoss(
  row: SessionIdMigrationRowPlan,
  historicalFiles: SessionIdMigrationFileEvidence[],
  findings: SessionIdMigrationFinding[],
): SessionIdMigrationHistoricalIdentityLoss | undefined {
  const byIdentity = new Map<
    string,
    { availableTracePaths: string[]; unavailableTracePaths: string[] }
  >();
  const unattributedAvailableTracePaths: string[] = [];
  const unattributedUnavailableTracePaths: string[] = [];
  for (const file of [...historicalFiles].sort((left, right) =>
    compareDeterministic(left.path, right.path),
  )) {
    if (
      (file.availability === "available" && file.headerStatus === "unavailable") ||
      (file.availability === "unavailable" &&
        file.headerStatus !== undefined &&
        file.headerStatus !== "unavailable")
    ) {
      findings.push({
        kind: "unclassified_trace",
        severity: "blocking",
        location: `session-row:${row.sourceRowId}:historical-file:${file.path}`,
        detail: "historical trace availability and header status contradict",
      });
    }
    if (file.headerStatus === "malformed" || file.headerStatus === "path_rejected") {
      findings.push({
        kind: "unclassified_trace",
        severity: "blocking",
        location: `session-row:${row.sourceRowId}:historical-file:${file.path}`,
        detail:
          file.headerDetail ??
          (file.headerStatus === "path_rejected"
            ? "historical trace path was rejected by the inventory boundary"
            : "historical trace header is malformed"),
      });
    }
    const historicalIdentity = normalizeUuid(file.headerPiSessionId);
    if (!historicalIdentity) {
      (file.availability === "available"
        ? unattributedAvailableTracePaths
        : unattributedUnavailableTracePaths
      ).push(file.path);
      findings.push({
        kind: "unclassified_trace",
        severity: file.headerStatus === "valid" ? "blocking" : "warning",
        location: `session-row:${row.sourceRowId}:historical-file:${file.path}`,
        detail:
          file.headerStatus === "valid"
            ? "historical trace is marked valid without a valid Pi session UUID"
            : "historical trace has no valid header UUID and is reported as unattributed loss",
      });
      continue;
    }
    if (historicalIdentity === row.canonicalSessionId) continue;
    const loss = byIdentity.get(historicalIdentity) ?? {
      availableTracePaths: [],
      unavailableTracePaths: [],
    };
    (file.availability === "available"
      ? loss.availableTracePaths
      : loss.unavailableTracePaths
    ).push(file.path);
    byIdentity.set(historicalIdentity, loss);
  }

  if (
    byIdentity.size === 0 &&
    unattributedAvailableTracePaths.length === 0 &&
    unattributedUnavailableTracePaths.length === 0
  ) {
    return undefined;
  }
  const discardedIdentities = Array.from(byIdentity.entries())
    .sort(([left], [right]) => compareDeterministic(left, right))
    .map(([piSessionId, loss]) => ({
      piSessionId,
      availableTracePaths: loss.availableTracePaths.sort(compareDeterministic),
      unavailableTracePaths: loss.unavailableTracePaths.sort(compareDeterministic),
    }));
  return {
    sourceRowId: row.sourceRowId,
    ...(row.canonicalSessionId ? { canonicalSessionId: row.canonicalSessionId } : {}),
    discardedIdentityCount: discardedIdentities.length,
    availableTraceCount:
      discardedIdentities.reduce(
        (count, identity) => count + identity.availableTracePaths.length,
        0,
      ) + unattributedAvailableTracePaths.length,
    unavailableTraceCount:
      discardedIdentities.reduce(
        (count, identity) => count + identity.unavailableTracePaths.length,
        0,
      ) + unattributedUnavailableTracePaths.length,
    attributedAvailableTraceCount: discardedIdentities.reduce(
      (count, identity) => count + identity.availableTracePaths.length,
      0,
    ),
    attributedUnavailableTraceCount: discardedIdentities.reduce(
      (count, identity) => count + identity.unavailableTracePaths.length,
      0,
    ),
    unattributedHistoricalTraceCount:
      unattributedAvailableTracePaths.length + unattributedUnavailableTracePaths.length,
    unattributedHistoricalTraces: [
      ...unattributedAvailableTracePaths.map((path) => ({
        path,
        availability: "available" as const,
      })),
      ...unattributedUnavailableTracePaths.map((path) => ({
        path,
        availability: "unavailable" as const,
      })),
    ],
    unattributedAvailableTracePaths,
    unattributedUnavailableTracePaths,
    discardedIdentities,
    combinedHistoryVisibilityLost: true,
  };
}

function planReferences(
  references: readonly SessionIdMigrationReferenceInput[],
  canonicalBySourceRowId: ReadonlyMap<string, string>,
  findings: SessionIdMigrationFinding[],
): SessionIdMigrationManifest["plannedOperations"]["references"] {
  return [...references]
    .sort((left, right) => compareDeterministic(left.location, right.location))
    .map((reference) => planReference(reference, canonicalBySourceRowId, findings));
}

function planPaths(
  paths: readonly SessionIdMigrationPathInput[],
  canonicalBySourceRowId: ReadonlyMap<string, string>,
  findings: SessionIdMigrationFinding[],
): SessionIdMigrationManifest["plannedOperations"]["paths"] {
  return [...paths]
    .sort(
      (left, right) =>
        compareDeterministic(left.location, right.location) ||
        compareDeterministic(left.path, right.path),
    )
    .map((path) => ({ ...planReference(path, canonicalBySourceRowId, findings), path: path.path }));
}

function planReference(
  reference: SessionIdMigrationReferenceInput,
  canonicalBySourceRowId: ReadonlyMap<string, string>,
  findings: SessionIdMigrationFinding[],
): SessionIdMigrationManifest["plannedOperations"]["references"][number] {
  const policy = reference.policy;
  const invalidEvidenceDetail = invalidReferenceEvidence(reference);
  if (invalidEvidenceDetail) {
    findings.push({
      kind: "invalid_reference_evidence",
      severity: "blocking",
      location: reference.location,
      detail: invalidEvidenceDetail,
    });
    return {
      location: reference.location,
      ...(reference.sourceSessionId ? { sourceSessionId: reference.sourceSessionId } : {}),
      policy,
      outcome: "unclassified",
    };
  }
  if (reference.classification === "unclassified") {
    addReferenceFinding(
      "unclassified_reference",
      reference,
      findings,
      reference.detail ?? "reference is not classified",
    );
    return {
      location: reference.location,
      ...(reference.sourceSessionId ? { sourceSessionId: reference.sourceSessionId } : {}),
      policy,
      outcome: policy === "observe_only" ? "observe_only" : "unclassified",
    };
  }
  if (reference.observation === "stale") {
    findings.push({
      kind: "stale_reference",
      severity: "warning",
      location: reference.location,
      detail: reference.detail ?? "reference is retained as stale non-rewrite evidence",
    });
  }
  const targetSessionId = reference.sourceSessionId
    ? canonicalBySourceRowId.get(reference.sourceSessionId)
    : undefined;
  if (!targetSessionId) {
    addReferenceFinding(
      "dangling_reference",
      reference,
      findings,
      reference.detail ?? "source Session row has no canonical target",
    );
    return {
      location: reference.location,
      ...(reference.sourceSessionId ? { sourceSessionId: reference.sourceSessionId } : {}),
      policy,
      outcome: policy === "observe_only" ? "observe_only" : "dangling",
    };
  }
  return {
    location: reference.location,
    sourceSessionId: reference.sourceSessionId,
    targetSessionId,
    policy,
    outcome: policy === "observe_only" ? "observe_only" : "rewrite",
  };
}

function invalidReferenceEvidence(reference: SessionIdMigrationReferenceInput): string | undefined {
  const candidate = reference as {
    classification?: unknown;
    policy?: unknown;
    observation?: unknown;
  };
  const observation = candidate.observation;
  if (candidate.classification === "classified") {
    if (candidate.policy !== "rewrite" && candidate.policy !== "observe_only") {
      return "classified reference policy is not recognized";
    }
    if (observation === undefined) return undefined;
    return candidate.policy === "observe_only" && observation === "stale"
      ? undefined
      : "classified stale observation requires observe_only policy";
  }
  if (candidate.classification === "unclassified") {
    if (candidate.policy !== "rewrite" && candidate.policy !== "observe_only") {
      return "unclassified reference policy is not recognized";
    }
    return observation === undefined
      ? undefined
      : "unclassified reference must not carry an observation";
  }
  return "reference classification is not recognized";
}

function addReferenceFinding(
  kind: "dangling_reference" | "unclassified_reference",
  reference: SessionIdMigrationReferenceInput,
  findings: SessionIdMigrationFinding[],
  detail: string,
): void {
  findings.push({
    kind,
    severity:
      kind === "unclassified_reference"
        ? "blocking"
        : reference.policy === "observe_only"
          ? "warning"
          : "blocking",
    location: reference.location,
    detail,
  });
}

function normalizeUuid(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed && UUID_PATTERN.test(trimmed) ? trimmed.toLowerCase() : undefined;
}

function compareFindings(
  left: SessionIdMigrationFinding,
  right: SessionIdMigrationFinding,
): number {
  return (
    compareDeterministic(left.kind, right.kind) ||
    compareDeterministic(left.location, right.location) ||
    compareDeterministic(left.detail, right.detail)
  );
}

/** Unicode code-unit ordering is locale-independent and stable across hosts. */
function compareDeterministic(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}
