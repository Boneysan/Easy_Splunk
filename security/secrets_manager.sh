#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt


# Lightweight secrets manager for Easy_Splunk
# - prefers system keyring via `secret-tool` when available
# - falls back to encrypted files under .credentials with key material in .keys

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYS_DIR="$ROOT_DIR/.keys"
CRED_DIR="$ROOT_DIR/.credentials"

source "$ROOT_DIR/security/encryption_utils.sh"

generate_secure_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

encrypt_credential() {
    local credential="$1"
    local key_file="$2"
    encrypt_to_base64_string "$credential" "$key_file"
}

decrypt_credential() {
    local encrypted="$1"
    local key_file="$2"
    decrypt_from_base64_string "$encrypted" "$key_file"
}

store_credential() {
    local service="$1"
    local username="$2"
    local password="$3"

    ensure_dirs "$KEYS_DIR" "$CRED_DIR"

    if command -v secret-tool >/dev/null 2>&1; then
        echo -n "$password" | secret-tool store --label="Easy Splunk $service" service "$service" username "$username"
        return $?
    else
        local key_file="$KEYS_DIR/$service.key"
        if [[ ! -f "$key_file" ]]; then
            generate_key_file "$key_file"
            chmod 600 "$key_file"
        fi

        local out_file="$CRED_DIR/$service-$username.enc"
        encrypt_credential "$password" "$key_file" > "$out_file"
        chmod 600 "$out_file"
    fi
}

retrieve_credential() {
    local service="$1"
    local username="$2"

    if command -v secret-tool >/dev/null 2>&1; then
        secret-tool lookup service "$service" username "$username"
        return $?
    else
        local key_file="$KEYS_DIR/$service.key"
        local in_file="$CRED_DIR/$service-$username.enc"
        if [[ ! -f "$key_file" || ! -f "$in_file" ]]; then
            return 1
        fi
        local encrypted
        encrypted=$(cat "$in_file")
        decrypt_credential "$encrypted" "$key_file"
    fi
}

help() {
    cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  generate_secure_password
  store_credential <service> <username> <password>
  retrieve_credential <service> <username>
EOF
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd=${1:-}
    shift || true
    case "$cmd" in
        generate_secure_password) generate_secure_password ;;
        store_credential) store_credential "$@" ;;
        retrieve_credential) retrieve_credential "$@" ;;
        *) help ;;
    esac
fi
