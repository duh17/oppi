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
#   --version <v>      Install oppi-server <v> instead of npm `latest`.
#   --package <tgz>    Install a local `npm pack` tarball of server/ (testing
#                      unreleased server changes).
#   --no-service       Do not install the LaunchAgent / systemd unit; start
#                      `oppi serve` in the background instead (does not survive
#                      a reboot). Also used when Linux has no systemd user manager.
#
# Steps:
#   node     Use `node` >= 22.19 (with npm) from the login shell's PATH. Otherwise
#            download the official Node 22 LTS tarball from nodejs.org, verify it
#            against SHASUMS256.txt, and install it under ~/.oppi/runtime/node.
#   oppi     `npm install --global --prefix ~/.oppi/install/releases/<version>
#            --ignore-scripts --omit=dev oppi-server@<version>`, smoke-test
#            `oppi --version`, then atomically point ~/.oppi/install/current at it.
#            Launcher: ~/.oppi/bin/oppi, symlinked into ~/.local/bin when writable.
#            Another oppi (an npm global install) is left alone and reported.
#   service  `oppi server install`: macOS LaunchAgent, Linux systemd user unit.
#   start    Wait (90 s) until `oppi status --json` reports HTTPS and
#            https://127.0.0.1:<port>/health answers.
# Rerunning upgrades or repairs and ends in the same state.
#
# Progress protocol. This is a contract with the iOS app (SSH setup); keep the
# format exact. One line each on stdout; other output is for people and the app
# ignores it:
#
#   oppi-install: step=<node|oppi|service|start> status=<begin|ok|skip|fail> detail=<one line>
#   oppi-install: done version=<x.y.z> port=<n>
#   oppi-install: error code=<code> detail=<one line>
#
# Error codes: usage, unsupported_platform, busy, node_download, checksum, npm,
# service, start_timeout. A failing step prints `status=fail` and then `error`.
# The exit status is 0 only after `done`.

# Everything runs inside main, called on the last line: a truncated download
# runs nothing, and with `sh -s` no command can read the rest of the script.

OPPI_MIN_NODE_MAJOR=22
OPPI_MIN_NODE_MINOR=19
OPPI_NODE_DIST=https://nodejs.org/dist/latest-v22.x
OPPI_PACKAGE_NAME=oppi-server
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
    curl -fsSL --retry 2 -o "$2" "$1" </dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1" </dev/null
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

acquire_lock() {
  lock_dir=$OPPI_HOME/install/.lock
  mkdir -p "$OPPI_HOME/install"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    lock_pid=$(cat "$lock_dir/pid" 2>/dev/null)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      fail busy "another Oppi install is running (pid $lock_pid)"
    fi
    rm -rf "$lock_dir"
    mkdir "$lock_dir" 2>/dev/null || fail busy "could not lock $lock_dir"
  fi
  printf '%s\n' "$$" >"$lock_dir/pid"
  have_lock=1
}

release_lock() {
  if [ "${have_lock:-}" = 1 ]; then
    rm -rf "$OPPI_HOME/install/.lock"
    have_lock=
  fi
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
  elif [ -n "$requested_version" ]; then
    printf '%s' "$requested_version"
  else
    npm_run view "$OPPI_PACKAGE_NAME@latest" version 2>/dev/null
  fi
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

  releases=$OPPI_HOME/install/releases
  release=$releases/$version
  mkdir -p "$releases"
  previous_release=$(readlink "$OPPI_HOME/install/current" 2>/dev/null || true)

  if [ -z "$package_file" ] && [ "$(installed_version "$release" || true)" = "$version" ]; then
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
    rm -rf "$release"
    mv "$stage" "$release" || fail npm "could not move the release into $release"
    oppi_status=ok
    oppi_result="installed $OPPI_PACKAGE_NAME $version"
  fi

  swap_symlink "releases/$version" "$OPPI_HOME/install/current" ||
    fail npm "could not point $OPPI_HOME/install/current at $version"
  # Keep the release just replaced (rollback by hand); drop older ones.
  for old in "$releases"/*; do
    [ -d "$old" ] || continue
    case "$old" in
      "$release" | "$releases/${previous_release#releases/}") ;;
      *) rm -rf "$old" ;;
    esac
  done

  write_launcher
  link_launcher
  [ -n "$other_oppi" ] && oppi_result="$oppi_result; left another oppi at $other_oppi in place"
  [ -n "$link_note" ] && oppi_result="$oppi_result; $link_note"
  progress oppi "$oppi_status" "$oppi_result"
}

# ~/.oppi/bin/oppi runs the current release on the chosen Node by absolute
# path, so it works where `node` is not on PATH (sshd, the service, Pi's tools).
# OPPI_NODE tells `oppi server install` which Node the service should run.
write_launcher() {
  mkdir -p "$OPPI_HOME/bin"
  launcher=$OPPI_HOME/bin/oppi
  cat >"$launcher.tmp.$$" <<EOF
#!/bin/sh
# Oppi launcher written by install.sh; rerunning the installer rewrites it.
OPPI_NODE=$(shell_quote "$oppi_node")
export OPPI_NODE
exec "\$OPPI_NODE" $(shell_quote "$OPPI_HOME/install/current/lib/node_modules/$OPPI_PACKAGE_NAME/dist/src/cli.js") "\$@"
EOF
  chmod 755 "$launcher.tmp.$$"
  mv -f "$launcher.tmp.$$" "$launcher" || fail npm "could not write $launcher"
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

# A server this installer started without a service (see start_background).
stop_background() {
  pid_file=$OPPI_HOME/serve.pid
  [ -f "$pid_file" ] || return 0
  bg_pid=$(cat "$pid_file" 2>/dev/null)
  rm -f "$pid_file"
  [ -n "$bg_pid" ] && kill -0 "$bg_pid" 2>/dev/null || return 0
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
  printf '%s\n' "$!" >"$OPPI_HOME/serve.pid"
  log_hint=$serve_log
}

install_service() {
  service_log=$OPPI_HOME/install/service.log
  stop_background
  if [ "$no_service" = 1 ]; then
    progress service skip "--no-service: starting oppi serve in the background (does not survive a reboot)"
    start_background
    return 0
  fi
  if [ "$node_os" = linux ] && ! systemd_user_available; then
    progress service skip "no systemd user manager here; starting oppi serve in the background (does not survive a reboot)"
    start_background
    return 0
  fi

  progress service begin "oppi server install"
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
      progress service ok "systemd user service oppi.service installed; it stops when you log out until an admin runs: sudo loginctl enable-linger $(id -un)"
    fi
  fi
}

# ---------------------------------------------------------------- start

# Prints the port once status says HTTPS and loopback /health answers.
probe_ready() {
  status_json=$("$launcher" status --json </dev/null 2>/dev/null) || return 1
  "$oppi_node" -e '
    const https = require("node:https");
    let port;
    try {
      const server = JSON.parse(process.argv[1]).data.status.server;
      if (server.transport !== "https") process.exit(1);
      port = server.port;
    } catch {
      process.exit(1);
    }
    const req = https.get(
      { host: "127.0.0.1", port, path: "/health", rejectUnauthorized: false, timeout: 3000 },
      (res) => {
        let body = "";
        res.on("data", (c) => (body += c));
        res.on("end", () => {
          try {
            const h = JSON.parse(body);
            if (h.ok === true && h.protocol === 2) {
              process.stdout.write(String(port));
              process.exit(0);
            }
          } catch {}
          process.exit(1);
        });
      },
    );
    req.on("timeout", () => req.destroy());
    req.on("error", () => process.exit(1));
  ' "$status_json" </dev/null
}

wait_for_server() {
  progress start begin "waiting for https://127.0.0.1/health (up to ${OPPI_START_TIMEOUT}s)"
  started=$(date +%s)
  while :; do
    if port=$(probe_ready); then
      progress start ok "Oppi $version answers https://127.0.0.1:$port/health"
      return 0
    fi
    if [ $(($(date +%s) - started)) -ge "$OPPI_START_TIMEOUT" ]; then
      fail start_timeout "no HTTPS /health answer after ${OPPI_START_TIMEOUT}s; logs: $log_hint"
    fi
    sleep 1
  done
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

  adopt_login_path
  detect_platform
  acquire_lock
  trap 'release_lock' EXIT
  trap 'release_lock; exit 130' INT TERM

  say "Installing Oppi into $OPPI_HOME"
  choose_node
  install_oppi
  install_service
  wait_for_server
  release_lock

  say "oppi-install: done version=$version port=$port"
  # A terminal install shows an invite here, because the service prints none.
  # The app (--non-interactive) mints its own invite over SSH.
  if [ "$interactive" = 1 ]; then
    say ""
    say "Oppi $version is running. Scan this code in the Oppi app on your iPhone:"
    "$launcher" pair </dev/null || say "Run 'oppi pair' to show a pairing code."
    say "Later, 'oppi pair' shows a fresh code (open a new terminal first if 'oppi' is not found)."
  fi
  return 0
}

main "$@"
