#!/usr/bin/env bash
# Decide whether a CI coverage job is relevant without downloading a third-party
# action. Push workflows already have on.paths, so they are relevant. Pull
# requests match the same globs against the PR diff.
set -euo pipefail

usage() {
  echo "Usage: detect-ci-relevant-paths.sh [--event NAME] [--base-sha SHA] [--head-sha SHA] [--files-from FILE] [pattern ...]" >&2
  exit 2
}

event_name="${EVENT_NAME:-${GITHUB_EVENT_NAME:-}}"
base_sha="${BASE_SHA:-}"
head_sha="${HEAD_SHA:-HEAD}"
files_from=""
patterns=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --event)
      [[ $# -ge 2 ]] || usage
      event_name="$2"
      shift 2
      ;;
    --base-sha)
      [[ $# -ge 2 ]] || usage
      base_sha="$2"
      shift 2
      ;;
    --head-sha)
      [[ $# -ge 2 ]] || usage
      head_sha="$2"
      shift 2
      ;;
    --files-from)
      [[ $# -ge 2 ]] || usage
      files_from="$2"
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    --)
      shift
      patterns+=("$@")
      break
      ;;
    -*)
      usage
      ;;
    *)
      patterns+=("$1")
      shift
      ;;
  esac
done

if [[ ${#patterns[@]} -eq 0 ]]; then
  echo "detect-ci-relevant-paths: at least one path pattern is required" >&2
  exit 2
fi

write_result() {
  local relevant="$1"
  echo "relevant=$relevant"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "relevant=$relevant" >> "$GITHUB_OUTPUT"
  fi
}

path_matches() {
  local path="$1"
  local pattern="$2"
  local prefix

  if [[ "$pattern" == */** ]]; then
    prefix="${pattern%/}"
    prefix="${prefix%/\*\*}"
    [[ "$path" == "$prefix" || "$path" == "$prefix"/* ]]
    return
  fi

  # shellcheck disable=SC2254
  case "$path" in
    $pattern) return 0 ;;
    *) return 1 ;;
  esac
}

any_path_matches() {
  local path="$1"
  local pattern
  for pattern in "${patterns[@]}"; do
    if path_matches "$path" "$pattern"; then
      return 0
    fi
  done
  return 1
}

if [[ "$event_name" == "push" ]]; then
  write_result true
  exit 0
fi

if [[ "$event_name" != "pull_request" ]]; then
  echo "detect-ci-relevant-paths: unsupported event '$event_name'" >&2
  exit 1
fi

changed_paths=()
if [[ -n "$files_from" ]]; then
  if [[ "$files_from" == "-" ]]; then
    mapfile -t changed_paths
  else
    mapfile -t changed_paths < "$files_from"
  fi
else
  if [[ -z "$base_sha" ]]; then
    echo "detect-ci-relevant-paths: --base-sha is required for pull_request" >&2
    exit 1
  fi
  mapfile -t changed_paths < <(git diff --name-only --diff-filter=ACDMRT "$base_sha" "$head_sha")
fi

for path in "${changed_paths[@]}"; do
  [[ -n "$path" ]] || continue
  if any_path_matches "$path"; then
    write_result true
    exit 0
  fi
done

write_result false
