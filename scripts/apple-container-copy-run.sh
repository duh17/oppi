#!/usr/bin/env bash
set -euo pipefail

IMAGE="docker.io/library/node:24-bookworm-slim"
SOURCE_DIR=""
CONTAINER_WORKDIR="/work"
MEMORY="4G"
HOST_OUTPUT_DIR=""
CONTAINER_OUTPUT_DIR="/out"
ENV_ARGS=()
EXCLUDES=()

usage() {
  cat <<'EOF'
Run a command in Apple container after copying files in with tar streams.

No host path is bind-mounted. The source is copied to /work before the command
runs. When --output is set, /out is copied back after the command, including on
command failure.

Usage:
  apple-container-copy-run.sh --source DIR [options] -- COMMAND [ARG ...]

Options:
  --source DIR       Host directory copied into /work (required)
  --image IMAGE      OCI image (default: docker.io/library/node:24-bookworm-slim)
  --workdir DIR      Command working directory (default: /work)
  --memory SIZE      Container memory limit (default: 4G)
  --output DIR       Copy container /out into this host directory after the run
  --env KEY=VALUE    Set a container command environment variable; repeatable
  --exclude PATTERN  Exclude a tar path; repeatable
  -h, --help         Show this help

The image must provide /bin/sh, tar, mkdir, and sleep.
Start Apple container first with: container system start
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      SOURCE_DIR="${2:-}"
      shift 2
      ;;
    --image)
      IMAGE="${2:-}"
      shift 2
      ;;
    --workdir)
      CONTAINER_WORKDIR="${2:-}"
      shift 2
      ;;
    --memory)
      MEMORY="${2:-}"
      shift 2
      ;;
    --output)
      HOST_OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --env)
      ENV_ARGS+=("${2:-}")
      shift 2
      ;;
    --exclude)
      EXCLUDES+=("${2:-}")
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$SOURCE_DIR" || $# -eq 0 ]]; then
  echo "error: --source and a command after -- are required" >&2
  usage >&2
  exit 2
fi
if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "error: source directory not found: $SOURCE_DIR" >&2
  exit 2
fi
if ! command -v container >/dev/null 2>&1; then
  echo "error: Apple container CLI is not installed" >&2
  exit 1
fi
if ! container system status >/dev/null 2>&1; then
  echo "error: Apple container services are not running; run: container system start" >&2
  exit 1
fi

SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd -P)"
if [[ -n "$HOST_OUTPUT_DIR" ]]; then
  mkdir -p "$HOST_OUTPUT_DIR"
  HOST_OUTPUT_DIR="$(cd "$HOST_OUTPUT_DIR" && pwd -P)"
fi

CONTAINER_NAME="oppi-copy-run-$(date +%s)-$$-${RANDOM:-0}"
cleanup() {
  container rm --force "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

echo "[apple-container] image: $IMAGE (memory: $MEMORY)"
echo "[apple-container] copying $SOURCE_DIR to $CONTAINER_NAME:/work (no bind mounts)"
container run --detach --name "$CONTAINER_NAME" --memory "$MEMORY" --entrypoint /bin/sh "$IMAGE" \
  -c 'while :; do sleep 3600; done' >/dev/null

container exec "$CONTAINER_NAME" mkdir -p /work "$CONTAINER_OUTPUT_DIR"

tar_args=(--no-acls --no-fflags --no-xattrs --no-mac-metadata -C "$SOURCE_DIR")
for pattern in "${EXCLUDES[@]}"; do
  tar_args+=(--exclude "$pattern")
done
tar_args+=(-cf - .)

COPYFILE_DISABLE=1 tar "${tar_args[@]}" \
  | container exec -i "$CONTAINER_NAME" /bin/sh -c 'tar -xf - -C /work'

exec_args=()
for value in "${ENV_ARGS[@]}"; do
  exec_args+=(--env "$value")
done

set +e
container exec "${exec_args[@]}" --workdir "$CONTAINER_WORKDIR" "$CONTAINER_NAME" "$@"
command_status=$?
set -e

copy_status=0
if [[ -n "$HOST_OUTPUT_DIR" ]]; then
  echo "[apple-container] copying $CONTAINER_NAME:$CONTAINER_OUTPUT_DIR to $HOST_OUTPUT_DIR"
  set +e
  container exec "$CONTAINER_NAME" tar -C "$CONTAINER_OUTPUT_DIR" -cf - . \
    | COPYFILE_DISABLE=1 tar -C "$HOST_OUTPUT_DIR" -xf -
  copy_status=$?
  set -e
fi

if [[ $command_status -ne 0 ]]; then
  exit "$command_status"
fi
exit "$copy_status"
