#!/bin/bash
# Load API keys from macOS Keychain and start oppi-server server
#
# Keys must be stored in Keychain:
#   security add-generic-password -a "$USER" -s "OPENROUTER_API_KEY" -w "value" -U
#
# This script is used by launchd which doesn't inherit shell env vars.

set -e

# Load secrets from Keychain
load_secret() {
    local key_name="$1"
    local value
    value=$(security find-generic-password -a "$USER" -s "$key_name" -w 2>/dev/null) || return 0
    if [ -n "$value" ]; then
        export "$key_name"="$value"
    fi
}

load_secret OPENROUTER_API_KEY

# Start oppi-server server
cd /path/to/pios/oppi-server
exec npx tsx src/cli.ts serve "$@"
