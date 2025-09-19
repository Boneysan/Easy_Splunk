#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'


# Utilities for encrypting/decrypting strings to/from base64 using a key file.

ensure_dirs() {
    for d in "$@"; do
        if [[ ! -d "$d" ]]; then
            mkdir -p "$d"
            chmod 700 "$d"
        fi
    done
}

generate_key_file() {
    local path="$1"
    # 32 bytes (256 bit) random key
    dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 -w 0 > "$path"
}

encrypt_to_base64_string() {
    local plaintext="$1"
    local key_file="$2"
    if [[ ! -f "$key_file" ]]; then
        return 1
    fi
    # Use openssl symmetric encryption with keyfile as password source
    echo -n "$plaintext" | openssl enc -aes-256-cbc -pbkdf2 -salt -pass file:"$key_file" | base64 -w 0
}

decrypt_from_base64_string() {
    local b64="$1"
    local key_file="$2"
    if [[ ! -f "$key_file" ]]; then
        return 1
    fi
    echo -n "$b64" | base64 -d | openssl enc -aes-256-cbc -pbkdf2 -d -pass file:"$key_file"
}
