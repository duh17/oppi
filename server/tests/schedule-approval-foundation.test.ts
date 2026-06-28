import { readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { decideScheduledMutation } from "../src/schedule-approval.js";
import { openDatabase } from "../src/sqlite-compat.js";
import { SessionSqliteStore } from "../src/storage/session-sqlite-store.js";
import type {
  AgentSchedule,
  AgentScheduleRun,
  ScheduleApprovalRef,
  ServerAgentExtensionAuditEventEnvelope,
} from "../src/types.js";

function sourceFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return sourceFiles(path);
    return entry.isFile() && path.endsWith(".ts") ? [path] : [];
  });
}

describe("schedule approval foundation", () => {
  it("creates an append-only audit envelope table for extension approval events", () => {
    const dataDir = join(tmpdir(), `oppi-schedule-audit-${process.pid}-${Date.now()}`);
    let store: SessionSqliteStore | undefined;

    try {
      store = new SessionSqliteStore(dataDir);
      store.close();
      store = undefined;

      const db = openDatabase(join(dataDir, "session-state.db"));
      try {
        const columns = db
          .prepare("PRAGMA table_info(server_agent_extension_audit_events)")
          .all() as Array<{
          name: string;
        }>;
        expect(columns.map((column) => column.name)).toEqual([
          "id",
          "created_at",
          "workspace_id",
          "schedule_id",
          "run_id",
          "session_id",
          "event_type",
          "approval_ref_id",
          "extension_scope_id",
          "extension_display_name",
          "display_json",
          "provenance_json",
          "envelope_json",
        ]);
      } finally {
        db.close();
      }
    } finally {
      store?.close();
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("does not introduce a generic grant type or table in server source", () => {
    const srcRoot = join(process.cwd(), "src");
    const sourceText = sourceFiles(srcRoot)
      .map((path) => readFileSync(path, "utf8"))
      .join("\n");

    expect(sourceText).not.toContain(["Server", "Agent", "Grant"].join(""));
    expect(sourceText).not.toContain("server_agent_grants");
  });

  it("fails closed for scheduled and background mutations without an accepted opaque ref", () => {
    expect(decideScheduledMutation({ origin: "scheduled", approvalRefs: [], nowMs: 1000 })).toEqual(
      {
        allowed: false,
        reason: "missing_accepted_approval_ref",
      },
    );
    expect(
      decideScheduledMutation({
        origin: "background",
        approvalRefs: [{ id: "ref-rejected", status: "rejected" }],
        nowMs: 1000,
      }),
    ).toEqual({ allowed: false, reason: "missing_accepted_approval_ref" });
  });

  it("represents schedules, runs, and audit envelopes with opaque approval refs", () => {
    const acceptedRef = {
      id: "ref-accepted",
      status: "accepted",
      acceptedAt: 900,
      expiresAt: 1100,
      display: { extensionDisplayName: "Ask", extensionScopeId: "repo:ask" },
      provenance: { requestId: "ui-1", sessionId: "sess-1" },
    } satisfies ScheduleApprovalRef;
    const approvalRefs: ScheduleApprovalRef[] = [acceptedRef];

    const schedule = {
      id: "schedule-1",
      workspaceId: "ws-1",
      prompt: "Run checks",
      enabled: true,
      createdAt: 1,
      updatedAt: 1,
      approvalRefs,
    } satisfies AgentSchedule;
    const run = {
      id: "run-1",
      scheduleId: schedule.id,
      workspaceId: schedule.workspaceId,
      status: "queued",
      createdAt: 2,
      updatedAt: 2,
      approvalRefs: schedule.approvalRefs,
    } satisfies AgentScheduleRun;
    const envelope = {
      id: "audit-1",
      createdAt: 3,
      eventType: "approval_ref.accepted",
      workspaceId: schedule.workspaceId,
      scheduleId: schedule.id,
      runId: run.id,
      approvalRefId: acceptedRef.id,
      display: acceptedRef.display,
      provenance: acceptedRef.provenance,
    } satisfies ServerAgentExtensionAuditEventEnvelope;

    expect(envelope.approvalRefId).toBe("ref-accepted");
    expect(decideScheduledMutation({ origin: "scheduled", approvalRefs, nowMs: 1000 })).toEqual({
      allowed: true,
      reason: "accepted_approval_ref",
      approvalRefId: "ref-accepted",
    });
    expect(decideScheduledMutation({ origin: "scheduled", approvalRefs, nowMs: 1200 })).toEqual({
      allowed: false,
      reason: "expired_approval_ref",
      approvalRefId: "ref-accepted",
    });
  });
});
