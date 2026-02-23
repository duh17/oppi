#!/usr/bin/env bash
set -euo pipefail

# ─── TestFlight Beta Tester Invite ───────────────────────────────
#
# Adds a tester to a TestFlight beta group for a specific build.
#
# Usage:
#   ios/scripts/testflight-invite.sh <email> [--build <number>] [--group <name>]
#
# Defaults:
#   --build   latest uploaded build
#   --group   "Internal Testers"
# ──────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LOCAL_ENV_FILE="$IOS_DIR/.env.testflight.local"

# Preserve caller env before sourcing local config
_CALLER_ASC_KEY_ID="${ASC_KEY_ID-}"
_CALLER_ASC_KEY_PATH="${ASC_KEY_PATH-}"
_CALLER_ASC_ISSUER_ID="${ASC_ISSUER_ID-}"
_CALLER_HAS_KEY_ID="${ASC_KEY_ID+x}"
_CALLER_HAS_KEY_PATH="${ASC_KEY_PATH+x}"
_CALLER_HAS_ISSUER="${ASC_ISSUER_ID+x}"

# Load local env if present (fills defaults)
if [[ -f "$LOCAL_ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$LOCAL_ENV_FILE"
  set +a
fi

# Restore caller env (takes precedence over local config)
[[ -n "$_CALLER_HAS_KEY_ID" ]] && ASC_KEY_ID="$_CALLER_ASC_KEY_ID"
[[ -n "$_CALLER_HAS_KEY_PATH" ]] && ASC_KEY_PATH="$_CALLER_ASC_KEY_PATH"
[[ -n "$_CALLER_HAS_ISSUER" ]] && ASC_ISSUER_ID="$_CALLER_ASC_ISSUER_ID"

# ─── Args ────────────────────────────────────────────────────────

EMAIL=""
BUILD_NUMBER=""
GROUP_NAME="Internal Testers"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD_NUMBER="$2"; shift 2 ;;
    --group) GROUP_NAME="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: testflight-invite.sh <email> [--build <N>] [--group <name>]"
      exit 0
      ;;
    -*)
      echo "Unknown option: $1"; exit 1 ;;
    *)
      EMAIL="$1"; shift ;;
  esac
done

if [[ -z "$EMAIL" ]]; then
  echo "error: email required"
  echo "Usage: testflight-invite.sh <email> [--build <N>] [--group <name>]"
  exit 1
fi

# ─── Resolve API key (same logic as testflight.sh) ──────────────

resolve_asc_key() {
  if [[ -n "${ASC_KEY_PATH:-}" && -f "$ASC_KEY_PATH" ]]; then return 0; fi
  if [[ -n "${ASC_KEY_ID:-}" ]]; then
    local candidates=(
      "$HOME/.appstoreconnect/AuthKey_${ASC_KEY_ID}.p8"
      "$HOME/.private_keys/AuthKey_${ASC_KEY_ID}.p8"
    )
    for path in "${candidates[@]}"; do
      if [[ -f "$path" ]]; then ASC_KEY_PATH="$path"; return 0; fi
    done
  fi
  for dir in "$HOME/.appstoreconnect" "$HOME/.private_keys"; do
    if [[ -d "$dir" ]]; then
      local found
      found=$(find "$dir" -name "AuthKey_*.p8" -print -quit 2>/dev/null)
      if [[ -n "$found" ]]; then
        ASC_KEY_PATH="$found"
        local basename; basename=$(basename "$found" .p8)
        ASC_KEY_ID="${ASC_KEY_ID:-${basename#AuthKey_}}"
        return 0
      fi
    fi
  done
  return 1
}

resolve_asc_issuer() {
  if [[ -n "${ASC_ISSUER_ID:-}" ]]; then return 0; fi
  local issuer_file="${ASC_ISSUER_ID_FILE:-$HOME/.appstoreconnect/issuer_id}"
  if [[ ! -f "$issuer_file" ]]; then return 1; fi
  local issuer; issuer=$(tr -d '[:space:]' < "$issuer_file")
  if [[ "$issuer" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    ASC_ISSUER_ID="$issuer"
    return 0
  fi
  return 1
}

if ! resolve_asc_key; then echo "error: no ASC API key found"; exit 1; fi
if ! resolve_asc_issuer; then echo "error: no ASC issuer ID found"; exit 1; fi

echo "── API Key: $ASC_KEY_ID"
echo "── Tester: $EMAIL"
echo "── Group: $GROUP_NAME"
[[ -n "$BUILD_NUMBER" ]] && echo "── Build: $BUILD_NUMBER"

# ─── ASC API via Node ────────────────────────────────────────────

BUNDLE_ID=$(grep 'PRODUCT_BUNDLE_IDENTIFIER:' "$IOS_DIR/project.yml" | head -1 | awk '{print $2}')

ASC_KEY_ID="$ASC_KEY_ID" \
ASC_ISSUER_ID="$ASC_ISSUER_ID" \
ASC_KEY_PATH="$ASC_KEY_PATH" \
BUNDLE_ID="$BUNDLE_ID" \
BUILD_NUMBER="$BUILD_NUMBER" \
GROUP_NAME="$GROUP_NAME" \
TESTER_EMAIL="$EMAIL" \
node <<'NODE'
const fs = require("node:fs");
const crypto = require("node:crypto");

const keyId = process.env.ASC_KEY_ID;
const issuer = process.env.ASC_ISSUER_ID;
const keyPath = process.env.ASC_KEY_PATH;
const bundleId = process.env.BUNDLE_ID;
const buildNumber = process.env.BUILD_NUMBER;
const groupName = process.env.GROUP_NAME;
const testerEmail = process.env.TESTER_EMAIL;

const b64url = (input) =>
  Buffer.from(input).toString("base64").replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");

function token() {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "ES256", kid: keyId, typ: "JWT" }));
  const payload = b64url(JSON.stringify({ iss: issuer, exp: now + 600, aud: "appstoreconnect-v1" }));
  const unsigned = `${header}.${payload}`;
  const sign = crypto.createSign("sha256");
  sign.update(unsigned);
  sign.end();
  const sig = sign.sign({ key: fs.readFileSync(keyPath, "utf8"), dsaEncoding: "ieee-p1363" });
  return `${unsigned}.${b64url(sig)}`;
}

async function asc(method, path, query, body) {
  const url = new URL(`https://api.appstoreconnect.apple.com${path}`);
  if (query) for (const [k, v] of Object.entries(query)) url.searchParams.set(k, String(v));
  const res = await fetch(url, {
    method,
    headers: { Authorization: `Bearer ${token()}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json; try { json = JSON.parse(text); } catch {}
  if (!res.ok && res.status !== 409) {
    const detail = json?.errors?.[0]?.detail || text.slice(0, 400);
    throw new Error(`${method} ${url.pathname} (${res.status}): ${detail}`);
  }
  return { ok: res.ok, status: res.status, data: json };
}

(async () => {
  // 1. Find app
  const appResp = await asc("GET", "/v1/apps", { "filter[bundleId]": bundleId, limit: 1 });
  const appId = appResp.data?.data?.[0]?.id;
  if (!appId) throw new Error(`app not found: ${bundleId}`);
  console.log(`   app: ${appId}`);

  // 2. Find or create beta group
  const groupsResp = await asc("GET", "/v1/betaGroups", {
    "filter[app]": appId, "filter[name]": groupName, limit: 1
  });
  let groupId = groupsResp.data?.data?.[0]?.id;

  if (!groupId) {
    console.log(`   creating beta group "${groupName}"...`);
    const createResp = await asc("POST", "/v1/betaGroups", undefined, {
      data: {
        type: "betaGroups",
        attributes: { name: groupName, isInternalGroup: true },
        relationships: { app: { data: { type: "apps", id: appId } } }
      }
    });
    groupId = createResp.data?.data?.id;
    if (!groupId) throw new Error("failed to create beta group");
  }
  console.log(`   group: ${groupId} (${groupName})`);

  // 3. Find or create beta tester
  const testerResp = await asc("GET", "/v1/betaTesters", {
    "filter[email]": testerEmail, "filter[apps]": appId, limit: 1
  });
  let testerId = testerResp.data?.data?.[0]?.id;

  if (!testerId) {
    console.log(`   inviting ${testerEmail}...`);
    const inviteResp = await asc("POST", "/v1/betaTesters", undefined, {
      data: {
        type: "betaTesters",
        attributes: { email: testerEmail, firstName: "", lastName: "" },
        relationships: {
          betaGroups: { data: [{ type: "betaGroups", id: groupId }] }
        }
      }
    });
    if (inviteResp.status === 409) {
      // Already exists globally, look up again without app filter
      const globalResp = await asc("GET", "/v1/betaTesters", {
        "filter[email]": testerEmail, limit: 1
      });
      testerId = globalResp.data?.data?.[0]?.id;
    } else {
      testerId = inviteResp.data?.data?.id;
    }
  }

  if (!testerId) throw new Error(`failed to find/create tester ${testerEmail}`);
  console.log(`   tester: ${testerId}`);

  // 4. Add tester to group
  const addToGroup = await asc("POST", `/v1/betaGroups/${groupId}/relationships/betaTesters`, undefined, {
    data: [{ type: "betaTesters", id: testerId }]
  });
  if (addToGroup.status === 409 || addToGroup.ok) {
    console.log(`   tester added to group`);
  }

  // 5. Find build and add to group (if build specified)
  if (buildNumber) {
    const buildResp = await asc("GET", "/v1/builds", {
      "filter[app]": appId, "filter[version]": buildNumber, sort: "-uploadedDate", limit: 1
    });
    const build = buildResp.data?.data?.[0];
    if (!build) {
      console.log(`   warning: build ${buildNumber} not found (may still be processing)`);
    } else {
      console.log(`   build: ${build.id} (${buildNumber}), processing: ${build.attributes?.processingState}`);

      const addBuild = await asc("POST", `/v1/betaGroups/${groupId}/relationships/builds`, undefined, {
        data: [{ type: "builds", id: build.id }]
      });
      if (addBuild.status === 409 || addBuild.ok) {
        console.log(`   build added to group`);
      }
    }
  }

  console.log(`\n── Done! ${testerEmail} invited to "${groupName}" for ${bundleId}`);
})();
NODE
