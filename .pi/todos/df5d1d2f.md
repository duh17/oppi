{
  "id": "df5d1d2f",
  "title": "REST API for skill CRUD",
  "tags": [
    "oppi",
    "skills",
    "server",
    "api"
  ],
  "status": "done",
  "created_at": "2026-02-14T05:00:44.012Z"
}

## Goal
Expose skills via REST so iOS UI and agents can browse, create, edit, and delete skills.

## Endpoints
```
GET    /skills                    — list all skills (built-in + user)
GET    /skills/:name              — skill detail (SKILL.md content, files, metadata)
GET    /skills/:name/files/*path  — read a specific file from a skill
POST   /skills                    — create user skill (multipart or JSON with files)
PUT    /skills/:name              — update user skill (SKILL.md + scripts)
DELETE /skills/:name              — delete user skill
```

## Response Shape
```json
{
  "name": "search",
  "description": "Private web search via SearXNG",
  "builtIn": true,
  "containerSafe": true,
  "hasScripts": true,
  "files": ["SKILL.md", "scripts/search"],
  "enabledIn": ["workspace-1", "workspace-2"]
}
```

## Dependencies
- TODO-334eb82e (Live SkillRegistry) — needs reactive registry for catalog
- Existing UserSkillStore handles disk I/O

## Notes
- Built-in skills are read-only via API (can't PUT/DELETE)
- User skills stored in `~/.config/oppi/skills/<userId>/<name>/`
- Auth: require valid bearer token (existing auth middleware)
- iOS will use these endpoints for the skill catalog screen
