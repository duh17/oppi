#!/bin/sh
# Oppi installer: Node.js when needed, the oppi-server package, and the
# background service. No sudo, no package managers.
#
#   curl -fsSL https://raw.githubusercontent.com/duh17/oppi/main/install.sh | sh
#   sh install.sh [--non-interactive] [--version <x.y.z>] [--package <oppi-server.tgz>] [--no-service]
#
# Options:
#   --non-interactive  Never prompt. The iOS app runs this file over SSH as
#                      `/bin/sh -s -- --non-interactive` with the script on stdin.
#   --version <spec>   Install oppi-server <spec> (a version, tag, or range)
#                      instead of npm `latest`.
#   --package <tgz>    Install a local `npm pack` tarball of server/ (testing
#                      unreleased server changes). Skips the minimum-version check.
#   --no-service       Do not install the LaunchAgent / systemd unit; start
#                      `oppi serve` in the background instead (does not survive
#                      a reboot). Also used when Linux has no systemd user manager.
#
# Steps:
#   node     Use `node` >= 22.19 (with npm) from the login shell's PATH. Otherwise
#            download the official Node 22 LTS tarball from nodejs.org, verify it
#            against SHASUMS256.txt, and install it under ~/.oppi/runtime/node.
#   oppi     Refuse oppi-server older than OPPI_MIN_SERVER_VERSION (the first
#            release with Linux service support and this installer's checks).
#            `npm install --global --prefix` a staging directory under
#            ~/.oppi/install/releases with `--ignore-scripts --omit=dev`, and
#            smoke-test `oppi --version`. Launcher: ~/.oppi/bin/oppi (it sets
#            OPPI_NODE, which the service keeps and the server appends to session
#            PATH), symlinked into ~/.local/bin when writable. Another oppi (an
#            npm global install) is left alone and reported.
#   service  Refuse to start when another program holds the server port. Then
#            move the release into place and atomically point
#            ~/.oppi/install/current at it (a later failure points it back),
#            and run `oppi server install`: macOS LaunchAgent, Linux systemd
#            user unit. The replaced release stays for a manual rollback.
#   start    Wait (90 s) until `oppi status --json` reports HTTPS, the server
#            on the owner Unix socket is the installed version in the process
#            the service (or this script) runs with its listener on the port,
#            and https://127.0.0.1:<port>/health answers.
# Rerunning upgrades or repairs and ends in the same state.
#
# Progress protocol. This is a contract with the iOS app (SSH setup); keep the
# format exact. One line each on stdout; other output is for people and the app
# ignores it:
#
#   oppi-install: step=<node|oppi|service|start> status=<begin|ok|warn|skip|fail> detail=<one line>
#   oppi-install: done version=<x.y.z> port=<n>
#   oppi-install: error code=<code> detail=<one line>
#
# Statuses: `ok`, `warn`, `skip`, and `fail` end a step. `skip` means nothing new
# was done, or a fallback ran (already installed, an offline rerun kept the old
# Node, the service fell back to a background `oppi serve`). `warn` means the
# step is done, with a caveat the user must see: lingering is off, so the service
# stops at logout; or another `oppi`, a foreign file at the link path, or a link
# directory off PATH means `oppi` by name may not run this install. `warn` and
# `skip` are not failures; the app shows both as warnings, and the run still
# ends in `done`.
#
# Error codes: usage, unsupported_platform, busy, node_download, checksum, npm,
# server_too_old, port_in_use, service, start_timeout. A failing step prints
# `status=fail` and then `error`.
# The exit status is 0 only after `done`.

# Everything runs inside main, called on the last line: a truncated download
# runs nothing, and with `sh -s` no command can read the rest of the script.

OPPI_MIN_NODE_MAJOR=22
OPPI_MIN_NODE_MINOR=19
OPPI_NODE_DIST=https://nodejs.org/dist/latest-v22.x
OPPI_PACKAGE_NAME=oppi-server
# Older releases lack the Linux service, OPPI_NODE, and the owner-socket
# process facts in `oppi server status --json`.
OPPI_MIN_SERVER_VERSION=0.54.0
OPPI_START_TIMEOUT=90

say() {
  printf '%s\n' "$*"
}

one_line() {
  printf '%s' "$*" | tr '\r\n\t' '   '
}

progress() {
  # progress <step> <status> <detail>
  current_step=$1
  say "oppi-install: step=$1 status=$2 detail=$(one_line "$3")"
}

fail() {
  # fail <code> <detail>
  if [ -n "${current_step:-}" ]; then
    say "oppi-install: step=$current_step status=fail detail=$(one_line "$2")"
  fi
  say "oppi-install: error code=$1 detail=$(one_line "$2")"
  rollback_release
  # A staged release that was never activated is not kept.
  if [ -z "${switched:-}" ] && [ -n "${staged:-}" ] && [ "$staged" != "${release:-}" ]; then
    rm -rf "$staged"
  fi
  release_lock
  exit 1
}

usage() {
  cat <<'EOF'
Usage: install.sh [--non-interactive] [--version <x.y.z>] [--package <oppi-server.tgz>] [--no-service]

Installs Node.js 22 when needed, oppi-server, and the background service, then
waits for the server to answer. No sudo. See the comment at the top of this file.
EOF
}

# ---------------------------------------------------------------- environment

# sshd's PATH lacks Homebrew, nvm, and similar. Adopt the login shell's PATH,
# the same way the app's SSH setup check does, so both see the same `node`.
login_shell_path() {
  "${SHELL:-/bin/sh}" -lc 'printf "\nOPPI_PATH=%s\n" "$PATH"' </dev/null 2>/dev/null | sed -n 's/^OPPI_PATH=//p' | tail -n 1
}

adopt_login_path() {
  login_path=$(login_shell_path)
  if [ -n "$login_path" ]; then
    PATH=$login_path
    export PATH
  fi
}

detect_platform() {
  case "$(uname -s)" in
    Darwin) node_os=darwin ;;
    Linux) node_os=linux ;;
    *) fail unsupported_platform "Oppi supports macOS and Linux, not $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) node_arch=x64 ;;
    arm64 | aarch64) node_arch=arm64 ;;
    *) fail unsupported_platform "no Node.js build for CPU $(uname -m); install Node.js 22.19+ yourself and rerun" ;;
  esac
  # A shell under Rosetta reports x86_64 on Apple silicon.
  if [ "$node_os" = darwin ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ]; then
    node_arch=arm64
  fi
}

is_musl() {
  [ "$node_os" = linux ] || return 1
  for f in /lib/ld-musl-*; do
    [ -e "$f" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------- helpers

download() {
  # download <url> <file>
  if command -v curl >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -fsSL --retry 2 -o "$2" "$1" </dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget --https-only --secure-protocol=TLSv1_2 -q -O "$2" "$1" </dev/null
  else
    fail node_download "curl or wget is required to download Node.js"
  fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  else
    return 1
  fi
}

# Point <link> at <target> in one rename, so readers never see it missing.
# `mv -T` (GNU, busybox) and `mv -h` (BSD) replace a symlink to a directory
# instead of moving into it.
swap_symlink() {
  swap_tmp="$2.tmp.$$"
  rm -f "$swap_tmp"
  ln -s "$1" "$swap_tmp" || return 1
  mv -Tf "$swap_tmp" "$2" 2>/dev/null && return 0
  mv -hf "$swap_tmp" "$2" 2>/dev/null && return 0
  rm -f "$2" && mv -f "$swap_tmp" "$2"
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

node_version_ok() {
  # node_version_ok <node-path>: version is at least 22.19
  nv=$("$1" --version 2>/dev/null </dev/null) || return 1
  nv=${nv#v}
  nv_major=${nv%%.*}
  nv_rest=${nv#*.}
  nv_minor=${nv_rest%%.*}
  case "$nv_major.$nv_minor" in
    *[!0-9.]* | .* | *.) return 1 ;;
  esac
  [ "$nv_major" -gt "$OPPI_MIN_NODE_MAJOR" ] && return 0
  [ "$nv_major" -eq "$OPPI_MIN_NODE_MAJOR" ] && [ "$nv_minor" -ge "$OPPI_MIN_NODE_MINOR" ]
}

# The lock is a symlink whose target is the holder's pid: creating it is atomic
# and fails when it exists, so the pid is never missing or half-written.
acquire_lock() {
  lock=$OPPI_HOME/install/install.lock
  mkdir -p "$OPPI_HOME/install"
  if ! ln -s "$$" "$lock" 2>/dev/null; then
    lock_pid=$(readlink "$lock" 2>/dev/null)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      fail busy "another Oppi install is running (pid $lock_pid)"
    fi
    # Take over a dead holder's lock only through a rename to a name of our own:
    # of two runs racing here, one rename wins. The loser may have renamed the
    # winner's fresh lock instead of the dead one; it sees a different pid,
    # puts the lock back, and reports busy.
    stale=$lock.stale.$$
    if mv "$lock" "$stale" 2>/dev/null; then
      if [ "$(readlink "$stale" 2>/dev/null)" != "$lock_pid" ]; then
        mv "$stale" "$lock" 2>/dev/null
        fail busy "another Oppi install took the lock"
      fi
      rm -f "$stale"
    fi
    ln -s "$$" "$lock" 2>/dev/null || fail busy "another Oppi install took the lock"
  fi
  have_lock=1
}

release_lock() {
  if [ "${have_lock:-}" = 1 ]; then
    rm -f "$OPPI_HOME/install/install.lock"
    have_lock=
  fi
}

# Remove staging directories that an interrupted run left behind. Only the lock
# holder calls this, so none of them belong to a live install.
remove_stale_staging() {
  for stale in "$OPPI_HOME"/install/releases/.*.tmp.* "$OPPI_HOME"/install/releases/.*.old.* \
    "$OPPI_HOME"/install/install.lock.stale.* "$OPPI_HOME"/runtime/.download.*; do
    [ -e "$stale" ] && rm -rf "$stale"
  done
}

# ---------------------------------------------------------------- node

install_managed_node() {
  runtime_dir=$OPPI_HOME/runtime
  stage=$runtime_dir/.download.$$
  rm -rf "$stage"
  mkdir -p "$stage" || fail node_download "could not create $stage"

  download "$OPPI_NODE_DIST/SHASUMS256.txt" "$stage/SHASUMS256.txt" ||
    { rm -rf "$stage"; return 1; }
  suffix="-$node_os-$node_arch.tar.gz"
  node_file=$(awk -v s="$suffix" 'index($2, "node-v") == 1 && substr($2, length($2) - length(s) + 1) == s { print $2; exit }' "$stage/SHASUMS256.txt")
  expected=$(awk -v f="$node_file" '$2 == f { print $1; exit }' "$stage/SHASUMS256.txt")
  if [ -z "$node_file" ] || [ -z "$expected" ]; then
    rm -rf "$stage"
    fail node_download "nodejs.org lists no Node.js 22 build for $node_os-$node_arch"
  fi
  node_name=${node_file%.tar.gz}

  if [ -x "$runtime_dir/$node_name/bin/node" ] && node_version_ok "$runtime_dir/$node_name/bin/node"; then
    rm -rf "$stage"
    swap_symlink "$node_name" "$runtime_dir/node" || fail node_download "could not link $runtime_dir/node"
    node_result="$node_name already installed in $runtime_dir"
    node_status=skip
    return 0
  fi

  say "  Downloading $node_file"
  download "$OPPI_NODE_DIST/$node_file" "$stage/$node_file" ||
    { rm -rf "$stage"; fail node_download "could not download $OPPI_NODE_DIST/$node_file"; }
  actual=$(sha256_of "$stage/$node_file") ||
    { rm -rf "$stage"; fail checksum "no sha256sum, shasum, or openssl to verify the Node.js download"; }
  if [ "$actual" != "$expected" ]; then
    rm -rf "$stage"
    fail checksum "$node_file SHA-256 $actual does not match SHASUMS256.txt ($expected)"
  fi

  tar -xzf "$stage/$node_file" -C "$stage" </dev/null ||
    { rm -rf "$stage"; fail node_download "could not extract $node_file"; }
  rm -rf "${runtime_dir:?}/$node_name"
  mv "$stage/$node_name" "$runtime_dir/$node_name" ||
    { rm -rf "$stage"; fail node_download "could not move Node.js into $runtime_dir"; }
  rm -rf "$stage"
  node_version_ok "$runtime_dir/$node_name/bin/node" ||
    fail node_download "the downloaded Node.js does not run on this machine"
  swap_symlink "$node_name" "$runtime_dir/node" || fail node_download "could not link $runtime_dir/node"

  # Drop older managed Node versions; the service is restarted onto the new one.
  for old in "$runtime_dir"/node-v*; do
    [ -d "$old" ] && [ "$old" != "$runtime_dir/$node_name" ] && rm -rf "$old"
  done
  node_result="installed $node_name in $runtime_dir"
  node_status=ok
}

choose_node() {
  progress node begin "looking for Node.js 22.19+ with npm"
  login_node=$(command -v node 2>/dev/null || true)
  case "$login_node" in /*) ;; *) login_node= ;; esac
  if [ -n "$login_node" ] && node_version_ok "$login_node" && [ -x "${login_node%/*}/npm" ]; then
    oppi_node=$login_node
    oppi_npm=${login_node%/*}/npm
    progress node ok "using $login_node ($("$login_node" --version </dev/null))"
    return 0
  fi

  if is_musl; then
    fail unsupported_platform "musl libc (Alpine) has no official Node.js build; install nodejs and npm 22.19+ with your package manager and rerun"
  fi
  managed=$OPPI_HOME/runtime/node/bin/node
  if ! install_managed_node; then
    # Offline rerun: keep a managed Node that already works.
    if [ -x "$managed" ] && node_version_ok "$managed"; then
      node_status=skip
      node_result="could not reach nodejs.org; kept $("$managed" --version </dev/null) in $OPPI_HOME/runtime"
    else
      fail node_download "could not download $OPPI_NODE_DIST/SHASUMS256.txt"
    fi
  fi
  # The stable path, not the versioned directory: the launcher and the service
  # follow ~/.oppi/runtime/node when a rerun installs a newer Node 22.
  oppi_node=$managed
  oppi_npm=$OPPI_HOME/runtime/node/bin/npm
  if [ -n "$login_node" ]; then
    node_result="$node_result (login PATH has $login_node $("$login_node" --version 2>/dev/null </dev/null), which is too old or has no npm)"
  fi
  progress node "$node_status" "$node_result"
}

# ---------------------------------------------------------------- oppi

npm_run() {
  # npm's own scripts start with `#!/usr/bin/env node`; give them the chosen node.
  PATH="${oppi_node%/*}:$PATH" "$oppi_npm" "$@" </dev/null
}

package_version() {
  if [ -n "$package_file" ]; then
    tar -xzOf "$package_file" package/package.json </dev/null 2>/dev/null |
      "$oppi_node" -e '
        let s = "";
        process.stdin.on("data", (c) => (s += c)).on("end", () => {
          const p = JSON.parse(s);
          if (p.name !== process.argv[1]) process.exit(2);
          process.stdout.write(p.version);
        });' "$OPPI_PACKAGE_NAME"
  else
    # A tag or range resolves to the newest matching version; npm prints a
    # string for one match and an array for several.
    npm_run view "$OPPI_PACKAGE_NAME@${requested_version:-latest}" version --json 2>/dev/null |
      "$oppi_node" -e '
        let s = "";
        process.stdin.on("data", (c) => (s += c)).on("end", () => {
          const v = JSON.parse(s || "null");
          const last = Array.isArray(v) ? v[v.length - 1] : v;
          if (typeof last !== "string") process.exit(1);
          process.stdout.write(last);
        });'
  fi
}

# version_older <a> <b>: a sorts before b. Same major.minor.patch: a prerelease
# (0.54.0-beta.1) is older than the release; two prereleases compare as text.
version_older() {
  "$oppi_node" -e '
    const split = (v) => {
      const [core, pre = ""] = v.split("+")[0].split(/-(.*)/s);
      return { nums: core.split(".").map((n) => Number(n) || 0), pre };
    };
    const [a, b] = [split(process.argv[1]), split(process.argv[2])];
    for (let i = 0; i < 3; i++) {
      const [x, y] = [a.nums[i] ?? 0, b.nums[i] ?? 0];
      if (x !== y) process.exit(x < y ? 0 : 1);
    }
    if (a.pre === b.pre) process.exit(1);
    if (!a.pre) process.exit(1);
    if (!b.pre) process.exit(0);
    process.exit(a.pre < b.pre ? 0 : 1);
  ' "$1" "$2" </dev/null
}

installed_version() {
  # installed_version <release-dir>: prints `x.y.z` when its CLI runs
  out=$("$oppi_node" "$1/lib/node_modules/$OPPI_PACKAGE_NAME/dist/src/cli.js" --version </dev/null 2>/dev/null) || return 1
  printf '%s' "${out##* }"
}

install_oppi() {
  progress oppi begin "installing $OPPI_PACKAGE_NAME${requested_version:+@$requested_version}${package_file:+ from $package_file}"

  # Another oppi on PATH (npm global, source link) stays; report it.
  other_oppi=$(command -v oppi 2>/dev/null || true)
  case "$other_oppi" in
    "" | "$OPPI_HOME/bin/oppi" | "$link_dir/oppi") other_oppi= ;;
  esac

  version=$(package_version) || version=
  case "$version" in
    "" | *[!0-9A-Za-z.+-]*)
      if [ -n "$package_file" ]; then
        fail npm "$package_file is not an $OPPI_PACKAGE_NAME npm pack tarball"
      fi
      fail npm "could not resolve $OPPI_PACKAGE_NAME@${requested_version:-latest} from the npm registry"
      ;;
  esac
  # A registry release older than this installer cannot run its service steps.
  # --package is for testing unreleased servers and is trusted as is.
  if [ -z "$package_file" ] && version_older "$version" "$OPPI_MIN_SERVER_VERSION"; then
    fail server_too_old "$OPPI_PACKAGE_NAME $version is older than $OPPI_MIN_SERVER_VERSION, the first release this installer supports"
  fi

  releases=$OPPI_HOME/install/releases
  release=$releases/$version
  mkdir -p "$releases"

  # Install into a staging prefix. Nothing the running server or the next
  # service restart uses changes until activate_release, after the port check.
  if [ -z "$package_file" ] && [ "$(installed_version "$release" || true)" = "$version" ]; then
    staged=$release
    oppi_status=skip
    oppi_result="$OPPI_PACKAGE_NAME $version already installed"
  else
    stage=$releases/.$version.tmp.$$
    rm -rf "$stage"
    npm_log=$OPPI_HOME/install/npm.log
    spec=${package_file:-$OPPI_PACKAGE_NAME@$version}
    say "  npm install $spec (log: $npm_log)"
    if ! npm_run install --global --prefix "$stage" --ignore-scripts --omit=dev \
      --no-fund --no-audit --loglevel=error "$spec" >"$npm_log" 2>&1; then
      rm -rf "$stage"
      tail -n 20 "$npm_log" >&2
      fail npm "npm install $spec failed: $(grep -v '^[[:space:]]*$' "$npm_log" | tail -n 1)"
    fi
    got=$(installed_version "$stage" || true)
    if [ "$got" != "$version" ]; then
      rm -rf "$stage"
      fail npm "installed $OPPI_PACKAGE_NAME did not run: oppi --version printed '${got}', expected $version"
    fi
    staged=$stage
    oppi_status=ok
    oppi_result="installed $OPPI_PACKAGE_NAME $version"
  fi
  cli_js=$staged/lib/node_modules/$OPPI_PACKAGE_NAME/dist/src/cli.js

  # The launcher runs whatever `current` points at, so writing it now changes
  # nothing until the switch.
  write_launcher
  link_launcher
  [ -n "$other_oppi" ] && oppi_result="$oppi_result; left another oppi at $other_oppi in place"
  [ -n "$link_note" ] && oppi_result="$oppi_result; $link_note"
  # Another oppi, a foreign file at the link path, or a link directory off PATH:
  # `oppi` by name may not be this install. Adding the directory to the profile is
  # only a note (a new terminal picks it up).
  [ -n "$other_oppi" ] && oppi_status=warn
  case "$link_note" in
    "" | "added "*) ;;
    *) oppi_status=warn ;;
  esac
  progress oppi "$oppi_status" "$oppi_result"
}

# ~/.oppi/bin/oppi runs the current release on the chosen Node by absolute
# path, so it works where `node` is not on PATH (sshd, the service, Pi's tools).
# OPPI_NODE tells `oppi server install` which Node the service should run.
# The Node directory goes last on the launcher's PATH so CLI commands that run
# npm (`oppi update --check`) work without putting this Node ahead of the user's.
write_launcher() {
  launcher=$OPPI_HOME/bin/oppi
  mkdir -p "$OPPI_HOME/bin" || fail npm "could not create $OPPI_HOME/bin"
  if ! cat >"$launcher.tmp.$$" <<EOF
#!/bin/sh
# Oppi launcher written by install.sh; rerunning the installer rewrites it.
OPPI_NODE=$(shell_quote "$oppi_node")
export OPPI_NODE
PATH="\$PATH:\${OPPI_NODE%/*}"
export PATH
exec "\$OPPI_NODE" $(shell_quote "$OPPI_HOME/install/current/lib/node_modules/$OPPI_PACKAGE_NAME/dist/src/cli.js") "\$@"
EOF
  then
    rm -f "$launcher.tmp.$$"
    fail npm "could not write $launcher"
  fi
  if ! { chmod 755 "$launcher.tmp.$$" && mv -f "$launcher.tmp.$$" "$launcher"; }; then
    fail npm "could not write $launcher"
  fi
}

# The staged (later: active) release's CLI, for the installer's own queries.
oppi_cli() {
  OPPI_NODE=$oppi_node "$oppi_node" "$cli_js" "$@" </dev/null 2>/dev/null
}

# Point `current` at the staged release. A same-version replacement moves the
# old directory aside instead of deleting it, so a server still running from it
# keeps its files and a failure can put it back. rollback_release undoes this.
activate_release() {
  current_target=$(readlink "$OPPI_HOME/install/current" 2>/dev/null || true)
  saved_previous=$(cat "$OPPI_HOME/install/previous" 2>/dev/null || true)
  aside=
  if [ "$staged" != "$release" ]; then
    if [ -e "$release" ]; then
      aside=$releases/.$version.old.$$
      mv "$release" "$aside" || fail npm "could not move the old $version aside"
    fi
    mv "$staged" "$release" || fail npm "could not move the release into $release"
    cli_js=$release/lib/node_modules/$OPPI_PACKAGE_NAME/dist/src/cli.js
  fi
  # Remember the release being replaced for a manual rollback. A rerun of the
  # same version keeps the one remembered earlier.
  if [ -n "$current_target" ] && [ "${current_target#releases/}" != "$version" ]; then
    printf '%s\n' "${current_target#releases/}" >"$OPPI_HOME/install/previous"
  fi
  swap_symlink "releases/$version" "$OPPI_HOME/install/current" ||
    fail npm "could not point $OPPI_HOME/install/current at $version"
  switched=1
}

# After a failure past the switch: the next service restart must run what ran before.
rollback_release() {
  [ "${switched:-}" = 1 ] || return 0
  switched=
  if [ -n "$aside" ] && [ -d "$aside" ]; then
    rm -rf "$release" && mv "$aside" "$release"
  fi
  if [ -n "$current_target" ]; then
    swap_symlink "$current_target" "$OPPI_HOME/install/current"
    if [ -n "$saved_previous" ]; then
      printf '%s\n' "$saved_previous" >"$OPPI_HOME/install/previous"
    else
      rm -f "$OPPI_HOME/install/previous"
    fi
    say "  Rolled $OPPI_HOME/install/current back to ${current_target#releases/}"
  fi
}

# Once the new server answers: drop releases other than current and the one
# remembered for rollback, and the directory moved aside.
prune_releases() {
  [ -n "$aside" ] && rm -rf "$aside"
  previous_version=$(cat "$OPPI_HOME/install/previous" 2>/dev/null || true)
  for old in "$releases"/*; do
    [ -d "$old" ] || continue
    [ "$old" = "$release" ] && continue
    [ -n "$previous_version" ] && [ "$old" = "$releases/$previous_version" ] && continue
    rm -rf "$old"
  done
}

path_has() {
  # path_has <dir> <path-list>
  case ":$2:" in *":$1:"*) return 0 ;; esac
  return 1
}

profile_file() {
  case "${SHELL##*/}" in
    zsh) printf '%s/.zprofile' "${ZDOTDIR:-$HOME}" ;;
    bash)
      for f in "$HOME/.bash_profile" "$HOME/.bash_login"; do
        [ -f "$f" ] && { printf '%s' "$f"; return; }
      done
      printf '%s/.profile' "$HOME"
      ;;
    fish) printf '%s/.config/fish/conf.d/oppi.fish' "$HOME" ;;
    *) printf '%s/.profile' "$HOME" ;;
  esac
}

# The app finds `oppi` on the login PATH after install, so the link directory
# must be on it. Interactive runs ask first; --non-interactive adds it.
ensure_on_login_path() {
  dir=$1
  path_has "$dir" "$PATH" && return 0
  # Some profiles (Ubuntu's ~/.profile) add ~/.local/bin only once it exists.
  path_has "$dir" "$(login_shell_path)" && return 0
  profile=$(profile_file)
  marker="# Added by the Oppi installer"
  if [ -f "$profile" ] && grep -F "$marker" "$profile" >/dev/null 2>&1; then
    return 0
  fi
  if [ "$interactive" = 1 ] && (: </dev/tty) 2>/dev/null; then
    printf 'Add %s to PATH in %s? [Y/n] ' "$dir" "$profile" >/dev/tty
    read -r answer </dev/tty || answer=
    case "$answer" in
      [nN]*)
        link_note="$dir is not on PATH; add it to use oppi by name"
        return 0
        ;;
    esac
  fi
  mkdir -p "$(dirname "$profile")"
  # Write $HOME, not the expanded path, so a renamed home keeps working.
  case "$dir" in
    "$HOME"/*) profile_dir=\$HOME/${dir#"$HOME"/} ;;
    *) profile_dir=$dir ;;
  esac
  if [ "${profile##*.}" = fish ]; then
    printf '%s\nfish_add_path -g "%s"\n' "$marker" "$profile_dir" >>"$profile"
  else
    printf '\n%s\nexport PATH="%s:$PATH"\n' "$marker" "$profile_dir" >>"$profile"
  fi
  link_note="added $dir to PATH in $profile"
}

link_launcher() {
  link_note=
  dir=$link_dir
  if mkdir -p "$dir" 2>/dev/null && [ -w "$dir" ]; then
    target=$dir/oppi
    if [ -e "$target" ] || [ -L "$target" ]; then
      if [ "$(readlink "$target" 2>/dev/null)" != "$launcher" ]; then
        link_note="$target exists and is not Oppi's; left it alone"
        ensure_on_login_path "$OPPI_HOME/bin"
        return 0
      fi
    fi
    swap_symlink "$launcher" "$target" || fail npm "could not link $target"
  else
    dir=$OPPI_HOME/bin
  fi
  ensure_on_login_path "$dir"
}

# ---------------------------------------------------------------- service

systemd_user_available() {
  command -v systemctl >/dev/null 2>&1 || return 1
  if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "/run/user/$(id -u)" ]; then
    XDG_RUNTIME_DIR=/run/user/$(id -u)
    export XDG_RUNTIME_DIR
  fi
  systemctl --user show-environment >/dev/null 2>&1 </dev/null
}

pid_command() {
  if [ -r "/proc/$1/cmdline" ]; then
    tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null
  else
    ps -p "$1" -o command= 2>/dev/null
  fi
}

# A live `oppi serve` from this managed install (pids get reused).
is_managed_serve() {
  case "$(pid_command "$1")" in
    *"$OPPI_HOME/install/"*" serve"*) return 0 ;;
  esac
  return 1
}

# A server this installer started without a service (see start_background).
stop_background() {
  pid_file=$OPPI_HOME/serve.pid
  [ -f "$pid_file" ] || return 0
  bg_pid=$(cat "$pid_file" 2>/dev/null)
  rm -f "$pid_file"
  [ -n "$bg_pid" ] && is_managed_serve "$bg_pid" || return 0
  kill "$bg_pid" 2>/dev/null
  i=0
  while kill -0 "$bg_pid" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 0.5
    i=$((i + 1))
  done
}

start_background() {
  serve_log=$OPPI_HOME/serve.log
  if command -v setsid >/dev/null 2>&1; then
    setsid "$launcher" serve </dev/null >>"$serve_log" 2>&1 &
  else
    nohup "$launcher" serve </dev/null >>"$serve_log" 2>&1 &
  fi
  # setsid and the launcher exec, so this is the server's own pid.
  printf '%s\n' "$!" >"$OPPI_HOME/serve.pid"
  serve_mode=background
  log_hint=$serve_log
}

# json_field <json> <dot.path>: the value there, or nothing.
json_field() {
  "$oppi_node" -e '
    try {
      let v = JSON.parse(process.argv[1]);
      for (const k of process.argv[2].split(".")) v = v?.[k];
      if (v !== undefined && v !== null) process.stdout.write(String(v));
    } catch {}
  ' "$1" "$2" </dev/null
}

# `free` when nothing accepts TCP on 127.0.0.1:<port>, else `open`.
port_state() {
  "$oppi_node" -e '
    const sock = require("node:net").connect({ host: "127.0.0.1", port: Number(process.argv[1]) });
    const say = (s) => { process.stdout.write(s); process.exit(0); };
    sock.setTimeout(3000, () => say("open"));
    sock.on("error", (e) => say(e.code === "ECONNREFUSED" ? "free" : "open"));
    sock.on("connect", () => say("open"));
  ' "$1" </dev/null
}

# Pid listening on <port> from lsof or ss, when either is installed.
listener_pid() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null </dev/null | head -n 1
  elif command -v ss >/dev/null 2>&1; then
    ss -Hltnp "sport = :$1" 2>/dev/null </dev/null | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -n 1
  fi
}

# Refuse to start when the port belongs to anything but the service this run
# replaces: a hand-run `oppi serve`, another app's server, or (with
# --no-service, which leaves the service alone) the service itself. Otherwise
# the new server would crash-loop while the old one kept answering /health.
#
# Who holds the port: lsof or ss when installed; otherwise the server on this
# data directory, asked over its owner-only Unix socket (`oppi server status
# --json`), when it reports its HTTPS listener bound to that port.
check_port() {
  port=$(json_field "$(oppi_cli status --json)" data.status.server.port)
  case "$port" in '' | *[!0-9]*) return 0 ;; esac
  [ "$(port_state "$port")" = free ] && return 0
  server_json=$(oppi_cli server status --json)
  service_holder=$(json_field "$server_json" data.service.pid)
  holder_pid=$(listener_pid "$port")
  if [ -z "$holder_pid" ] && [ "$(json_field "$server_json" data.server.listening)" = true ] &&
    [ "$(json_field "$server_json" data.server.port)" = "$port" ]; then
    holder_pid=$(json_field "$server_json" data.server.pid)
  fi
  replaceable_pid=
  [ "$1" = service ] && replaceable_pid=$service_holder
  if [ -n "$holder_pid" ]; then
    [ -n "$replaceable_pid" ] && [ "$holder_pid" = "$replaceable_pid" ] && return 0
    if [ "$holder_pid" = "$service_holder" ]; then
      fail port_in_use "port $port is in use by the Oppi background service (pid $holder_pid); run 'oppi server uninstall' first, or install without --no-service"
    fi
    what="pid $holder_pid ($(pid_command "$holder_pid" | cut -c1-120))"
  elif [ -n "$replaceable_pid" ]; then
    # No lsof or ss, and no server on this data directory that reports the
    # port (an older Oppi): the running service is the likely holder, and its
    # restart frees the port.
    say "  Port $port answers; assuming it is the Oppi service being replaced (pid $replaceable_pid)"
    return 0
  else
    what="another program"
  fi
  fail port_in_use "port $port is in use by $what; stop it (or change the port with 'oppi config set port <n>') and rerun"
}

# Order matters: stop this installer's own background server, check the port,
# and only then switch `current` (activate_release). A failure after the switch
# rolls it back (fail -> rollback_release).
install_service() {
  service_log=$OPPI_HOME/install/service.log
  background_reason=
  if [ "$no_service" = 1 ]; then
    background_reason="--no-service"
  elif [ "$node_os" = linux ] && ! systemd_user_available; then
    background_reason="no systemd user manager here"
  fi
  if [ -n "$background_reason" ]; then
    progress service begin "checking the server port"
    stop_background
    check_port background
    activate_release
    progress service skip "$background_reason: starting oppi serve in the background (does not survive a reboot)"
    start_background
    return 0
  fi

  progress service begin "oppi server install"
  stop_background
  check_port service
  activate_release
  if ! "$launcher" server install </dev/null >"$service_log" 2>&1; then
    cat "$service_log" >&2
    fail service "oppi server install failed: $(grep -F '✗' "$service_log" | head -n 1 | sed 's/^[[:space:]]*✗[[:space:]]*//')"
  fi
  if [ "$node_os" = darwin ]; then
    log_hint="$HOME/.config/oppi/server.log"
    progress service ok "LaunchAgent dev.chaosdonkey.oppi installed; starts at login"
  else
    log_hint="journalctl --user -u oppi"
    linger=$(loginctl show-user "$(id -un)" --property=Linger --value 2>/dev/null </dev/null || true)
    if [ "$linger" = yes ]; then
      progress service ok "systemd user service oppi.service installed; starts at boot"
    else
      progress service warn "systemd user service oppi.service installed; it stops when you log out until an admin runs: sudo loginctl enable-linger $(id -un)"
    fi
  fi
}

# ---------------------------------------------------------------- start

# Prints `ready <port> <pid>` once `oppi status` says HTTPS, the server on this
# data directory (asked over its owner socket) is the expected process running
# <version> with its HTTPS listener bound to that port, and loopback /health
# answers; otherwise `wait <why>`. The expected process is the service's pid,
# or the background server's from serve.pid.
probe_ready() {
  "$oppi_node" -e '
    const [statusJson, serverJson, mode, backgroundPid, version] = process.argv.slice(1);
    const say = (s) => { process.stdout.write(s); process.exit(0); };
    let port, data;
    try {
      const server = JSON.parse(statusJson).data.status.server;
      if (server.transport !== "https") say("wait oppi status does not report HTTPS yet");
      port = server.port;
      data = JSON.parse(serverJson).data;
    } catch {
      say("wait oppi status is not readable yet");
    }
    const expected = mode === "background" ? Number(backgroundPid) : data.service?.pid;
    if (!expected) say("wait the service has no pid yet");
    const s = data.server;
    if (!s) say("wait no server answers on the owner socket yet");
    if (s.pid !== expected || s.version !== version) {
      say(`wait the owner socket is held by pid ${s.pid} (oppi-server ${s.version}), not the new server (pid ${expected}, ${version})`);
    }
    if (!s.listening || s.port !== port) say(`wait pid ${s.pid} has not bound port ${port} yet`);
    const req = require("node:https").get(
      { host: "127.0.0.1", port, path: "/health", rejectUnauthorized: false, timeout: 3000 },
      (res) => {
        let body = "";
        res.on("data", (c) => (body += c));
        res.on("end", () => {
          let h;
          try { h = JSON.parse(body); } catch {}
          if (h?.ok === true && h.protocol === 2) say(`ready ${port} ${expected}`);
          say(`wait port ${port} does not answer as Oppi`);
        });
      },
    );
    req.on("timeout", () => req.destroy());
    req.on("error", () => say(`wait no HTTPS answer on port ${port}`));
  ' "$(oppi_cli status --json)" "$(oppi_cli server status --json)" "$serve_mode" \
    "$(cat "$OPPI_HOME/serve.pid" 2>/dev/null)" "$version" </dev/null
}

wait_for_server() {
  progress start begin "waiting for https://127.0.0.1/health (up to ${OPPI_START_TIMEOUT}s)"
  started=$(date +%s)
  while :; do
    probe=$(probe_ready)
    case "$probe" in
      ready\ *)
        ready=${probe#ready }
        port=${ready%% *}
        progress start ok "Oppi $version answers https://127.0.0.1:$port/health (pid ${ready#* })"
        return 0
        ;;
    esac
    if [ $(($(date +%s) - started)) -ge "$OPPI_START_TIMEOUT" ]; then
      fail start_timeout "not ready after ${OPPI_START_TIMEOUT}s: ${probe#wait }; logs: $log_hint"
    fi
    sleep 1
  done
}

# Show a pairing code only to someone at a terminal. `ssh host 'curl ... | sh'`,
# CI, and `| tee` would leave a working first-device invite in a log, and a rerun
# (an upgrade) must not replace an invite someone is about to use: there is one
# slot. So: stdout is a terminal, no device has enrolled, and no invite is
# pending (the same rule `oppi serve` follows).
offer_pairing_code() {
  if [ -t 1 ]; then
    pairing_state=$(oppi_cli status --json)
    if [ "$(json_field "$pairing_state" data.status.paired)" = false ] &&
      [ "$(json_field "$pairing_state" data.status.pairingInvitePending)" = false ]; then
      say "Scan this code in the Oppi app on your iPhone:"
      "$launcher" pair </dev/null || say "Run 'oppi pair' to show a pairing code."
      say "Later, 'oppi pair' shows a fresh code (open a new terminal first if 'oppi' is not found)."
      return 0
    fi
  fi
  say "Run 'oppi pair' to show a pairing code (open a new terminal first if 'oppi' is not found)."
}

# ---------------------------------------------------------------- main

main() {
  interactive=1
  no_service=0
  requested_version=
  package_file=
  while [ $# -gt 0 ]; do
    case "$1" in
      --non-interactive) interactive=0 ;;
      --no-service) no_service=1 ;;
      --version)
        [ $# -ge 2 ] || fail usage "--version needs a value"
        requested_version=$2
        shift
        ;;
      --package)
        [ $# -ge 2 ] || fail usage "--package needs a path"
        package_file=$2
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) fail usage "unknown option: $1" ;;
    esac
    shift
  done
  [ -n "${HOME:-}" ] || fail usage "HOME is not set"
  if [ -n "$package_file" ]; then
    [ -f "$package_file" ] || fail usage "no such package file: $package_file"
    case "$package_file" in /*) ;; *) package_file=$(pwd)/$package_file ;; esac
  fi

  umask 022
  OPPI_HOME=$HOME/.oppi
  link_dir=$HOME/.local/bin
  launcher=$OPPI_HOME/bin/oppi
  log_hint=
  serve_mode=service

  adopt_login_path
  detect_platform
  acquire_lock
  trap 'release_lock' EXIT
  trap 'release_lock; exit 130' INT TERM

  remove_stale_staging
  say "Installing Oppi into $OPPI_HOME"
  choose_node
  install_oppi
  install_service
  wait_for_server
  switched=
  prune_releases
  release_lock

  say "oppi-install: done version=$version port=$port"
  # The app (--non-interactive) mints its own invite over SSH.
  if [ "$interactive" = 1 ]; then
    say ""
    say "Oppi $version is running."
    offer_pairing_code
  fi
  return 0
}

main "$@"
