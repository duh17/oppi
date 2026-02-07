{
  "id": "bdffb4b5",
  "title": "P2: Skill promotion safety gate (pending → approved)",
  "tags": [
    "pi-remote",
    "skills",
    "security",
    "workflow",
    "phase-2"
  ],
  "status": "backlog",
  "created_at": "2026-02-07T16:27:14.198Z"
}

## Context
Product direction is organic skill growth with phone curation. New skills created during sessions should not auto-activate globally without review.

## Goal
Introduce approval workflow for promoted skills before they can be loaded into future sessions.

## Acceptance Criteria
- Skill save/promotion creates `pending` record by default.
- Phone approval required to transition `pending -> approved`.
- Only approved (and container-safe, where applicable) skills are eligible for session load.
- Persist approval metadata (who/when/source session).
- Add deny/archive path for rejected skills.
- API + iOS surface for reviewing pending promotions.

## Related existing TODOs
- TODO-eabe2bf3 (skill storage + CRUD)
- TODO-d6c60004 (load user skills into sessions)
- TODO-a55a58d6 (save skill from workspace)

## Note
Can be implemented as status field on skill records in v1 (no full versioning required).
