{
  "id": "eabe2bf3",
  "title": "P2: Server — skill storage + CRUD API",
  "tags": [
    "pi-remote",
    "server",
    "skills",
    "api",
    "phase-2"
  ],
  "status": "backlog",
  "created_at": "2026-02-07T07:42:21.835Z"
}

## Context

Users need to save, list, and delete skills. v1 is simple: a skill is a
directory with SKILL.md. No versioning, no meta.json, no archive state.

Tracker: TODO-992ad1a6

## What to do

### A. Create skills.ts module

New `pi-remote/src/skills.ts`:

**Storage layout** (flat directories, no versioning):
```
~/.pi-remote/skills/
├── _built-in/           # Copied from host, read-only to user
│   ├── searxng/
│   ├── fetch/
│   └── web-browser/
└── <userId>/
    ├── data-viz/
    │   ├── SKILL.md
    │   └── scripts/
    └── training-log/
        ├── SKILL.md
        └── scripts/
```

**Functions:**
- `listSkills(userId)` → `Skill[]` — reads SKILL.md frontmatter for
  name + description. Returns built-in + user skills.
- `getSkill(userId, name)` → `Skill & { files: FileEntry[] }` — metadata
  plus file listing.
- `saveSkill(userId, name, sourceDir)` → copies directory from session
  workspace to persistent storage. Validates: SKILL.md exists, name is
  valid (lowercase, hyphens, 1-64 chars), total size < 100KB, no built-in
  name collision.
- `deleteSkill(userId, name)` → removes directory. Built-ins can't be deleted.
- `getSkillDir(userId, name)` → resolved path for file serving.
- `syncBuiltIns()` → copies built-in skills from host to _built-in/ dir.
  Called at server startup.

**Skill model:**
```typescript
interface Skill {
  name: string;
  description: string;     // from SKILL.md frontmatter
  builtIn: boolean;
  createdAt: string;        // dir mtime for user skills
}
```

Parse SKILL.md frontmatter with a simple regex — just extract the
`description:` line. Don't need a full YAML parser.

### B. Add REST endpoints to server.ts

```
GET    /me/skills
  → { skills: Skill[] }

GET    /me/skills/:name
  → { skill: Skill, files: FileEntry[] }

GET    /me/skills/:name/files/*path
  → file contents (reuse files.ts from TODO-362ce018)

POST   /me/skills
  body: { name, sessionId }
  → Copies /work/<name>/ from session workspace to skill storage
  → { skill: Skill }

DELETE /me/skills/:name
  → 204 on success, 403 for built-ins
```

### C. Validation rules

- Name: `/^[a-z][a-z0-9-]{0,63}$/`
- SKILL.md must exist in source directory
- Total directory size < 100KB
- Can't shadow built-in names
- Path safety: reuse resolveAndValidate from files.ts

## Files

- `pi-remote/src/skills.ts` — NEW: storage, CRUD, validation
- `pi-remote/src/server.ts` — add 5 endpoints
- `pi-remote/src/types.ts` — add Skill interface

## Done when

- `GET /me/skills` returns built-in skills (searxng, fetch, web-browser)
- `POST /me/skills { name: "test", sessionId: "..." }` saves a skill
- `GET /me/skills/test` returns skill metadata + files
- `DELETE /me/skills/test` removes it
- Attempting to save without SKILL.md → 400
- Attempting to shadow "searxng" → 400

---

## Implementation Order: Step 11a

First skills step. Server only, ~1 day. Builds on existing skills.ts (183 lines).
