#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt


# Placeholder for HashiCorp Vault integration
# This file provides minimal helpers to read/write secrets from a Vault server.

VAULT_ADDR_DEFAULT="http://127.0.0.1:8200"

vault_read_secret() {
    local path="$1"
    local key="${2:-}" # optional specific key in the secret
    local addr="${VAULT_ADDR:-$VAULT_ADDR_DEFAULT}"

    if ! command -v vault >/dev/null 2>&1; then
        echo "vault CLI not available" >&2
        return 2
    fi

    if [[ -z "$key" ]]; then
        vault kv get -format=json "$path" | jq -r '.data.data'
    else
        vault kv get -format=json "$path" | jq -r --arg k "$key" '.data.data[$k]'
    fi
}

vault_write_secret() {
    local path="$1"
    shift
    if ! command -v vault >/dev/null 2>&1; then
        echo "vault CLI not available" >&2
        return 2
    fi
    # expects key=value pairs
    vault kv put "$path" "$@"
}
