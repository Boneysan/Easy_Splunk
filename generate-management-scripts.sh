#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

#
# ==============================================================================
# generate-management-scripts.sh
# ------------------------------------------------------------------------------
# Generates helper scripts that call the app's API using an API key loaded
# at runtime from a secrets .env file (NOT embedded at generation time).
#
# Flags:
#   --out-dir <dir>         Where to write scripts (default: ./management-scripts)
#   --secrets-file <path>   Path to .env file (default: ./config/secrets/production.env)
#   --api-url <url>         Base API URL (default: http://localhost:8080/api/v1)
#   --key-var <NAME>        Env var name that contains the API key in the .env
#                           (default: THIRD_PARTY_API_KEY)
#
# Notes:
#   - Scripts are idempotent to regenerate and do not store the API key.
#   - Placeholders are replaced safely (slashes, ampersands, backslashes escaped).
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/security.sh
# Version: 1.0.0
# ==============================================================================


# --- Source Dependencies ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"
# shellcheck source=lib/security.sh
source "${SCRIPT_DIR}/lib/security.sh"

# --- Version Checks ------------------------------------------------------------
if [[ "${SECURITY_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "generate-management-scripts.sh requires security.sh version >= 1.0.0"
fi

# --- Defaults (overridable by flags) ---
OUT_DIR="${OUT_DIR:-./management-scripts}"
SECRETS_ENV_FILE="${SECRETS_ENV_FILE:-./config/secrets/production.env}"
API_BASE_URL="${API_BASE_URL:-http://localhost:8080/api/v1}"
KEY_VAR="${KEY_VAR:-THIRD_PARTY_API_KEY}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --out-dir <dir>         Output directory (default: ${OUT_DIR})
  --secrets-file <path>   Secrets .env path (default: ${SECRETS_ENV_FILE})
  --api-url <url>         API base URL (default: ${API_BASE_URL})
  --key-var <NAME>        Env var name holding API key (default: ${KEY_VAR})
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir) OUT_DIR="${2:?}"; shift 2;;
    --secrets-file) SECRETS_ENV_FILE="${2:?}"; shift 2;;
    --api-url) API_BASE_URL="${2:?}"; shift 2;;
    --key-var) KEY_VAR="${2:?}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "${E_INVALID_INPUT:-2}" "Unknown option: $1";;
  esac
done

# --- Pre-flight ---
mkdir -p "${OUT_DIR}"
harden_file_permissions "${OUT_DIR}" "700" "management scripts directory" || true
if [[ ! -f "${SECRETS_ENV_FILE}" ]]; then
  die "${E_MISSING_DEP:-3}" "Secrets file not found: ${SECRETS_ENV_FILE}. Run generate-credentials.sh first."
fi
harden_file_permissions "${SECRETS_ENV_FILE}" "600" "secrets env file" || true
if ! grep -E "^[[:space:]]*${KEY_VAR}=" "${SECRETS_ENV_FILE}" >/dev/null; then
  log_warn "Could not find ${KEY_VAR}= in ${SECRETS_ENV_FILE}. Scripts will still work if it's added later."
fi

# Safe replacement helper
_sed_escape_repl() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//&/\\&}"
  printf '%s' "${s}"
}

# Common prefix for generated scripts
read -r -d '' _COMMON_PFX <<'EOS' || true
#!/usr/bin/env bash

SECRETS_ENV_FILE="${SECRETS_ENV_FILE_PLACEHOLDER}"
API_BASE_URL="${API_BASE_URL_PLACEHOLDER}"
KEY_VAR="${KEY_VAR_PLACEHOLDER}"

# Normalize base URL: drop trailing slash
API_BASE_URL="${API_BASE_URL%/}"

# Load secrets at runtime without exporting unrelated env
if [[ ! -f "${SECRETS_ENV_FILE}" ]]; then
  echo "Secrets file not found: ${SECRETS_ENV_FILE}" >&2
  exit 2
fi
# shellcheck disable=SC1090
set -a; source "${SECRETS_ENV_FILE}"; set +a

API_KEY="${!KEY_VAR:-}"
if [[ -z "${API_KEY}" ]]; then
  echo "API key env var '${KEY_VAR}' is empty/missing in ${SECRETS_ENV_FILE}" >&2
  exit 3
fi

_curl_json() {
  # usage: _curl_json GET /path [curl-args...]
  local method="$1"; shift
  local path="$1"; shift || true
  curl_auth "${API_BASE_URL}${path}" "${SECRETS_ENV_FILE}" \
    -X "${method}" -H "Accept: application/json" "$@"
}

_pp_or_cat() {
  if command -v jq >/dev/null 2>&1; then jq .; else cat; fi
}
EOS

# --- Generators ---------------------------------------------------------------
_generate_get_health_script() {
  local p="${OUT_DIR}/get-health.sh"
  log_info "  -> ${p}"
  write_secret_file "${p}" "$(cat <<EOF
${_COMMON_PFX}
# Check API health
if _curl_json GET "/health" | _pp_or_cat; then
  echo "API is healthy."
else
  echo "API health check failed." >&2
  exit 1
fi
EOF
)" "get-health.sh"
  harden_file_permissions "${p}" "700" "management script" || true
}

_generate_list_users_script() {
  local p="${OUT_DIR}/list-users.sh"
  log_info "  -> ${p}"
  write_secret_file "${p}" "$(cat <<EOF
${_COMMON_PFX}
# List users
_curl_json GET "/users" | _pp_or_cat
EOF
)" "list-users.sh"
  harden_file_permissions "${p}" "700" "management script" || true
}

_generate_add_user_script() {
  local p="${OUT_DIR}/add-user.sh"
  log_info "  -> ${p}"
  write_secret_file "${p}" "$(cat <<'EOF'
${_COMMON_PFX}
# Add user
if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <username> <password> [role]" >&2
  exit 64
fi

USERNAME="$1"; PASSWORD="$2"; ROLE="${3:-user}"

# Build JSON payload
if command -v jq >/dev/null 2>&1; then
  payload="$(jq -c --arg u "$USERNAME" --arg p "$PASSWORD" --arg r "$ROLE" \
    '{username:$u,password:$p,role:$r}')"
else
  payload=$(printf '{"username":"%s","password":"%s","role":"%s"}' "$USERNAME" "$PASSWORD" "$ROLE")
fi

# Send request
if ! out=$(_curl_json POST "/users" -H "Content-Type: application/json" -d "$payload" 2>&1); then
  echo "$out" >&2
  exit 1
fi

# Pretty print
printf '%s\n' "$out" | _pp_or_cat
EOF
)" "add-user.sh"
  harden_file_permissions "${p}" "700" "management script" || true
}

# --- Main ---------------------------------------------------------------------
main() {
  log_info "🚀 Generating API Management Scripts"
  mkdir -p "${OUT_DIR}"
  _generate_get_health_script
  _generate_list_users_script
  _generate_add_user_script
  _rep_secrets="$(_sed_escape_repl "${SECRETS_ENV_FILE}")"
  _rep_baseurl="$(_sed_escape_repl "${API_BASE_URL}")"
  _rep_keyvar="$(_sed_escape_repl "${KEY_VAR}")"
  for f in "${OUT_DIR}/get-health.sh" "${OUT_DIR}/list-users.sh" "${OUT_DIR}/add-user.sh"; do
    sed -i.bak \
      -e "s|SECRETS_ENV_FILE_PLACEHOLDER|${_rep_secrets}|g" \
      -e "s|API_BASE_URL_PLACEHOLDER|${_rep_baseurl}|g" \
      -e "s|KEY_VAR_PLACEHOLDER|${_rep_keyvar}|g" \
      "$f"
    rm -f "${f}.bak"
  done
  audit_security_configuration "${OUT_DIR}/security-audit.txt"
  log_warn "Generated scripts load the API key at runtime from: ${SECRETS_ENV_FILE}"
  log_warn "Expected .env entry: ${KEY_VAR}=<your_api_key_here>"
  log_info  "Run again with different flags to update paths/URL/variable."
  log_success "✅ Management scripts generated in: ${OUT_DIR}"
}

GENERATE_MANAGEMENT_SCRIPTS_VERSION="1.0.0"
main

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "generate-management-scripts"

# Set error handling


