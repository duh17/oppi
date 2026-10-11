#!/usr/bin/env bash
# Regenerate the push test vectors (protocol/push/spec.md §7). Ordinary tests never run this.
# CryptoKit first: the server generator seals to the CryptoKit-derived recipient key.
# Needs macOS 14+ (CryptoKit HPKE) and `npm ci` in server/.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
vectors="$root/protocol/push/vectors"
mkdir -p "$vectors"

xcrun swift "$root/protocol/push/scripts/cryptokit-vectors.swift" > "$vectors/cryptokit-hpke.json.tmp"
mv "$vectors/cryptokit-hpke.json.tmp" "$vectors/cryptokit-hpke.json"

cd "$root/server"
npx tsx scripts/generate-push-vectors.ts
