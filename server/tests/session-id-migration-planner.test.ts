import { describe, expect, it } from "vitest";

import {
  decideFieldAuthorityDuplicateMerge,
  FIELD_AUTHORITY_DUPLICATE_REASON_ID,
  type SessionIdMigrationMergeMember,
} from "../src/storage/session-id-migration-merge.js";
import {
  planSessionIdMigration,
  type SessionIdMigrationPlannerInput,
  type SessionIdMigrationReferenceInput,
} from "../src/storage/session-id-migration-planner.js";

const PI_A = "11111111-1111-4111-8111-111111111111";
const PI_B = "22222222-2222-4222-8222-222222222222";
const PI_C = "33333333-3333-4333-8333-333333333333";
const PLANNED = "44444444-4444-4444-8444-444444444444";

function freezeDeep<T>(value: T): T {
  if (value && typeof value === "object") {
    Object.freeze(value);
    for (const child of Object.values(value as Record<string, unknown>)) {
      freezeDeep(child);
    }
  }
  return value;
}

describe("session ID migration planner", () => {
  it("maps unique stored Pi UUIDs and emits data-only row, reference, and path operations", () => {
    const manifest = planSessionIdMigration({
      sessionRows: [{ sourceRowId: "wrapper-a", piSessionId: PI_A }],
      references: [
        {
          location: "explicit-reference:attachment-record",
          sourceSessionId: "wrapper-a",
          classification: "classified",
          policy: "rewrite",
        },
      ],
      paths: [
        {
          location: "explicit-path:attachment-directory",
          path: "session-attachments/wrapper-a",
          sourceSessionId: "wrapper-a",
          classification: "classified",
          policy: "rewrite",
        },
      ],
    });

    expect(manifest.status).toBe("ready");
    expect(manifest.rows).toEqual([
      expect.objectContaining({
        sourceRowId: "wrapper-a",
        canonicalSessionId: PI_A,
        disposition: "adopt_stored_pi_id",
      }),
    ]);
    expect(manifest.plannedOperations.sessionRows).toEqual([
      { kind: "rekey_session_row", sourceRowId: "wrapper-a", targetSessionId: PI_A },
    ]);
    expect(manifest.plannedOperations.references).toEqual([
      {
        location: "explicit-reference:attachment-record",
        sourceSessionId: "wrapper-a",
        targetSessionId: PI_A,
        policy: "rewrite",
        outcome: "rewrite",
      },
    ]);
    expect(manifest.plannedOperations.paths).toEqual([
      {
        location: "explicit-path:attachment-directory",
        path: "session-attachments/wrapper-a",
        sourceSessionId: "wrapper-a",
        targetSessionId: PI_A,
        policy: "rewrite",
        outcome: "rewrite",
      },
    ]);
    expect(manifest.metadata.inventoryCoverage.notInventoried).toContain(
      "SQLite tables and production Session rows",
    );
  });

  it("plans an explicitly approved duplicate survivor without blocking the known group", () => {
    const manifest = planSessionIdMigration({
      sessionRows: [
        { sourceRowId: "older-authoritative", piSessionId: PI_A },
        { sourceRowId: "newer", piSessionId: PI_A },
        { sourceRowId: "unique", piSessionId: PI_B },
      ],
      duplicateDispositions: [
        {
          targetSessionId: PI_A,
          survivorSourceRowId: "older-authoritative",
          decisionId: "duplicate-review-2026-07-15-01",
          reasonId: "field-authority:canonical-metadata",
        },
      ],
    });

    expect(manifest.status).toBe("ready");
    expect(manifest.duplicateGroups).toEqual([
      {
        groupId: `duplicate:${PI_A}`,
        canonicalSessionId: PI_A,
        memberSourceRowIds: ["newer", "older-authoritative"],
        resolution: "approved",
        survivorSourceRowId: "older-authoritative",
        decisionId: "duplicate-review-2026-07-15-01",
        reasonId: "field-authority:canonical-metadata",
      },
    ]);
    expect(manifest.rows.find((row) => row.sourceRowId === "newer")).toMatchObject({
      canonicalSessionId: PI_A,
      survivorSourceRowId: "older-authoritative",
      duplicateDecisionId: "duplicate-review-2026-07-15-01",
    });
    expect(manifest.plannedOperations.sessionRows).toContainEqual({
      kind: "discard_duplicate_row",
      sourceRowId: "newer",
      targetSessionId: PI_A,
      survivorSourceRowId: "older-authoritative",
      decisionId: "duplicate-review-2026-07-15-01",
      reasonId: "field-authority:canonical-metadata",
    });
    expect(manifest.findings).not.toContainEqual(
      expect.objectContaining({ kind: "target_collision" }),
    );
  });

  it("blocks duplicate groups with missing or invalid dispositions", () => {
    const sessionRows = [
      { sourceRowId: "first", piSessionId: PI_A },
      { sourceRowId: "second", piSessionId: PI_A },
    ];
    const missing = planSessionIdMigration({ sessionRows });
    const invalid = planSessionIdMigration({
      sessionRows,
      duplicateDispositions: [
        {
          targetSessionId: PI_A,
          survivorSourceRowId: "not-a-member",
          decisionId: "duplicate-review-2026-07-15-invalid",
          reasonId: "field-authority:canonical-metadata",
        },
      ],
    });

    expect(missing.status).toBe("blocked");
    expect(missing.duplicateGroups[0]).toMatchObject({ resolution: "unresolved" });
    expect(missing.plannedOperations.sessionRows).toEqual(
      expect.arrayContaining([expect.objectContaining({ kind: "unresolved_duplicate_row" })]),
    );
    expect(missing.findings).toContainEqual(
      expect.objectContaining({ kind: "unresolved_duplicate_disposition", severity: "blocking" }),
    );
    expect(invalid.status).toBe("blocked");
    expect(invalid.findings).toContainEqual(
      expect.objectContaining({ kind: "invalid_duplicate_disposition", severity: "blocking" }),
    );
  });

  it("blocks a target occupied by a source row outside its approved duplicate disposition", () => {
    const manifest = planSessionIdMigration({
      sessionRows: [
        { sourceRowId: PI_A, piSessionId: PI_B },
        { sourceRowId: "wrapper-for-a", piSessionId: PI_A },
      ],
    });

    expect(manifest.status).toBe("blocked");
    expect(manifest.findings).toContainEqual(
      expect.objectContaining({
        kind: "target_collision",
        severity: "blocking",
        location: `target:${PI_A}`,
      }),
    );
  });

  it("recovers a missing row identity from its current Pi header", () => {
    const manifest = planSessionIdMigration({
      sessionRows: [
        {
          sourceRowId: "header-recovery",
          piSessionFile: {
            path: "/traces/current.jsonl",
            availability: "available",
            headerPiSessionId: PI_B.toUpperCase(),
          },
        },
      ],
    });

    expect(manifest.status).toBe("ready");
    expect(manifest.rows[0]).toMatchObject({
      canonicalSessionId: PI_B,
      disposition: "recover_current_header_id",
    });
  });

  it("requires caller-provided deterministic UUIDs when no current identity can be recovered", () => {
    const incomplete = planSessionIdMigration({
      sessionRows: [{ sourceRowId: "missing-everything" }],
    });
    const planned = planSessionIdMigration({
      sessionRows: [{ sourceRowId: "missing-everything" }],
      plannedUuidsBySourceRowId: { "missing-everything": PLANNED },
    });

    expect(incomplete.status).toBe("blocked");
    expect(incomplete.findings).toContainEqual(
      expect.objectContaining({ kind: "unclassified_session", severity: "blocking" }),
    );
    expect(planned.status).toBe("ready");
    expect(planned.rows[0]).toMatchObject({
      canonicalSessionId: PLANNED,
      disposition: "use_planned_uuid",
    });
  });

  it("blocks an unavailable declared current trace while preserving historical unavailability as warning evidence", () => {
    const manifest = planSessionIdMigration({
      sessionRows: [
        {
          sourceRowId: "wrapper-a",
          piSessionId: PI_A,
          piSessionFile: {
            path: "/traces/current-missing.jsonl",
            availability: "unavailable",
            headerStatus: "unavailable",
          },
          piSessionFiles: [
            {
              path: "/traces/historical-missing.jsonl",
              availability: "unavailable",
              headerStatus: "unavailable",
            },
          ],
        },
      ],
    });

    expect(manifest.status).toBe("blocked");
    expect(manifest.findings).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          kind: "unclassified_trace",
          severity: "blocking",
          detail: "declared current trace is unavailable",
        }),
        expect.objectContaining({
          kind: "unclassified_trace",
          severity: "warning",
          location: "session-row:wrapper-a:historical-file:/traces/historical-missing.jsonl",
        }),
      ]),
    );
  });

  it("fails closed for contradictory current trace availability and header status", () => {
    const manifest = planSessionIdMigration({
      sessionRows: [
        {
          sourceRowId: "wrapper-a",
          piSessionId: PI_A,
          piSessionFile: {
            path: "/traces/contradictory.jsonl",
            availability: "available",
            headerStatus: "unavailable",
          },
        },
      ],
    });

    expect(manifest.status).toBe("blocked");
    expect(manifest.findings).toContainEqual(
      expect.objectContaining({
        kind: "unclassified_trace",
        severity: "blocking",
        location: "session-row:wrapper-a:current-file:/traces/contradictory.jsonl",
      }),
    );
  });

  it("fails closed for contradictory historical trace availability and header status", () => {
    const manifest = planSessionIdMigration({
      sessionRows: [
        {
          sourceRowId: "wrapper-a",
          piSessionId: PI_A,
          piSessionFiles: [
            {
              path: "/traces/historical-contradictory.jsonl",
              availability: "available",
              headerStatus: "unavailable",
            },
          ],
        },
      ],
    });

    expect(manifest.status).toBe("blocked");
    expect(manifest.findings).toContainEqual(
      expect.objectContaining({
        kind: "unclassified_trace",
        severity: "blocking",
        location: "session-row:wrapper-a:historical-file:/traces/historical-contradictory.jsonl",
        detail: "historical trace availability and header status contradict",
      }),
    );
  });

  it("blocks a trace marked valid when it does not carry a valid header UUID", () => {
    const manifest = planSessionIdMigration({
      sessionRows: [
        {
          sourceRowId: "wrapper-a",
          piSessionId: PI_A,
          piSessionFile: {
            path: "/traces/missing-header-uuid.jsonl",
            availability: "available",
            headerStatus: "valid",
          },
          piSessionFiles: [
            {
              path: "/traces/historical-invalid-header-uuid.jsonl",
              availability: "available",
              headerStatus: "valid",
              headerPiSessionId: "not-a-uuid",
            },
          ],
        },
      ],
    });

    expect(manifest.status).toBe("blocked");
    expect(manifest.findings).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          kind: "unclassified_trace",
          severity: "blocking",
          location: "session-row:wrapper-a:current-file:/traces/missing-header-uuid.jsonl",
        }),
        expect.objectContaining({
          kind: "unclassified_trace",
          severity: "blocking",
          location:
            "session-row:wrapper-a:historical-file:/traces/historical-invalid-header-uuid.jsonl",
        }),
      ]),
    );
  });

  it("reports available and unavailable historical identities without creating archival rows", () => {
    const manifest = planSessionIdMigration({
      sessionRows: [
        {
          sourceRowId: "multi-file-wrapper",
          piSessionId: PI_A,
          piSessionFile: {
            path: "/traces/current.jsonl",
            availability: "available",
            headerPiSessionId: PI_A,
          },
          piSessionFiles: [
            {
              path: "/traces/old-available.jsonl",
              availability: "available",
              headerPiSessionId: PI_B,
            },
            {
              path: "/traces/old-unavailable.jsonl",
              availability: "unavailable",
              headerPiSessionId: PI_C,
            },
            {
              path: "/traces/same-identity.jsonl",
              availability: "available",
              headerPiSessionId: PI_A,
            },
            { path: "/traces/old-unattributed-available.jsonl", availability: "available" },
            { path: "/traces/old-unattributed-unavailable.jsonl", availability: "unavailable" },
          ],
        },
      ],
    });

    expect(manifest.status).toBe("ready");
    expect(manifest.rows).toHaveLength(1);
    expect(manifest.historicalIdentityLosses).toEqual([
      {
        sourceRowId: "multi-file-wrapper",
        canonicalSessionId: PI_A,
        discardedIdentityCount: 2,
        availableTraceCount: 2,
        unavailableTraceCount: 2,
        attributedAvailableTraceCount: 1,
        attributedUnavailableTraceCount: 1,
        unattributedHistoricalTraceCount: 2,
        unattributedHistoricalTraces: [
          { path: "/traces/old-unattributed-available.jsonl", availability: "available" },
          { path: "/traces/old-unattributed-unavailable.jsonl", availability: "unavailable" },
        ],
        unattributedAvailableTracePaths: ["/traces/old-unattributed-available.jsonl"],
        unattributedUnavailableTracePaths: ["/traces/old-unattributed-unavailable.jsonl"],
        combinedHistoryVisibilityLost: true,
        discardedIdentities: [
          {
            piSessionId: PI_B,
            availableTracePaths: ["/traces/old-available.jsonl"],
            unavailableTracePaths: [],
          },
          {
            piSessionId: PI_C,
            availableTracePaths: [],
            unavailableTracePaths: ["/traces/old-unavailable.jsonl"],
          },
        ],
      },
    ]);
    expect(manifest.findings).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ kind: "unclassified_trace", severity: "warning" }),
      ]),
    );
    expect(manifest.plannedOperations.sessionRows).toEqual([
      { kind: "rekey_session_row", sourceRowId: "multi-file-wrapper", targetSessionId: PI_A },
    ]);
  });

  it("fails closed for required unclassified or dangling references", () => {
    const manifest = planSessionIdMigration({
      sessionRows: [{ sourceRowId: "known", piSessionId: PI_A }],
      references: [
        {
          location: "reference:unknown-shape",
          sourceSessionId: "known",
          classification: "unclassified",
          policy: "rewrite",
        },
        {
          location: "reference:orphan",
          sourceSessionId: "missing-row",
          classification: "classified",
          policy: "rewrite",
        },
      ],
    });

    expect(manifest.status).toBe("blocked");
    expect(manifest.plannedOperations.references.map((reference) => reference.outcome)).toEqual([
      "dangling",
      "unclassified",
    ]);
    expect(manifest.findings).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ kind: "unclassified_reference", severity: "blocking" }),
        expect.objectContaining({ kind: "dangling_reference", severity: "blocking" }),
      ]),
    );
  });

  it("audits every caller UUID assignment instead of silently discarding one", () => {
    const manifest = planSessionIdMigration({
      sessionRows: [
        { sourceRowId: "stored", piSessionId: PI_A },
        { sourceRowId: "needs-assignment" },
        { sourceRowId: "needs-invalid" },
      ],
      plannedUuidsBySourceRowId: {
        "needs-assignment": PI_B,
        "needs-invalid": "not-a-uuid",
        stored: PI_C,
        missing: PI_A,
      },
    });

    expect(manifest.status).toBe("blocked");
    expect(manifest.rows.find((row) => row.sourceRowId === "needs-assignment")).toMatchObject({
      canonicalSessionId: PI_B,
      disposition: "use_planned_uuid",
    });
    expect(manifest.findings).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          kind: "invalid_planned_uuid_assignment",
          location: "planned-uuid:stored",
        }),
        expect.objectContaining({
          kind: "invalid_planned_uuid_assignment",
          location: "planned-uuid:missing",
        }),
        expect.objectContaining({
          kind: "invalid_planned_uuid_assignment",
          location: "planned-uuid:needs-invalid",
        }),
      ]),
    );
  });

  it("does not let observe-only policy downgrade unclassified evidence", () => {
    const manifest = planSessionIdMigration({
      sessionRows: [{ sourceRowId: "known", piSessionId: PI_A }],
      references: [
        {
          location: "historical:malformed",
          classification: "unclassified",
          policy: "observe_only",
        },
      ],
    });

    expect(manifest.status).toBe("blocked");
    expect(manifest.findings).toContainEqual(
      expect.objectContaining({
        kind: "unclassified_reference",
        severity: "blocking",
        location: "historical:malformed",
      }),
    );
  });

  it("records observe-only references without planning a rewrite or blocking dangling history", () => {
    const manifest = planSessionIdMigration({
      sessionRows: [{ sourceRowId: "known", piSessionId: PI_A }],
      references: [
        {
          location: "historical:run",
          sourceSessionId: "removed-session",
          classification: "classified",
          policy: "observe_only",
        },
      ],
    });

    expect(manifest.status).toBe("ready");
    expect(manifest.plannedOperations.references).toEqual([
      {
        location: "historical:run",
        sourceSessionId: "removed-session",
        policy: "observe_only",
        outcome: "observe_only",
      },
    ]);
    expect(manifest.findings).toEqual([
      expect.objectContaining({
        kind: "dangling_reference",
        severity: "warning",
        location: "historical:run",
      }),
    ]);
  });

  it("blocks every stale observation/policy combination outside the reference evidence matrix", () => {
    const invalidReferences = [
      {
        location: "invalid:classified-rewrite-stale",
        sourceSessionId: "known",
        classification: "classified",
        policy: "rewrite",
        observation: "stale",
      },
      {
        location: "invalid:unclassified-rewrite-stale",
        sourceSessionId: "known",
        classification: "unclassified",
        policy: "rewrite",
        observation: "stale",
      },
      {
        location: "invalid:unclassified-observe-stale",
        sourceSessionId: "known",
        classification: "unclassified",
        policy: "observe_only",
        observation: "stale",
      },
    ] as unknown as readonly SessionIdMigrationReferenceInput[];

    for (const reference of invalidReferences) {
      const manifest = planSessionIdMigration({
        sessionRows: [{ sourceRowId: "known", piSessionId: PI_A }],
        references: [reference],
      });

      expect(manifest.status).toBe("blocked");
      expect(manifest.findings).toContainEqual(
        expect.objectContaining({
          kind: "invalid_reference_evidence",
          severity: "blocking",
          location: reference.location,
        }),
      );
      expect(manifest.plannedOperations.references).toEqual([
        expect.objectContaining({
          location: reference.location,
          policy: reference.policy,
          outcome: "unclassified",
        }),
      ]);
    }
  });

  it("is deterministic and does not mutate frozen caller evidence", () => {
    const input = freezeDeep({
      sessionRows: [
        { sourceRowId: "b", piSessionId: PI_B },
        { sourceRowId: "a", piSessionId: PI_A },
      ],
      references: [
        { location: "z", sourceSessionId: "b", classification: "classified", policy: "rewrite" },
        { location: "a", sourceSessionId: "a", classification: "classified", policy: "rewrite" },
      ],
    } satisfies SessionIdMigrationPlannerInput);
    const before = JSON.stringify(input);

    const first = planSessionIdMigration(input);
    const second = planSessionIdMigration(input);

    expect(first).toEqual(second);
    expect(JSON.stringify(input)).toBe(before);
    expect(first.metadata.readinessScope).toBe("inventoried_partial_scope_only");
    expect(first.rows.map((row) => row.sourceRowId)).toEqual(["a", "b"]);
    expect(first.plannedOperations.references.map((reference) => reference.location)).toEqual([
      "a",
      "z",
    ]);
  });
});


const LIVE_FILE = (pi: string, stamp: string) =>
  `/Users/chenda/.pi/agent/sessions/--Users-chenda-workspace-oppi--/${stamp}_${pi}.jsonl`;

/** Field-level fixtures for the six live production duplicate groups. */
const LIVE_DUPLICATE_GROUPS: Array<{
  decisionId: string;
  survivorSourceRowId: string;
  createdAt: number;
  lastActivity: number;
  messageCount: number;
  members: SessionIdMigrationMergeMember[];
}> = [
  {
    decisionId: "duplicate-review-2026-08-17-01",
    survivorSourceRowId: "cGEcSBwD",
    createdAt: 1777663540815,
    lastActivity: 1777697323828,
    messageCount: 0,
    members: [
      {
        sourceRowId: "aEY7oaE8",
        targetSessionId: "019de4be-23a6-72f8-a9b1-e5fbf250a9d9",
        createdAt: 1777663540815,
        lastActivity: 1777663569152,
        name: "we need fix our repo after your identiy change and restarted my server my ios cl",
        messageCount: 0,
        piSessionFile: LIVE_FILE("019de4be-23a6-72f8-a9b1-e5fbf250a9d9", "2026-05-01T18-12-39-463Z"),
        piSessionFiles: [
          LIVE_FILE("019de4be-23a6-72f8-a9b1-e5fbf250a9d9", "2026-05-01T18-12-39-463Z"),
        ],
        workspaceId: "zs1JP9sA",
        runtime: "oppi",
      },
      {
        sourceRowId: "cGEcSBwD",
        targetSessionId: "019de4be-23a6-72f8-a9b1-e5fbf250a9d9",
        createdAt: 1777663540976,
        lastActivity: 1777697323828,
        name: "we need fix our repo after your identiy change and restarted my server my ios cl",
        messageCount: 0,
        piSessionFile: LIVE_FILE("019de4be-23a6-72f8-a9b1-e5fbf250a9d9", "2026-05-01T18-12-39-463Z"),
        piSessionFiles: [
          LIVE_FILE("019de4be-23a6-72f8-a9b1-e5fbf250a9d9", "2026-05-01T18-12-39-463Z"),
        ],
        workspaceId: "zs1JP9sA",
        runtime: "oppi",
      },
    ],
  },
  {
    decisionId: "duplicate-review-2026-08-17-02",
    survivorSourceRowId: "qGirfKrZ",
    createdAt: 1778374217582,
    lastActivity: 1778380481609,
    messageCount: 69,
    members: [
      {
        sourceRowId: "zUGuNLkh",
        targetSessionId: "019e0f5d-13ae-70b1-adb6-a891d7e03335",
        createdAt: 1778374217582,
        lastActivity: 1778375704158,
        name: "Review Codex CLI Server Architecture",
        messageCount: 69,
        piSessionFile: LIVE_FILE("019e0f5d-13ae-70b1-adb6-a891d7e03335", "2026-05-10T00-50-18-670Z"),
        piSessionFiles: [
          LIVE_FILE("019e0f5d-13ae-70b1-adb6-a891d7e03335", "2026-05-10T00-50-18-670Z"),
        ],
        workspaceId: "zs1JP9sA",
        runtime: "oppi",
      },
      {
        sourceRowId: "qGirfKrZ",
        targetSessionId: "019e0f5d-13ae-70b1-adb6-a891d7e03335",
        createdAt: 1778376548700,
        lastActivity: 1778380481609,
        name: "Let's do a review of the Codex CLI app server. And then review our server backen",
        messageCount: 18,
        piSessionFile: LIVE_FILE("019e0f5d-13ae-70b1-adb6-a891d7e03335", "2026-05-10T00-50-18-670Z"),
        piSessionFiles: [
          LIVE_FILE("019e0f5d-13ae-70b1-adb6-a891d7e03335", "2026-05-10T00-50-18-670Z"),
        ],
        workspaceId: "zs1JP9sA",
        runtime: "oppi",
      },
    ],
  },
  {
    decisionId: "duplicate-review-2026-08-17-03",
    survivorSourceRowId: "Vg30ff82",
    createdAt: 1778374352095,
    lastActivity: 1778382478124,
    messageCount: 146,
    members: [
      {
        sourceRowId: "84RzdI-D",
        targetSessionId: "019e0f5f-2322-748c-8041-79df58059cef",
        createdAt: 1778374352095,
        lastActivity: 1778375704159,
        name: "Investigate Codecs Usage Limit Implementation",
        messageCount: 146,
        piSessionFile: LIVE_FILE("019e0f5f-2322-748c-8041-79df58059cef", "2026-05-10T00-52-33-699Z"),
        piSessionFiles: [
          LIVE_FILE("019e0f5f-2322-748c-8041-79df58059cef", "2026-05-10T00-52-33-699Z"),
        ],
        workspaceId: "zs1JP9sA",
        runtime: "oppi",
      },
      {
        sourceRowId: "Vg30ff82",
        targetSessionId: "019e0f5f-2322-748c-8041-79df58059cef",
        createdAt: 1778375805675,
        lastActivity: 1778382478124,
        name: "Continue Session",
        messageCount: 45,
        piSessionFile: LIVE_FILE("019e0f5f-2322-748c-8041-79df58059cef", "2026-05-10T00-52-33-699Z"),
        piSessionFiles: [
          LIVE_FILE("019e0f5f-2322-748c-8041-79df58059cef", "2026-05-10T00-52-33-699Z"),
        ],
        workspaceId: "zs1JP9sA",
        runtime: "oppi",
      },
    ],
  },
  {
    decisionId: "duplicate-review-2026-08-17-04",
    survivorSourceRowId: "FVj1bvDF",
    createdAt: 1778480711661,
    lastActivity: 1778561572502,
    messageCount: 50,
    members: [
      {
        sourceRowId: "Dit94-YP",
        targetSessionId: "019e15b6-0ee3-744d-b0b0-5db2e1180f84",
        createdAt: 1778480711661,
        lastActivity: 1778484980716,
        name: "Fix Write Tool Markdown Streaming",
        messageCount: 50,
        piSessionFile: LIVE_FILE("019e15b6-0ee3-744d-b0b0-5db2e1180f84", "2026-05-11T06-25-13-443Z"),
        piSessionFiles: [
          LIVE_FILE("019e15b6-0ee3-744d-b0b0-5db2e1180f84", "2026-05-11T06-25-13-443Z"),
        ],
        workspaceId: "zs1JP9sA",
        runtime: "oppi",
      },
      {
        sourceRowId: "FVj1bvDF",
        targetSessionId: "019e15b6-0ee3-744d-b0b0-5db2e1180f84",
        createdAt: 1778559305446,
        lastActivity: 1778561572502,
        messageCount: 0,
        piSessionFile: LIVE_FILE("019e15b6-0ee3-744d-b0b0-5db2e1180f84", "2026-05-11T06-25-13-443Z"),
        piSessionFiles: [
          LIVE_FILE("019e15b6-0ee3-744d-b0b0-5db2e1180f84", "2026-05-11T06-25-13-443Z"),
        ],
        workspaceId: "zs1JP9sA",
        runtime: "oppi",
      },
    ],
  },
  {
    decisionId: "duplicate-review-2026-08-17-05",
    survivorSourceRowId: "6Jd8wqJj",
    createdAt: 1778481227557,
    lastActivity: 1778555496945,
    messageCount: 428,
    members: [
      {
        sourceRowId: "frCHakF5",
        targetSessionId: "019e15bd-eda3-76a5-861c-33e0719bf583",
        createdAt: 1778481227557,
        lastActivity: 1778498452349,
        name: "Review HTTP Snapshot Session-List Plan",
        messageCount: 428,
        piSessionFile: LIVE_FILE("019e15bd-eda3-76a5-861c-33e0719bf583", "2026-05-11T06-33-49-220Z"),
        piSessionFiles: [
          LIVE_FILE("019e15bd-eda3-76a5-861c-33e0719bf583", "2026-05-11T06-33-49-220Z"),
        ],
        workspaceId: "zs1JP9sA",
        runtime: "oppi",
      },
      {
        sourceRowId: "6Jd8wqJj",
        targetSessionId: "019e15bd-eda3-76a5-861c-33e0719bf583",
        createdAt: 1778555132014,
        lastActivity: 1778555496945,
        name: "i want you review TODO-4971f121 — HTTP snapshot session-list plan closely for ou",
        messageCount: 0,
        piSessionFile: LIVE_FILE("019e15bd-eda3-76a5-861c-33e0719bf583", "2026-05-11T06-33-49-220Z"),
        piSessionFiles: [
          LIVE_FILE("019e15bd-eda3-76a5-861c-33e0719bf583", "2026-05-11T06-33-49-220Z"),
        ],
        workspaceId: "zs1JP9sA",
        runtime: "oppi",
      },
    ],
  },
  {
    decisionId: "duplicate-review-2026-08-17-06",
    survivorSourceRowId: "evanRcWN",
    createdAt: 1778504591079,
    lastActivity: 1778612312446,
    messageCount: 979,
    members: [
      {
        sourceRowId: "UnZATPix",
        targetSessionId: "019e1722-6c54-7595-a330-8ef6ffa5f14c",
        createdAt: 1778504591079,
        lastActivity: 1778548674979,
        name: "Review Session frCHakF5",
        messageCount: 786,
        piSessionFile: LIVE_FILE("019e1722-6c54-7595-a330-8ef6ffa5f14c", "2026-05-11T13-03-12-468Z"),
        piSessionFiles: [
          LIVE_FILE("019e1722-6c54-7595-a330-8ef6ffa5f14c", "2026-05-11T13-03-12-468Z"),
        ],
        workspaceId: "zs1JP9sA",
        runtime: "oppi",
      },
      {
        sourceRowId: "evanRcWN",
        targetSessionId: "019e1722-6c54-7595-a330-8ef6ffa5f14c",
        createdAt: 1778551217691,
        lastActivity: 1778612312446,
        name: "review session let’s pick up where it’s left frCHakF5",
        messageCount: 979,
        piSessionFile: LIVE_FILE("019e1722-6c54-7595-a330-8ef6ffa5f14c", "2026-05-11T13-03-12-468Z"),
        piSessionFiles: [
          LIVE_FILE("019e1722-6c54-7595-a330-8ef6ffa5f14c", "2026-05-11T13-03-12-468Z"),
        ],
        workspaceId: "zs1JP9sA",
        runtime: "oppi",
      },
    ],
  },
];

describe("field-authority duplicate merge", () => {
  it("encodes survivor and merged-field authority for the six live production groups", () => {
    for (const group of LIVE_DUPLICATE_GROUPS) {
      const result = decideFieldAuthorityDuplicateMerge(group.members, group.decisionId);
      expect(result.ok).toBe(true);
      if (!result.ok) continue;
      expect(result.disposition).toEqual({
        targetSessionId: group.members[0]?.targetSessionId,
        survivorSourceRowId: group.survivorSourceRowId,
        decisionId: group.decisionId,
        reasonId: FIELD_AUTHORITY_DUPLICATE_REASON_ID,
      });
      expect(result.merged.createdAt).toBe(group.createdAt);
      expect(result.merged.lastActivity).toBe(group.lastActivity);
      expect(result.merged.messageCount).toBe(group.messageCount);
      expect(result.merged.workspaceId).toBe("zs1JP9sA");
      expect(result.merged.runtime).toBe("oppi");
      expect(result.merged.piSessionFiles).toEqual(group.members[0]?.piSessionFiles);
    }
  });

  it("does not let the planner invent a survivor when those six groups lack dispositions", () => {
    const manifest = planSessionIdMigration({
      sessionRows: LIVE_DUPLICATE_GROUPS.flatMap((group) =>
        group.members.map((member) => ({
          sourceRowId: member.sourceRowId,
          piSessionId: member.targetSessionId,
        })),
      ),
    });

    expect(manifest.status).toBe("blocked");
    expect(manifest.duplicateGroups).toHaveLength(6);
    expect(manifest.duplicateGroups.every((group) => group.resolution === "unresolved")).toBe(true);
    expect(manifest.findings.filter((finding) => finding.kind === "unresolved_duplicate_disposition")).toHaveLength(
      6,
    );
  });

  it("fails closed when current files or workspace identity disagree", () => {
    const base = LIVE_DUPLICATE_GROUPS[0]!.members;
    const fileClash = decideFieldAuthorityDuplicateMerge(
      [
        base[0]!,
        { ...base[1]!, piSessionFile: "/other.jsonl" },
      ],
      "duplicate-review-2026-08-17-file-clash",
    );
    const workspaceClash = decideFieldAuthorityDuplicateMerge(
      [
        base[0]!,
        { ...base[1]!, workspaceId: "other" },
      ],
      "duplicate-review-2026-08-17-workspace-clash",
    );

    expect(fileClash).toEqual({
      ok: false,
      detail: "members disagree on the current canonical Pi file",
    });
    expect(workspaceClash).toEqual({
      ok: false,
      detail: "members disagree on nonempty workspaceId",
    });
  });

  it("prefers the unique current-file holder before lastActivity", () => {
    const result = decideFieldAuthorityDuplicateMerge(
      [
        {
          sourceRowId: "older-with-file",
          targetSessionId: PI_A,
          createdAt: 1,
          lastActivity: 1,
          piSessionFile: "/current.jsonl",
        },
        {
          sourceRowId: "newer-without-file",
          targetSessionId: PI_A,
          createdAt: 2,
          lastActivity: 9,
        },
      ],
      "duplicate-review-canonical-file",
    );

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.disposition.survivorSourceRowId).toBe("older-with-file");
    expect(result.merged.createdAt).toBe(1);
    expect(result.merged.lastActivity).toBe(9);
    expect(result.merged.piSessionFile).toBe("/current.jsonl");
  });

  it("unions unique historical files and warnings onto the latest-activity survivor", () => {
    const result = decideFieldAuthorityDuplicateMerge(
      [
        {
          sourceRowId: "older",
          targetSessionId: PI_A,
          createdAt: 10,
          lastActivity: 20,
          piSessionFile: "/current.jsonl",
          piSessionFiles: ["/current.jsonl", "/old-a.jsonl"],
          warnings: ["warn-a"],
          name: "older-name",
        },
        {
          sourceRowId: "newer",
          targetSessionId: PI_A,
          createdAt: 11,
          lastActivity: 30,
          piSessionFile: "/current.jsonl",
          piSessionFiles: ["/current.jsonl", "/old-b.jsonl"],
          warnings: ["warn-b", "warn-a"],
          name: "newer-name",
        },
      ],
      "duplicate-review-union",
    );

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.disposition.survivorSourceRowId).toBe("newer");
    expect(result.merged.name).toBe("newer-name");
    expect(result.merged.piSessionFiles).toEqual(["/current.jsonl", "/old-a.jsonl", "/old-b.jsonl"]);
    expect(result.merged.warnings).toEqual(["warn-a", "warn-b"]);
  });
});
