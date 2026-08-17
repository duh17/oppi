#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_SPEC="$APPLE_ROOT/project.yml"

fail() {
  echo "error: $*" >&2
  exit 1
}

plist_value() {
  local manifest="$1"
  local key_path="$2"
  /usr/bin/plutil -extract "$key_path" raw -o - "$manifest"
}

assert_value() {
  local manifest="$1"
  local key_path="$2"
  local expected="$3"
  local actual
  actual="$(plist_value "$manifest" "$key_path")" || fail "$manifest is missing $key_path"
  if [[ "$actual" != "$expected" ]]; then
    fail "$manifest: $key_path is '$actual'; expected '$expected'"
  fi
}

validate_manifest() {
  local manifest="$1"
  shift

  [[ -f "$manifest" ]] || fail "missing privacy manifest: $manifest"
  /usr/bin/plutil -lint "$manifest" >/dev/null || fail "invalid privacy manifest: $manifest"
  assert_value "$manifest" NSPrivacyTracking false
  assert_value "$manifest" NSPrivacyTrackingDomains 0
  assert_value "$manifest" NSPrivacyCollectedDataTypes 0
  assert_value "$manifest" NSPrivacyAccessedAPITypes "$#"

  local api_index=0
  local spec category reasons reason_count reason_index
  local -a reason_values
  for spec in "$@"; do
    category="${spec%%:*}"
    reasons="${spec#*:}"
    assert_value "$manifest" \
      "NSPrivacyAccessedAPITypes.${api_index}.NSPrivacyAccessedAPIType" \
      "$category"

    IFS=',' read -r -a reason_values <<< "$reasons"
    reason_count="${#reason_values[@]}"
    assert_value "$manifest" \
      "NSPrivacyAccessedAPITypes.${api_index}.NSPrivacyAccessedAPITypeReasons" \
      "$reason_count"

    reason_index=0
    for reason in "${reason_values[@]}"; do
      assert_value "$manifest" \
        "NSPrivacyAccessedAPITypes.${api_index}.NSPrivacyAccessedAPITypeReasons.${reason_index}" \
        "$reason"
      reason_index=$((reason_index + 1))
    done
    api_index=$((api_index + 1))
  done
}

assert_project_resource() {
  local target="$1"
  local path="$2"
  ruby - "$PROJECT_SPEC" "$target" "$path" <<'RUBY' || \
    fail "project.yml must add exactly one $path source entry to $target with type: file and buildPhase: resources"
require "yaml"

spec_path, target_name, resource_path = ARGV
spec = YAML.safe_load(File.read(spec_path), aliases: true)
target = spec.fetch("targets", {}).fetch(target_name, {})
sources = target.fetch("sources", [])
matches = sources.select do |source|
  source.is_a?(Hash) && source["path"] == resource_path
end

exit(matches.length == 1 && matches.first["type"] == "file" && matches.first["buildPhase"] == "resources" ? 0 : 1)
RUBY
}

validate_sources() {
  validate_manifest "$APPLE_ROOT/Oppi/Resources/PrivacyInfo.xcprivacy" \
    "NSPrivacyAccessedAPICategoryUserDefaults:CA92.1,1C8F.1" \
    "NSPrivacyAccessedAPICategoryFileTimestamp:C617.1" \
    "NSPrivacyAccessedAPICategorySystemBootTime:35F9.1"
  validate_manifest "$APPLE_ROOT/OppiShareExtension/PrivacyInfo.xcprivacy" \
    "NSPrivacyAccessedAPICategoryUserDefaults:CA92.1,1C8F.1"

  [[ ! -e "$APPLE_ROOT/OppiActivityExtension/PrivacyInfo.xcprivacy" ]] || \
    fail "OppiActivityExtension does not use required-reason APIs in the audited Release executable"
  [[ ! -e "$APPLE_ROOT/OppiControlWidget/PrivacyInfo.xcprivacy" ]] || \
    fail "OppiControlWidget does not use required-reason APIs in the audited Release executable"

  assert_project_resource Oppi Oppi/Resources/PrivacyInfo.xcprivacy
  assert_project_resource OppiShareExtension OppiShareExtension/PrivacyInfo.xcprivacy
}

validate_archive() {
  local archive="$1"
  local app="$archive/Products/Applications/Oppi.app"
  [[ -d "$app" ]] || fail "archive does not contain Products/Applications/Oppi.app: $archive"

  local source_manifest archive_manifest
  local pairs=(
    "Oppi/Resources/PrivacyInfo.xcprivacy|$app/PrivacyInfo.xcprivacy"
    "OppiShareExtension/PrivacyInfo.xcprivacy|$app/PlugIns/OppiShareExtension.appex/PrivacyInfo.xcprivacy"
  )

  local pair
  for pair in "${pairs[@]}"; do
    source_manifest="$APPLE_ROOT/${pair%%|*}"
    archive_manifest="${pair#*|}"
    [[ -f "$archive_manifest" ]] || fail "archive is missing $archive_manifest"
    /usr/bin/plutil -lint "$archive_manifest" >/dev/null || \
      fail "archive contains an invalid manifest: $archive_manifest"
    cmp -s "$source_manifest" "$archive_manifest" || \
      fail "archived manifest differs from source: $archive_manifest"
  done

  [[ ! -e "$app/PlugIns/OppiActivityExtension.appex/PrivacyInfo.xcprivacy" ]] || \
    fail "archive has an unsupported OppiActivityExtension privacy declaration"
  [[ ! -e "$app/PlugIns/OppiControlWidget.appex/PrivacyInfo.xcprivacy" ]] || \
    fail "archive has an unsupported OppiControlWidget privacy declaration"

  echo "Archived privacy manifests:"
  while IFS= read -r manifest; do
    echo "  ${manifest#"$archive/"}"
  done < <(/usr/bin/find "$app" -type f -name PrivacyInfo.xcprivacy -print | sort)
}

run_self_test() (
  set -euo pipefail

  local fixture_root
  fixture_root="$(mktemp -d -t oppi-privacy-manifests.XXXXXX)"
  trap 'rm -rf "$fixture_root"' EXIT

  mkdir -p "$fixture_root/scripts" "$fixture_root/Oppi/Resources" "$fixture_root/OppiShareExtension"
  cp "$SCRIPT_DIR/check-privacy-manifests.sh" "$fixture_root/scripts/check-privacy-manifests.sh"
  cp "$APPLE_ROOT/Oppi/Resources/PrivacyInfo.xcprivacy" "$fixture_root/Oppi/Resources/PrivacyInfo.xcprivacy"
  cp "$APPLE_ROOT/OppiShareExtension/PrivacyInfo.xcprivacy" "$fixture_root/OppiShareExtension/PrivacyInfo.xcprivacy"

  cat > "$fixture_root/project.yml" <<'YAML'
targets:
  Oppi:
    sources:
      - path: Oppi/Resources/PrivacyInfo.xcprivacy
        type: file
        buildPhase: resources
  OppiShareExtension:
    sources:
      - path: OppiShareExtension/PrivacyInfo.xcprivacy
        type: file
        buildPhase: resources
YAML

  "$fixture_root/scripts/check-privacy-manifests.sh" >/dev/null

  cat > "$fixture_root/project.yml" <<'YAML'
targets:
  Oppi:
    sources:
      # - path: Oppi/Resources/PrivacyInfo.xcprivacy
      #   type: file
      #   buildPhase: resources
  OppiShareExtension:
    sources:
      - path: OppiShareExtension/PrivacyInfo.xcprivacy
        type: file
        buildPhase: resources
YAML
  if "$fixture_root/scripts/check-privacy-manifests.sh" >/dev/null 2>&1; then
    fail "self-test: commented-out resource membership passed"
  fi

  cat > "$fixture_root/project.yml" <<'YAML'
targets:
  WrongTarget:
    sources:
      - path: Oppi/Resources/PrivacyInfo.xcprivacy
        type: file
        buildPhase: resources
  OppiShareExtension:
    sources:
      - path: OppiShareExtension/PrivacyInfo.xcprivacy
        type: file
        buildPhase: resources
YAML
  if "$fixture_root/scripts/check-privacy-manifests.sh" >/dev/null 2>&1; then
    fail "self-test: wrong-target resource membership passed"
  fi

  cat > "$fixture_root/project.yml" <<'YAML'
targets:
  Oppi:
    sources:
      - path: Oppi/Resources/PrivacyInfo.xcprivacy
        type: file
  OppiShareExtension:
    sources:
      - path: OppiShareExtension/PrivacyInfo.xcprivacy
        type: file
        buildPhase: resources
YAML
  if "$fixture_root/scripts/check-privacy-manifests.sh" >/dev/null 2>&1; then
    fail "self-test: missing resources build phase passed"
  fi

  echo "Privacy manifest self-test passed."
)

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/check-privacy-manifests.sh
  ./scripts/check-privacy-manifests.sh self-test
  ./scripts/check-privacy-manifests.sh --archive PATH.xcarchive

The default mode validates the tracked manifest contents and parses project.yml
to verify exact target resource membership. Self-test exercises that membership
check against commented-out, wrong-target, and missing-build-phase fixtures.
Archive mode also verifies manifest placement and contents in the audited iOS
executable bundles. It does not scan executable API use or generate Apple's
merged privacy report.
USAGE
}

case "${1:-}" in
  "")
    [[ $# -eq 0 ]] || { usage >&2; exit 2; }
    validate_sources
    ;;
  self-test)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    validate_sources
    run_self_test
    ;;
  --archive)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    validate_sources
    validate_archive "$2"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

echo "Privacy manifest checks passed."
