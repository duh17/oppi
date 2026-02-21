#!/usr/bin/env bash
set -euo pipefail

# ─── TestFlight Build & Upload ───────────────────────────────────
#
# Builds a release archive, exports for App Store distribution,
# and uploads to App Store Connect / TestFlight.
#
# Prerequisites (one-time setup):
#   1. Apple Developer account (set OPPI_TEAM_ID or edit TEAM_ID below)
#   2. App Store Connect API key (.p8 file) with "Admin" or "App Manager" role
#   3. App created in App Store Connect matching your bundle ID in project.yml
#
# Setup:
#   mkdir -p ~/.appstoreconnect
#   mv ~/Downloads/AuthKey_XXXXXXXXXX.p8 ~/.appstoreconnect/
#   # Add to your shell profile:
#   export ASC_KEY_ID="XXXXXXXXXX"
#   export ASC_ISSUER_ID_FILE="$HOME/.appstoreconnect/issuer_id"  # preferred
#   # or: export ASC_ISSUER_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#   export OPPI_TEAM_ID="YOUR_TEAM_ID"   # optional, defaults to project.yml value
#
# Usage:
#   ios/scripts/testflight.sh              # build + upload
#   ios/scripts/testflight.sh --build-only # archive + export, skip upload
#   ios/scripts/testflight.sh --bump       # auto-increment build number
#   ios/scripts/testflight.sh --skip-generate  # skip xcodegen
# ──────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SCHEME="Oppi"
LOCAL_ENV_FILE="$IOS_DIR/.env.testflight.local"

# Preserve caller-provided env so local config can only fill defaults.
CALLER_HAS_ASC_KEY_ID="${ASC_KEY_ID+x}"
CALLER_ASC_KEY_ID="${ASC_KEY_ID-}"
CALLER_HAS_ASC_ISSUER_ID="${ASC_ISSUER_ID+x}"
CALLER_ASC_ISSUER_ID="${ASC_ISSUER_ID-}"
CALLER_HAS_ASC_ISSUER_ID_FILE="${ASC_ISSUER_ID_FILE+x}"
CALLER_ASC_ISSUER_ID_FILE="${ASC_ISSUER_ID_FILE-}"
CALLER_HAS_ASC_KEY_PATH="${ASC_KEY_PATH+x}"
CALLER_ASC_KEY_PATH="${ASC_KEY_PATH-}"
CALLER_HAS_OPPI_TEAM_ID="${OPPI_TEAM_ID+x}"
CALLER_OPPI_TEAM_ID="${OPPI_TEAM_ID-}"

# Optional local env file (gitignored) for developer-specific TestFlight config.
if [[ -f "$LOCAL_ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$LOCAL_ENV_FILE"
  set +a
fi

restore_caller_env() {
  local var_name="$1"
  local caller_set="$2"
  local caller_value="$3"
  local loaded_value="$4"

  if [[ -n "$caller_set" ]]; then
    if [[ "$loaded_value" != "$caller_value" ]]; then
      echo "warning: $LOCAL_ENV_FILE sets $var_name, but caller env takes precedence." >&2
    fi
    printf -v "$var_name" '%s' "$caller_value"
  fi
}

restore_caller_env "ASC_KEY_ID" "$CALLER_HAS_ASC_KEY_ID" "$CALLER_ASC_KEY_ID" "${ASC_KEY_ID-}"
restore_caller_env "ASC_ISSUER_ID" "$CALLER_HAS_ASC_ISSUER_ID" "$CALLER_ASC_ISSUER_ID" "${ASC_ISSUER_ID-}"
restore_caller_env "ASC_ISSUER_ID_FILE" "$CALLER_HAS_ASC_ISSUER_ID_FILE" "$CALLER_ASC_ISSUER_ID_FILE" "${ASC_ISSUER_ID_FILE-}"
restore_caller_env "ASC_KEY_PATH" "$CALLER_HAS_ASC_KEY_PATH" "$CALLER_ASC_KEY_PATH" "${ASC_KEY_PATH-}"
restore_caller_env "OPPI_TEAM_ID" "$CALLER_HAS_OPPI_TEAM_ID" "$CALLER_OPPI_TEAM_ID" "${OPPI_TEAM_ID-}"

TEAM_ID="${OPPI_TEAM_ID:-AZAQMY4SPZ}"

BUILD_ONLY=0
BUMP=0
SKIP_GENERATE=0
BUILD_NUMBER=""

usage() {
  cat <<'EOF'
Build, archive, and upload Oppi to TestFlight.

Usage:
  ios/scripts/testflight.sh [options]

Options:
  --build-only       Archive and export IPA, skip upload
  --bump             Auto-increment build number (CURRENT_PROJECT_VERSION)
  --build-number N   Set explicit build number
  --skip-generate    Skip xcodegen generate
  -h, --help         Show this help

Environment:
  ASC_KEY_ID                     App Store Connect API Key ID
  ASC_ISSUER_ID                  App Store Connect Issuer ID (optional if ASC_ISSUER_ID_FILE set)
  ASC_ISSUER_ID_FILE             Path to file containing issuer UUID (default: ~/.appstoreconnect/issuer_id)
  ASC_KEY_PATH                   Path to AuthKey .p8 file (optional, auto-detected)
  AUTO_EXPORT_COMPLIANCE         Auto-set export compliance after upload (default: 1)
  ASC_USES_NON_EXEMPT_ENCRYPTION Export compliance value (default: false)
  REQUIRE_EXPORT_COMPLIANCE      Fail script if compliance update fails (default: 0)
  ASC_COMPLIANCE_WAIT_SECONDS    Wait for uploaded build to appear in ASC (default: 300)
  ASC_COMPLIANCE_POLL_SECONDS    Poll interval while waiting (default: 5)
  DISABLE_SENTRY_FOR_TESTFLIGHT  Force Sentry DSN empty for public builds (default: 1)

Local config file (optional, gitignored):
  ios/.env.testflight.local

Precedence:
  Caller env vars override ios/.env.testflight.local values.
EOF
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only) BUILD_ONLY=1; shift ;;
    --bump) BUMP=1; shift ;;
    --build-number) BUILD_NUMBER="$2"; shift 2 ;;
    --skip-generate) SKIP_GENERATE=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1"; usage 1 ;;
  esac
done

# Public/TestFlight builds should ship without third-party crash telemetry.
if [[ "${DISABLE_SENTRY_FOR_TESTFLIGHT:-1}" == "1" ]]; then
  export SENTRY_DSN=""
  echo "── Sentry DSN: disabled for TestFlight build"
fi

# ─── Resolve API key ────────────────────────────────────────────

resolve_asc_key() {
  if [[ -n "${ASC_KEY_PATH:-}" && -f "$ASC_KEY_PATH" ]]; then
    return 0
  fi

  if [[ -n "${ASC_KEY_ID:-}" ]]; then
    local candidates=(
      "$HOME/.appstoreconnect/AuthKey_${ASC_KEY_ID}.p8"
      "$HOME/.private_keys/AuthKey_${ASC_KEY_ID}.p8"
      "$HOME/AuthKey_${ASC_KEY_ID}.p8"
    )
    for path in "${candidates[@]}"; do
      if [[ -f "$path" ]]; then
        ASC_KEY_PATH="$path"
        return 0
      fi
    done
  fi

  # Search for any .p8 key
  for dir in "$HOME/.appstoreconnect" "$HOME/.private_keys"; do
    if [[ -d "$dir" ]]; then
      local found
      found=$(find "$dir" -name "AuthKey_*.p8" -print -quit 2>/dev/null)
      if [[ -n "$found" ]]; then
        ASC_KEY_PATH="$found"
        local basename
        basename=$(basename "$found" .p8)
        ASC_KEY_ID="${ASC_KEY_ID:-${basename#AuthKey_}}"
        return 0
      fi
    fi
  done

  return 1
}

resolve_asc_issuer() {
  if [[ -n "${ASC_ISSUER_ID:-}" ]]; then
    return 0
  fi

  local issuer_file="${ASC_ISSUER_ID_FILE:-$HOME/.appstoreconnect/issuer_id}"
  if [[ ! -f "$issuer_file" ]]; then
    return 1
  fi

  local issuer
  issuer=$(tr -d '[:space:]' < "$issuer_file")
  if [[ "$issuer" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    ASC_ISSUER_ID="$issuer"
    ASC_ISSUER_ID_FILE="$issuer_file"
    return 0
  fi

  echo "error: Invalid ASC issuer ID format in $issuer_file" >&2
  return 1
}

if ! resolve_asc_key; then
  echo "error: No App Store Connect API key found."
  echo ""
  echo "One-time setup:"
  echo "  1. Go to https://appstoreconnect.apple.com/access/integrations/api"
  echo "  2. Create a new key with 'Admin' or 'App Manager' role"
  echo "  3. Download the .p8 file"
  echo "  4. mkdir -p ~/.appstoreconnect"
  echo "  5. mv ~/Downloads/AuthKey_XXXXXXXX.p8 ~/.appstoreconnect/"
  echo "  6. export ASC_KEY_ID=XXXXXXXX"
  echo "  7. export ASC_ISSUER_ID=xxxxxxxx-xxxx-... (shown on the API keys page)"
  echo ""
  exit 1
fi

if ! resolve_asc_issuer; then
  echo "error: ASC issuer ID is missing."
  echo "  Option 1: export ASC_ISSUER_ID=<your-issuer-id>"
  echo "  Option 2 (preferred):"
  echo "    mkdir -p ~/.appstoreconnect"
  echo "    printf '%s\n' '<your-issuer-id>' > ~/.appstoreconnect/issuer_id"
  echo "    chmod 600 ~/.appstoreconnect/issuer_id"
  echo "    export ASC_ISSUER_ID_FILE=~/.appstoreconnect/issuer_id"
  exit 1
fi

if [[ -z "${ASC_KEY_ID:-}" ]]; then
  echo "error: ASC_KEY_ID must be set."
  echo "  export ASC_KEY_ID=<your-key-id>"
  exit 1
fi

echo "── API Key: $ASC_KEY_ID (${ASC_KEY_PATH})"

apply_export_compliance() {
  local auto="${AUTO_EXPORT_COMPLIANCE:-1}"
  if [[ "$auto" == "0" ]]; then
    echo "── Skipping export compliance (AUTO_EXPORT_COMPLIANCE=0)"
    return 0
  fi

  if ! command -v node >/dev/null 2>&1; then
    echo "warning: node not found; cannot auto-set export compliance" >&2
    if [[ "${REQUIRE_EXPORT_COMPLIANCE:-0}" == "1" ]]; then
      echo "error: REQUIRE_EXPORT_COMPLIANCE=1 but node is unavailable" >&2
      exit 1
    fi
    return 0
  fi

  local bundle_id
  bundle_id=$(grep 'PRODUCT_BUNDLE_IDENTIFIER:' project.yml | head -1 | awk '{print $2}')
  if [[ -z "$bundle_id" ]]; then
    echo "warning: failed to resolve bundle id from project.yml; skipping export compliance" >&2
    if [[ "${REQUIRE_EXPORT_COMPLIANCE:-0}" == "1" ]]; then
      echo "error: REQUIRE_EXPORT_COMPLIANCE=1 and bundle id resolution failed" >&2
      exit 1
    fi
    return 0
  fi

  echo "── Setting export compliance for $bundle_id (usesNonExemptEncryption=${ASC_USES_NON_EXEMPT_ENCRYPTION:-false})"

  local compliance_output
  if ! compliance_output=$(ASC_KEY_ID="$ASC_KEY_ID" \
      ASC_ISSUER_ID="$ASC_ISSUER_ID" \
      ASC_KEY_PATH="$ASC_KEY_PATH" \
      ASC_BUNDLE_ID="$bundle_id" \
      ASC_BUILD_NUMBER="$BUILD_NUMBER" \
      ASC_USES_NON_EXEMPT_ENCRYPTION="${ASC_USES_NON_EXEMPT_ENCRYPTION:-false}" \
      ASC_COMPLIANCE_WAIT_SECONDS="${ASC_COMPLIANCE_WAIT_SECONDS:-300}" \
      ASC_COMPLIANCE_POLL_SECONDS="${ASC_COMPLIANCE_POLL_SECONDS:-5}" \
      node <<'NODE'
const fs = require("node:fs");
const crypto = require("node:crypto");

const keyId = process.env.ASC_KEY_ID;
const issuer = process.env.ASC_ISSUER_ID;
const keyPath = process.env.ASC_KEY_PATH;
const bundleId = process.env.ASC_BUNDLE_ID;
const buildNumber = process.env.ASC_BUILD_NUMBER;
const waitSeconds = Number(process.env.ASC_COMPLIANCE_WAIT_SECONDS || "300");
const pollSeconds = Number(process.env.ASC_COMPLIANCE_POLL_SECONDS || "5");

if (!keyId || !issuer || !keyPath || !bundleId || !buildNumber) {
  throw new Error("missing required ASC env for export compliance update");
}

const toBool = (value, fallback = false) => {
  if (value === undefined || value === null || value === "") return fallback;
  const v = String(value).trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(v)) return true;
  if (["0", "false", "no", "off"].includes(v)) return false;
  return fallback;
};
const usesNonExemptEncryption = toBool(process.env.ASC_USES_NON_EXEMPT_ENCRYPTION, false);

const b64url = (input) =>
  Buffer.from(input)
    .toString("base64")
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");

function token() {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "ES256", kid: keyId, typ: "JWT" }));
  const payload = b64url(
    JSON.stringify({ iss: issuer, exp: now + 600, aud: "appstoreconnect-v1" }),
  );
  const unsigned = `${header}.${payload}`;
  const sign = crypto.createSign("sha256");
  sign.update(unsigned);
  sign.end();
  const sig = sign.sign({ key: fs.readFileSync(keyPath, "utf8"), dsaEncoding: "ieee-p1363" });
  return `${unsigned}.${b64url(sig)}`;
}

async function asc(method, path, query = undefined, body = undefined) {
  const url = new URL(`https://api.appstoreconnect.apple.com${path}`);
  if (query) {
    for (const [key, value] of Object.entries(query)) {
      url.searchParams.set(key, String(value));
    }
  }

  const res = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${token()}`,
      "Content-Type": "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
  });

  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    // non-json response
  }

  if (!res.ok) {
    const detail = json?.errors?.[0]?.detail || text.slice(0, 240);
    if (res.status === 409) {
      return { _conflict: true, status: 409, detail };
    }
    throw new Error(`${method} ${url.pathname} failed (${res.status}): ${detail}`);
  }

  return json;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

(async () => {
  const appResp = await asc("GET", "/v1/apps", {
    "filter[bundleId]": bundleId,
    limit: 1,
  });

  const appId = appResp?.data?.[0]?.id;
  if (!appId) throw new Error(`app not found for bundle id ${bundleId}`);

  const deadline = Date.now() + waitSeconds * 1000;
  let build = null;

  while (Date.now() <= deadline) {
    const buildResp = await asc("GET", "/v1/builds", {
      "filter[app]": appId,
      "filter[version]": buildNumber,
      sort: "-uploadedDate",
      limit: 1,
    });

    build = buildResp?.data?.[0] ?? null;
    if (build) break;
    await sleep(Math.max(1, pollSeconds) * 1000);
  }

  if (!build?.id) {
    throw new Error(`build ${buildNumber} not found for app ${bundleId} within ${waitSeconds}s`);
  }

  // Check if compliance is already set on this build
  const currentEncryption = build.attributes?.usesNonExemptEncryption;
  if (currentEncryption !== null && currentEncryption !== undefined) {
    console.log(
      `   export compliance already set: build ${buildNumber}, usesNonExemptEncryption=${currentEncryption}`,
    );
  } else {
    const patchResp = await asc("PATCH", `/v1/builds/${build.id}`, undefined, {
      data: {
        type: "builds",
        id: build.id,
        attributes: {
          usesNonExemptEncryption,
        },
      },
    });

    if (patchResp?._conflict) {
      console.log(
        `   export compliance already set (409): build ${buildNumber}`,
      );
    } else {
      const patched = patchResp?.data?.attributes || {};
      console.log(
        `   export compliance set: build ${buildNumber}, usesNonExemptEncryption=${patched.usesNonExemptEncryption ?? usesNonExemptEncryption}`,
      );
    }
  }

  const detailsResp = await asc("GET", "/v1/buildBetaDetails", {
    "filter[build]": build.id,
    limit: 1,
  });

  const detail = detailsResp?.data?.[0]?.attributes || {};
  if (detail.internalBuildState || detail.externalBuildState) {
    console.log(
      `   beta states: internal=${detail.internalBuildState ?? "unknown"}, external=${detail.externalBuildState ?? "unknown"}`,
    );
  }
})();
NODE
  ); then
    echo "warning: export compliance update failed" >&2
    if [[ "${REQUIRE_EXPORT_COMPLIANCE:-0}" == "1" ]]; then
      echo "error: REQUIRE_EXPORT_COMPLIANCE=1 and export compliance update failed" >&2
      exit 1
    fi
    return 0
  fi

  echo "$compliance_output"
}

# Common xcodebuild auth flags — used for archive, export, and upload.
# This lets xcodebuild auto-create Distribution certificates and profiles.
AUTH_FLAGS=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$ASC_KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
)

# ─── Directories ─────────────────────────────────────────────────

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BUILD_DIR="$IOS_DIR/build/testflight-$TIMESTAMP"
ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"

mkdir -p "$BUILD_DIR"

# ─── Version bump ────────────────────────────────────────────────

cd "$IOS_DIR"

if [[ -n "$BUILD_NUMBER" ]]; then
  echo "── Setting build number: $BUILD_NUMBER"
  sed -i '' "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: $BUILD_NUMBER/" project.yml
elif [[ "$BUMP" -eq 1 ]]; then
  CURRENT=$(grep 'CURRENT_PROJECT_VERSION:' project.yml | head -1 | awk '{print $2}')
  NEXT=$((CURRENT + 1))
  echo "── Bumping build number: $CURRENT → $NEXT"
  sed -i '' "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: $NEXT/" project.yml
  BUILD_NUMBER="$NEXT"
else
  BUILD_NUMBER=$(grep 'CURRENT_PROJECT_VERSION:' project.yml | head -1 | awk '{print $2}')
fi

VERSION=$(grep 'MARKETING_VERSION:' project.yml | head -1 | sed 's/.*"\(.*\)"/\1/')
echo "── Version: $VERSION ($BUILD_NUMBER)"

# ─── Generate project ───────────────────────────────────────────

if [[ "$SKIP_GENERATE" -eq 0 ]]; then
  echo "── Generating Xcode project..."
  xcodegen generate
fi

# ─── Archive ─────────────────────────────────────────────────────

echo "── Archiving $SCHEME (Release)..."

ARCHIVE_LOG="$BUILD_DIR/archive.log"

xcodebuild archive \
  -project Oppi.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=iOS" \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  SENTRY_DSN="${SENTRY_DSN:-}" \
  "${AUTH_FLAGS[@]}" \
  2>&1 | tee "$ARCHIVE_LOG" | tail -5

if [[ ! -d "$ARCHIVE_PATH" ]]; then
  echo "error: Archive failed. Full log: $ARCHIVE_LOG"
  exit 1
fi

echo "── Archive OK"

# ─── Export Options plist ────────────────────────────────────────

cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>destination</key>
    <string>upload</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
    <key>compileBitcode</key>
    <false/>
</dict>
</plist>
PLIST

# ─── Export IPA ──────────────────────────────────────────────────

echo "── Exporting IPA..."

EXPORT_LOG="$BUILD_DIR/export.log"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  "${AUTH_FLAGS[@]}" \
  2>&1 | tee "$EXPORT_LOG" | tail -5

# With destination=upload, xcodebuild uploads directly during export.
# Check if export log confirms success (no local IPA created in this mode).
if grep -q "EXPORT SUCCEEDED" "$EXPORT_LOG"; then
  if grep -q "Upload succeeded" "$EXPORT_LOG"; then
    apply_export_compliance
    echo ""
    echo "── Done! Version $VERSION ($BUILD_NUMBER) uploaded via cloud signing."
    echo "   TestFlight build available in ~5-15 minutes."
    echo "   https://appstoreconnect.apple.com/apps"
    exit 0
  fi
fi

# Fallback: check for local IPA (build-only or non-upload destination)
IPA_PATH="$EXPORT_DIR/$SCHEME.ipa"
if [[ ! -f "$IPA_PATH" ]]; then
  echo "error: Export failed. Full log: $EXPORT_LOG"
  exit 1
fi

echo "── IPA: $IPA_PATH ($(du -h "$IPA_PATH" | cut -f1))"

if [[ "$BUILD_ONLY" -eq 1 ]]; then
  echo ""
  echo "── Build complete (--build-only). IPA at:"
  echo "   $IPA_PATH"
  exit 0
fi

echo "── Uploading to App Store Connect..."

xcrun altool --upload-package "$IPA_PATH" \
  -t ios \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID" \
  2>&1

apply_export_compliance

echo ""
echo "── Done! Version $VERSION ($BUILD_NUMBER) uploaded."
echo "   TestFlight build available in ~5-15 minutes."
echo "   https://appstoreconnect.apple.com/apps"
