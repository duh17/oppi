# Session Management API

REST endpoints for managing oppi sessions outside of `dispatch.mjs`.

## Authentication

```bash
TOKEN=$(jq -r .token ~/.config/oppi/config.json)
AUTH="Authorization: Bearer $TOKEN"
BASE="http://127.0.0.1:7749"
```

## Endpoints

### List Workspaces
```bash
curl -s "$BASE/workspaces" -H "$AUTH" | jq '.workspaces[] | {id, name}'
```

### List Models
```bash
curl -s "$BASE/models" -H "$AUTH" | jq '.models[].id'
```

### Check Session Status
```bash
curl -s "$BASE/workspaces/$WS/sessions/$SID" -H "$AUTH" | jq '.session.status'
```

Status values: `idle`, `starting`, `busy`, `ready`, `stopped`, `error`

### Stop a Session
```bash
curl -s -X POST "$BASE/workspaces/$WS/sessions/$SID/stop" -H "$AUTH"
```

### Delete a Session
```bash
curl -s -X DELETE "$BASE/workspaces/$WS/sessions/$SID" -H "$AUTH"
```
