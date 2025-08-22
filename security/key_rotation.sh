#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Simple key rotation helper for local encrypted credential store.
# - rotates key for a service and re-encrypts all username entries

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYS_DIR="$ROOT_DIR/.keys"
CRED_DIR="$ROOT_DIR/.credentials"

source "$ROOT_DIR/security/encryption_utils.sh"

rotate_key_for_service() {
    local service="$1"
    local old_key="$KEYS_DIR/$service.key"
    local new_key_temp
    new_key_temp=$(mktemp)
    generate_key_file "$new_key_temp"

    if [[ ! -f "$old_key" ]]; then
        echo "no existing key for $service" >&2
        mv "$new_key_temp" "$old_key"
        chmod 600 "$old_key"
        return 0
    fi

    # Re-encrypt each credential file for the service
    for enc in "$CRED_DIR/$service-"*.enc; do
        [[ -f "$enc" ]] || continue
        local basename
        basename=$(basename "$enc")
        local username
        username=${basename#${service}-}
        username=${username%.enc}

        local plaintext
        plaintext=$(decrypt_from_base64_string "$(cat "$enc")" "$old_key")
        mv "$new_key_temp" "$old_key"
        chmod 600 "$old_key"
        echo -n "$plaintext" | encrypt_to_base64_string "$old_key" > "$enc"
        chmod 600 "$enc"
    done
}
