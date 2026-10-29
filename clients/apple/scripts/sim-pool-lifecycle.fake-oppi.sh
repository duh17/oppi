#!/usr/bin/env bash
# Fake `oppi session list|get` for sim-pool-lifecycle.test.ts, installed as <root>/bin/oppi.
# A shell script for the same reason as the fake xcrun (a Bun script costs a runtime start per call).
#
# <root>/sessions.tsv has one row per session: id, status, idle minutes, then the status and idle
# minutes every call after the first answers with (a session that resumes mid-pass).
dir="$(cd "$(dirname "$0")/.." && pwd)"
counter="$dir/oppi.calls"
call=$(($(cat "$counter" 2>/dev/null || echo 0) + 1))
echo "$call" >"$counter"
now=$(($(date +%s) * 1000))

# Sets status and last for the session $1; fails when there is no such session.
lookup() {
  local id status first_age later_status later_age
  while IFS=$'\t' read -r id status first_age later_status later_age; do
    [ "$id" = "$1" ] || continue
    if [ "$call" -gt 1 ]; then status=$later_status first_age=$later_age; fi
    SESSION_STATUS=$status
    SESSION_LAST=$((now - first_age * 60000))
    return 0
  done <"$dir/sessions.tsv"
  return 1
}

verb=${2:-}
id=${3:-}
if [ "$verb" = list ]; then
  out=""
  while IFS=$'\t' read -r session _; do
    [ -n "$session" ] || continue
    lookup "$session" || continue
    out="$out${out:+,}{\"id\":\"$session\",\"status\":\"$SESSION_STATUS\",\"last_activity\":$SESSION_LAST}"
  done <"$dir/sessions.tsv"
  echo "{\"ok\":true,\"data\":{\"sessions\":[$out]}}"
elif lookup "$id"; then
  echo "{\"ok\":true,\"data\":{\"session\":{\"id\":\"$id\",\"status\":\"$SESSION_STATUS\",\"lastActivity\":$SESSION_LAST}}}"
else
  echo '{"ok":false,"error":{"code":"session_not_found","status":404}}'
fi
