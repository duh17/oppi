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
#   sim-first-boot 1 sim-pool's first boot of a new or erased simulator (OPPI_HEAVY_SIM_FIRST_BOOT)
#
# Other env: OPPI_HEAVY_DIR (slot files, default ~/Library/Caches/oppi-heavy),
# OPPI_HEAVY_POLL (seconds between retries while every slot is busy, default 5),
# OPPI_HEAVY_PARENT_PID (a waiting job gives up with status 143 once this process is gone, so
# a killed pre-push hook does not leave queued jobs that later run for nobody; a waiting job
# also gives up when it has been orphaned to init). A free slot runs regardless, except behind a
# waiting gate job (see Fairness).
#
# Fairness: there is no queue. A waiter retries every OPPI_HEAVY_POLL seconds and a newcomer
# tries at once, so a newcomer can take a slot that freed between a waiter's polls. The land gate
# comes first: a waiting job with LAND_QUEUE_BATCH set (the pre-push hook and batch-gate.ts export
# it) leaves a marker next to the slot files, and while that marker's pid is alive a non-gate
# newcomer for the same class takes no slot and waits behind it. Stale markers are ignored, gate
# jobs never defer to each other or to themselves, and a held class still runs nested use directly.
#
# sim-pool takes xcode-build and sim-first-boot slots itself (clients/apple/scripts/sim-pool-build.ts:
# flock(2) on these same slot files, the same env knobs, the same gate markers), so `sim-pool run`
# needs no heavy.sh wrapper.
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
  sim-first-boot) slots="${OPPI_HEAVY_SIM_FIRST_BOOT:-1}" ;;
  *) echo "heavy.sh: unknown class $class" >&2; exit 2 ;;
esac
[[ "$slots" =~ ^[1-9][0-9]*$ ]] || { echo "heavy.sh: invalid slot count '$slots' for $class" >&2; exit 2; }
# Nested use (a command inside a job that already holds this class) must not deadlock.
if [[ "${OPPI_HEAVY_HELD:-}" == *":$class:"* ]]; then exec "$@"; fi
dir="${OPPI_HEAVY_DIR:-$HOME/Library/Caches/oppi-heavy}"; mkdir -p "$dir"
export OPPI_HEAVY_HELD="${OPPI_HEAVY_HELD:-:}$class:"
announced=0
started="$(mktemp -u -t oppi-heavy)"
# Gate priority (see Fairness): LAND_QUEUE_BATCH marks a land-gate job. While it waits it keeps
# $gate_waiting_dir/$class.$$ fresh, and a non-gate newcomer that sees a live pid there stands aside.
gate_waiting_dir="$dir/gate-waiting"
gate_marker="$gate_waiting_dir/$class.$$"
is_gate=0
if [[ -n "${LAND_QUEUE_BATCH:-}" ]]; then is_gate=1; fi
# True while a gate job waits for this class. A marker whose pid is gone is a killed waiter: not a
# hold, and removed here so the directory cannot grow with them.
gate_waiting() {
  local marker name pid
  for marker in "$gate_waiting_dir/$class".*; do
    if [[ ! -e "$marker" ]]; then continue; fi
    name="${marker##*/}"; pid="${name#"$class".}"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then return 0; fi
    rm -f "$marker"
  done
  return 1
}
trap 'rm -f "$started" "$gate_marker"' EXIT
parent_gone() {
  if [[ -n "${OPPI_HEAVY_PARENT_PID:-}" ]]; then ! kill -0 "$OPPI_HEAVY_PARENT_PID" 2>/dev/null; return; fi
  [[ "$(ps -o ppid= -p $$ | tr -d ' ')" == "1" ]]
}
while true; do
  deferred=0
  if [[ $is_gate -eq 1 ]]; then
    # A gate job announces itself before it looks for a slot and refreshes the marker each round.
    mkdir -p "$gate_waiting_dir"
    printf '%s\n' "$$" > "$gate_marker"
  elif gate_waiting; then
    # A gate job waits for this class: the next free slot is its turn, not ours.
    deferred=1
  fi
  if [[ $deferred -eq 0 ]]; then
    for ((i = 0; i < slots; i++)); do
      # -t 0: try without waiting. lockf exits 75 when the slot is busy, but the command may
      # also exit 75, so the command marks that it started before running. Inside the lock it also
      # drops the gate marker: a gate that holds a slot no longer makes newcomers wait.
      set +e
      /usr/bin/lockf -s -k -t 0 "$dir/$class.$i" /bin/bash -c ': > "$0"; rm -f "$1"; shift; exec "$@"' \
        "$started" "$gate_marker" "$@"
      rc=$?
      set -e
      if [[ $rc -eq 75 && ! -e "$started" ]]; then continue; fi
      exit $rc
    done
  fi
  if [[ $announced -eq 0 ]]; then
    if [[ $deferred -eq 1 ]]; then
      echo "[heavy] a land-gate job is waiting for '$class'; waiting behind it" >&2
    else
      echo "[heavy] all $slots '$class' slots busy; waiting" >&2
    fi
    announced=1
  fi
  # Checked only after a full round of slot attempts failed (or a gate job took our turn): a free
  # slot always runs, and only a job that would keep waiting gives up.
  if parent_gone; then echo "[heavy] caller is gone; not starting '$class' job" >&2; exit 143; fi
  sleep "${OPPI_HEAVY_POLL:-5}"
done
