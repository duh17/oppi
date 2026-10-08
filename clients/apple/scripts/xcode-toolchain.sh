# Source me. Selects the Xcode toolchain every Oppi dev build lane uses.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/xcode-toolchain.sh"
#   oppi_use_xcode_toolchain
#
# An explicit DEVELOPER_DIR wins; otherwise the app named in xcode-toolchain.txt
# (shared with xcode-toolchain.ts). Exits with a clear message when the
# toolchain is missing. Never touches xcode-select.
_OPPI_XCODE_TOOLCHAIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

oppi_use_xcode_toolchain() {
  local developer_dir app
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    if [[ ! -d "$DEVELOPER_DIR" ]]; then
      echo "error: DEVELOPER_DIR points at a missing directory: $DEVELOPER_DIR" >&2
      exit 1
    fi
    export DEVELOPER_DIR
    return 0
  fi
  app="$(head -n 1 "$_OPPI_XCODE_TOOLCHAIN_DIR/xcode-toolchain.txt" | tr -d '[:space:]')"
  developer_dir="$app/Contents/Developer"
  if [[ ! -d "$developer_dir" ]]; then
    echo "error: Xcode toolchain not found: $app" >&2
    echo "hint: install it there or export DEVELOPER_DIR=<Xcode.app>/Contents/Developer (never xcode-select)" >&2
    exit 1
  fi
  export DEVELOPER_DIR="$developer_dir"
}
