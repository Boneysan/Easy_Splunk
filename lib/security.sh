#!/usr/bin/env bash
#
# ==============================================================================
# lib/security.sh
# ------------------------------------------------------------------------------
# ⭐⭐⭐⭐
#
# Provides core functions for security operations, including credential
# generation, SSL/TLS certificate management, and file permission hardening.
#
# Features:
#   - Generation of strong, random passwords.
#   - Creation of self-signed TLS certificates for internal HTTPS.
#   - A utility for setting secure file permissions (e.g., 600 for keys).
#
# Dependencies: core.sh, error-handling.sh
# Required by:  orchestrator.sh, compose-generator.sh, generate-credentials.sh
#
# ==============================================================================

# --- Source Dependencies ---
# Assumes core libraries have been sourced by the calling script.
if [[ -z "$(type -t log_info)" || -z "$(type -t die)" ]]; then
    echo "FATAL: lib/core.sh and lib/error-handling.sh must be sourced before lib/security.sh" >&2
    exit 1
fi

# --- Credential Generation ---

# Generates a cryptographically strong random password.
# Usage: MY_SECRET=$(generate_random_password [length])
#
# @param1: Optional length of the password (default: 32).
# @stdout: The generated password.
generate_random_password() {
    local length="${1:-32}"
    # Use /dev/urandom for entropy, filter for URL-safe characters, and take the first N characters.
    tr -dc 'A-Za-z0-9_!@#$%^&*' < /dev/urandom | head -c "$length"
}

# --- Security Hardening ---

# Sets secure permissions for a file, logging the action.
# Typically used for private keys and credential files.
# Usage: harden_file_permissions "/path/to/key.pem" "600"
#
# @param1: The path to the file.
# @param2: The octal permission mode (e.g., 600, 640).
harden_file_permissions() {
    local file_path="$1"
    local mode="$2"

    if [[ ! -f "$file_path" ]]; then
        log_warn "Cannot set permissions. File not found: ${file_path}"
        return 1
    fi

    chmod "$mode" "$file_path"
    log_debug "Set permissions of '${file_path}' to ${mode}."
}

# --- SSL/TLS Certificate Management ---

# Generates a self-signed TLS certificate and private key using OpenSSL.
# This function is idempotent: it will not overwrite existing files.
#
# Usage: generate_self_signed_cert "domain.com" "/path/to/key.pem" "/path/to/cert.pem"
#
# @param1: The common name for the certificate (e.g., localhost, my-app.internal).
# @param2: The output path for the private key file.
# @param3: The output path for the certificate file.
generate_self_signed_cert() {
    local common_name="$1"
    local key_file="$2"
    local cert_file="$3"

    # Ensure the output directory exists
    local cert_dir
    cert_dir=$(dirname "$cert_file")
    mkdir -p "$cert_dir"

    # Check if files already exist to prevent overwriting
    if [[ -f "$key_file" && -f "$cert_file" ]]; then
        log_info "TLS certificate and key already exist. Skipping generation."
        return 0
    fi

    # Check for OpenSSL dependency
    if ! command -v openssl &> /dev/null; then
        die "$E_MISSING_DEP" "OpenSSL is not installed but is required to generate certificates."
    fi

    log_info "Generating new self-signed TLS certificate for '${common_name}'..."
    log_debug "  -> Key File: ${key_file}"
    log_debug "  -> Cert File: ${cert_file}"

    # Generate the key and certificate in one command
    openssl req \
        -x509 \
        -nodes \
        -newkey rsa:4096 \
        -keyout "$key_file" \
        -out "$cert_file" \
        -days 3650 \
        -subj "/CN=${common_name}" \
        &>/dev/null # Suppress verbose output from openssl

    # Apply secure permissions to the generated files
    harden_file_permissions "$key_file" "600" # Private key must be protected
    harden_file_permissions "$cert_file" "644" # Certificate is public, can be world-readable

    log_success "Successfully generated new TLS certificate and private key."
}