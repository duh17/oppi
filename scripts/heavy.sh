#!/usr/bin/env bash
# Machine-wide counting semaphore for heavy commands, so ten agents cannot start ten cold
# Xcode builds and three full server suites at once (load 100-175 on a 32-core Mac Studio).
#
#   scripts/heavy.sh <class> -- <command...>
#
# Classes and slot counts (env override in parentheses):
#   xcode-build  2   build / build-for-testing phases      (OPPI_HEAVY_XCODE_BUILD)
#   server-full  1   full vitest suite                     (OPPI_HEAVY_SERVER_FULL)
#   ui-suite     2   XCUITest / E2E runs                   (OPPI_HEAVY_UI_SUITE)
#
# Other env: OPPI_HEAVY_DIR (slot files, default ~/Library/Caches/oppi-heavy),
# OPPI_HEAVY_POLL (seconds between retries while every slot is busy, default 5),
# OPPI_HEAVY_PARENT_PID (a waiting job gives up with status 143 once this process is gone, so
# a killed pre-push hook does not leave queued jobs that later run for nobody; a waiting job
# also gives up when it has been orphaned to init). A free slot runs regardless.
#
# Fairness: there is no queue. A waiter retries every OPPI_HEAVY_POLL seconds and a newcomer
# tries at once, so a newcomer can take a slot that freed between a waiter's polls.
#
# The kernel holds each slot through lockf(1) exactly as long as the command runs; a crashed
# holder frees its slot at once, so there is no stale-lock takeover logic. The command's exit
# status is passed through. Nested use of a class already held by an ancestor runs directly.
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: heavy.sh <class> -- <command...>" >&2; exit 2; }
class="$1"; shift
[[ "${1:-}" == "--" ]] && shift
[[ $# -ge 1 ]] || { echo "heavy.sh: missing command" >&2; exit 2; }
case "$class" in
  xcode-build) slots="${OPPI_HEAVY_XCODE_BUILD:-2}" ;;
  server-full) slots="${OPPI_HEAVY_SERVER_FULL:-1}" ;;
  ui-suite) slots="${OPPI_HEAVY_UI_SUITE:-2}" ;;
  *) echo "heavy.sh: unknown class $class" >&2; exit 2 ;;
esac
[[ "$slots" =~ ^[1-9][0-9]*$ ]] || { echo "heavy.sh: invalid slot count '$slots' for $class" >&2; exit 2; }
# Nested use (sim-pool inside a pre-push lane that already holds a slot) must not deadlock.
if [[ "${OPPI_HEAVY_HELD:-}" == *":$class:"* ]]; then exec "$@"; fi
dir="${OPPI_HEAVY_DIR:-$HOME/Library/Caches/oppi-heavy}"; mkdir -p "$dir"
export OPPI_HEAVY_HELD="${OPPI_HEAVY_HELD:-:}$class:"
announced=0
started="$(mktemp -u -t oppi-heavy)"
trap 'rm -f "$started"' EXIT
parent_gone() {
  if [[ -n "${OPPI_HEAVY_PARENT_PID:-}" ]]; then ! kill -0 "$OPPI_HEAVY_PARENT_PID" 2>/dev/null; return; fi
  [[ "$(ps -o ppid= -p $$ | tr -d ' ')" == "1" ]]
}
while true; do
  for ((i = 0; i < slots; i++)); do
    # -t 0: try without waiting. lockf exits 75 when the slot is busy, but the command may
    # also exit 75, so the command marks that it started before running.
    set +e
    /usr/bin/lockf -s -k -t 0 "$dir/$class.$i" /bin/bash -c ': > "$0"; exec "$@"' "$started" "$@"
    rc=$?
    set -e
    [[ $rc -eq 75 && ! -e "$started" ]] || exit $rc
  done
  if [[ $announced -eq 0 ]]; then
    echo "[heavy] all $slots '$class' slots busy; waiting" >&2; announced=1
  fi
  # Checked only after a full round of slot attempts failed: a free slot always runs, and only
  # a job that would keep waiting gives up.
  if parent_gone; then echo "[heavy] caller is gone; not starting '$class' job" >&2; exit 143; fi
  sleep "${OPPI_HEAVY_POLL:-5}"
done
