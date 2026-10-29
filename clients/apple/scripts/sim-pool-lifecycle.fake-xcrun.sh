#!/usr/bin/env bash
# Fake `xcrun simctl` for sim-pool-lifecycle.test.ts, installed as <root>/bin/xcrun.
# A shell script on purpose: a pool command makes a dozen simctl calls, and a Bun script costs a
# runtime start per call (about 0.6 s when the temp directory holds hundreds of thousands of
# entries, far more on a loaded host).
#
# State lives in <root>/devices.tsv, one row per device: udid, name, state, device type, runtime.
# Every call is appended to <root>/calls.log as "<subcommand> <args...>".
dir="$(cd "$(dirname "$0")/.." && pwd)"
tool=$1
shift
sub=${1:-}
shift || true
{
  printf '%s' "$sub"
  for arg in "$@"; do printf ' %s' "$arg"; done
  printf '\n'
} >>"$dir/calls.log"
[ "$tool" = simctl ] || exit 127
devices="$dir/devices.tsv"

set_state() {
  awk -F'\t' -v OFS='\t' -v udid="$1" -v state="$2" '$1 == udid { $3 = state } 1' "$devices" >"$devices.tmp" &&
    mv "$devices.tmp" "$devices"
}

case "$sub" in
  list)
    if [ "${1:-}" = runtimes ]; then
      cat "$dir/runtimes.json"
      exit 0
    fi
    awk -F'\t' '
      BEGIN { printf "{\"devices\":{" }
      {
        if (!($5 in seen)) { seen[$5] = ++n; order[n] = $5 }
        row = sprintf("{\"udid\":\"%s\",\"name\":\"%s\",\"state\":\"%s\",\"isAvailable\":true,\"deviceTypeIdentifier\":\"%s\"}", $1, $2, $3, $4)
        rows[$5] = rows[$5] (rows[$5] == "" ? "" : ",") row
      }
      END {
        for (i = 1; i <= n; i++) printf "%s\"%s\":[%s]", (i > 1 ? "," : ""), order[i], rows[order[i]]
        printf "}}"
      }
    ' "$devices"
    ;;
  create)
    printf 'UDID-%s\t%s\tShutdown\t%s\t%s\n' "$1" "$1" "$2" "$3" >>"$devices"
    echo "UDID-$1"
    ;;
  boot) set_state "$1" Booted ;;
  shutdown) set_state "$1" Shutdown ;;
  bootstatus | spawn | uninstall | keychain | privacy) ;;
  *) exit 127 ;;
esac
