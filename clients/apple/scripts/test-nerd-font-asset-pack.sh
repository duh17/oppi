#!/usr/bin/env bash
# Proves the NerdFontSymbols asset pack downloads and installs before it goes to
# App Store Connect: Apple's mock server (xcrun ba-serve) serves
# build/asset-packs/NerdFontSymbols.aar to a throwaway simulator, the Debug app
# launches, and the script waits for the app's "Nerd Font symbols installed" log.
#
# Uses a throwaway CA and localhost certificate in a temporary keychain, a
# dedicated simulator with the Background Assets URL override, and its own
# DerivedData. Everything is removed on exit; the login keychain is untouched
# apart from restoring the original search list.
#
# Usage: clients/apple/scripts/test-nerd-font-asset-pack.sh
#   (run build-nerd-font-asset-pack.sh first)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=xcode-toolchain.sh
source "$SCRIPT_DIR/xcode-toolchain.sh"
oppi_use_xcode_toolchain
APPLE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACK="$APPLE_ROOT/build/asset-packs/NerdFontSymbols.aar"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/oppi-asset-pack.XXXXXX")"
PORT=61289
KEYCHAIN="$WORK/mock.keychain-db"
BUNDLE_ID="dev.chenda.Oppi"
TIMEOUT=120

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ -f "$PACK" ]] || fail "missing $PACK; run scripts/build-nerd-font-asset-pack.sh first"

ORIGINAL_KEYCHAINS=()
while IFS= read -r line; do
  line="${line//\"/}"
  ORIGINAL_KEYCHAINS+=("${line// /}")
done < <(security list-keychains -d user)

UDID=""
SERVER_PID=""
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" 2>/dev/null || true
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  if [[ -n "$UDID" ]]; then
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
    xcrun simctl delete "$UDID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# 1. Throwaway CA and localhost server identity for the HTTPS mock server.
cd "$WORK"
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 1 -subj "/CN=Oppi Asset Pack Mock CA" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr -subj "/CN=localhost" 2>/dev/null
printf '%s\n' "basicConstraints=CA:FALSE" "keyUsage=critical,digitalSignature,keyEncipherment" \
  "extendedKeyUsage=serverAuth" "subjectAltName=DNS:localhost" > leaf.ext
openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out leaf.pem -days 1 -extfile leaf.ext 2>/dev/null
openssl pkcs12 -export -legacy -inkey leaf.key -in leaf.pem -certfile ca.pem -out leaf.p12 -passout pass:oppi 2>/dev/null ||
  openssl pkcs12 -export -inkey leaf.key -in leaf.pem -certfile ca.pem -out leaf.p12 -passout pass:oppi
security create-keychain -p oppi "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p oppi "$KEYCHAIN"
security import leaf.p12 -k "$KEYCHAIN" -P oppi -A -f pkcs12 >/dev/null
security set-key-partition-list -S apple-tool:,apple:,unsigned: -s -k oppi "$KEYCHAIN" >/dev/null
# ba-serve looks up its identity through the user search list.
security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" "$KEYCHAIN"

# 2. Mock server.
xcrun ba-serve --host localhost --port "$PORT" --choose-identity-automatically "$PACK" > server.log 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 20); do
  curl -s --cacert ca.pem -o /dev/null "https://localhost:$PORT/" && break
  sleep 0.5
done
curl -s --cacert ca.pem -o /dev/null "https://localhost:$PORT/" || { cat server.log; fail "mock server did not start"; }

# 3. URL override value, encoded exactly as `ba-serve url-override` writes it.
#    Set and clear it on the Mac only to capture the archived NSURL.
xcrun ba-serve url-override "https://localhost:$PORT" >/dev/null
OVERRIDE_HEX="$(defaults export com.apple.backgroundassets.managed - |
  plutil -extract MBAURLOverride raw -o - - | base64 -d | xxd -p | tr -d '\n')"
xcrun ba-serve url-override --clear >/dev/null

# 4. Dedicated simulator that trusts the CA and downloads from the mock server.
RUNTIME="$(xcrun simctl list runtimes -j | jq -r '[.runtimes[] | select(.platform=="iOS" and .isAvailable)] | last | .identifier')"
DEVICE_TYPE="$(xcrun simctl list devicetypes -j | jq -r '[.devicetypes[] | select(.name | test("^iPhone [0-9]+ Pro$"))] | last | .identifier')"
UDID="$(xcrun simctl create oppi-asset-pack "$DEVICE_TYPE" "$RUNTIME")"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl keychain "$UDID" add-root-cert ca.pem
xcrun simctl spawn "$UDID" defaults write com.apple.backgroundassets.managed MBAURLOverride -data "$OVERRIDE_HEX"

# 5. Build, install, launch, and wait for the install log.
echo "Building the Debug app for the simulator…"
(cd "$APPLE_ROOT" && xcodebuild -project Oppi.xcodeproj -scheme Oppi -configuration Debug \
  -destination "id=$UDID" -derivedDataPath "$WORK/dd" build > "$WORK/build.log" 2>&1) ||
  { tail -30 "$WORK/build.log"; fail "build failed"; }
xcrun simctl install "$UDID" "$WORK/dd/Build/Products/Debug-iphonesimulator/Oppi.app"
xcrun simctl spawn "$UDID" log stream --level info \
  --predicate "subsystem == \"$BUNDLE_ID\" AND category == \"NerdFontSymbols\"" > app.log 2>&1 &
LOG_PID=$!
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null

result=1
for _ in $(seq 1 "$TIMEOUT"); do
  if grep -q "Nerd Font symbols installed" app.log; then result=0; break; fi
  if grep -q "Nerd Font symbols unavailable" app.log; then break; fi
  sleep 1
done
kill "$LOG_PID" 2>/dev/null || true
grep -E "Nerd Font symbols" app.log || true
if [[ $result -ne 0 ]]; then
  echo "--- mock server log"; tail -20 server.log
  fail "the app did not install Nerd Font symbols from the mock server within ${TIMEOUT}s"
fi
echo "ok: NerdFontSymbols downloaded from the mock server and installed"
