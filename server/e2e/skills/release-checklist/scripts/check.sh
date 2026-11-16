#!/usr/bin/env bash
set -euo pipefail
git diff --quiet || { echo "Uncommitted changes"; exit 1; }
npm test
