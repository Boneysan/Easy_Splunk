#!/usr/bin/env bash
#
# ==============================================================================
# generate-splunk-configs.sh
# ------------------------------------------------------------------------------
# Automates Splunk setup: creates (or verifies) an index and a HEC token
# idempotently, and prints a short summary. Optional: write the token to a file.
#
# Flags:
#   --splunk-user <user>        (required)
#   --splunk-password <pass>    (prompted if omitted)
#   --index-name <name>         (required, e.g., my_app_prod)
#   --hec-name <name>           HEC token name (default: app_<index>_token)
#   --hec-sourcetype <st>       Optional sourcetype for the HEC token
#   --token-file <path>         Write the token to a file (chmod 600)
#   --splunk-api-host <host>    (default: localhost)
#   --splunk-api-port <port>    (default: 8089)
#   --protocol <https|http>     (default: https)
#   --insecure                  Ignore TLS verify (default ON)
#   --no-insecure               Enforce TLS verify
#   --timeout <sec>             curl max time (default: 20)
#   --retries <n>               curl retries (default: 2)
#   -h, --help
#
# Behavior / Notes:
#   • Uses Splunk management API (port 8089 by default).
#   • Treats 200/201 as success; 404 → creates resource; 409 → treated as exists.
#   • Never prints the full token by default; use --token-file to persist it.
#
# Dependencies: lib/core.sh, lib/error-handling.sh
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"

# ----------------------- Defaults -----------------------
SPLUNK_API_HOST="localhost"
SPLUNK_API_PORT="8089"
SPLUNK_USER=""
SPLUNK_PASSWORD=""
INDEX_NAME=""
HEC_NAME=""
HEC_SOURCETYPE=""
TOKEN_FILE=""

PROTOCOL="https"
INSECURE=1
TIMEOUT=20
RETRIES=2

usage() {
  cat <<EOF
Usage: $(basename "$0") --splunk-user <user> --index-name <name> [options]

Required:
  --splunk-user <user>
  --index-name <name>

Options:
  --splunk-password <pass>   Prompted securely if omitted
  --hec-name <name>          HEC token name (default: app_<index>_token)
  --hec-sourcetype <type>    Optional sourcetype for the HEC token
  --token-file <path>        Write the HEC token to a file (0600)
  --splunk-api-host <host>   Default: ${SPLUNK_API_HOST}
  --splunk-api-port <port>   Default: ${SPLUNK_API_PORT}
  --protocol <https|http>    Default: ${PROTOCOL}
  --insecure                 Ignore TLS verification (default ON)
  --no-insecure              Enforce TLS verification
  --timeout <sec>            curl max time (default: ${TIMEOUT})
  --retries <n>              curl retries (default: ${RETRIES})
  -h, --help                 Show this help
EOF
}

# ----------------------- Args ---------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --splunk-user) SPLUNK_USER="${2:?}"; shift 2 ;;
    --splunk-password) SPLUNK_PASSWORD="${2:?}"; shift 2 ;;
    --index-name) INDEX_NAME="${2:?}"; shift 2 ;;
    --hec-name) HEC_NAME="${2:?}"; shift 2 ;;
    --hec-sourcetype) HEC_SOURCETYPE="${2:?}"; shift 2 ;;
    --token-file) TOKEN_FILE="${2:?}"; shift 2 ;;
    --splunk-api-host) SPLUNK_API_HOST="${2:?}"; shift 2 ;;
    --splunk-api-port) SPLUNK_API_PORT="${2:?}"; shift 2 ;;
    --protocol) PROTOCOL="${2:?}"; shift 2 ;;
    --insecure) INSECURE=1; shift ;;
    --no-insecure) INSECURE=0; shift ;;
    --timeout) TIMEOUT="${2:?}"; shift 2 ;;
    --retries) RETRIES="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "${E_INVALID_INPUT:-2}" "Unknown option: $1" ;;
  esac
done

# ----------------------- Validation ---------------------
[[ -n "${SPLUNK_USER}" && -n "${INDEX_NAME}" ]] || die "${E_INVALID_INPUT:-2}" "Missing --splunk-user or --index-name"
[[ "${PROTOCOL}" =~ ^https?$ ]] || die "${E_INVALID_INPUT:-2}" "Invalid --protocol (use http or https)"
if [[ -z "${SPLUNK_PASSWORD}" ]]; then
  read -s -r -p "Enter Splunk password for '${SPLUNK_USER}': " SPLUNK_PASSWORD; echo
fi
command -v curl >/dev/null 2>&1 || die "${E_MISSING_DEP:-3}" "curl is required"

[[ -n "${HEC_NAME}" ]] || HEC_NAME="app_${INDEX_NAME}_token"
BASE_URL="${PROTOCOL}://${SPLUNK_API_HOST}:${SPLUNK_API_PORT}"
CURL_COMMON=(-sS --fail-with-body --max-time "${TIMEOUT}" --retry "${RETRIES}" --retry-delay 2 -u "${SPLUNK_USER}:${SPLUNK_PASSWORD}")
(( INSECURE == 1 )) && CURL_COMMON+=(-k)

# ----------------------- Helpers ------------------------
API_CODE=""; API_BODY=""

_api() {
  # _api <METHOD> <PATH> [curl -d/-H ...]
  local method="$1"; shift
  local path="$1"; shift || true
  local tmp; tmp="$(mktemp)"; local code=""; local rc=0
  if ! code="$(curl "${CURL_COMMON[@]}" -X "${method}" "${BASE_URL}${path}" "$@" -w '%{http_code}' -o "${tmp}")"; then
    rc=$?
    API_CODE="-1"
    API_BODY="$(cat "${tmp}" 2>/dev/null || true)"
    rm -f "${tmp}"
    return "${rc}"
  fi
  API_CODE="${code}"
  API_BODY="$(cat "${tmp}")"
  rm -f "${tmp}"
  return 0
}

_jq() { command -v jq >/dev/null 2>&1; }

_json_get() {
  # _json_get '<jq filter>'  (falls back to grep/sed best-effort)
  local filter="$1"
  if _jq; then
    printf '%s' "${API_BODY}" | jq -r "${filter}"
  else
    # crude fallback for simple key paths like .entry[0].content.token
    case "${filter}" in
      *.token) printf '%s' "${API_BODY}" | grep -oE '"token"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | sed 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/';;
      *)       printf '' ;;
    esac
  fi
}

_mask() {
  local s="$1"
  local n=${#s}
  if (( n <= 8 )); then printf '%s\n' "****"; else printf '%s\n' "${s:0:6}****${s: -4}"; fi
}

_write_token_file() {
  local path="$1" tok="$2"
  local dir; dir="$(dirname -- "$path")"
  mkdir -p "$dir"
  umask 077
  printf '%s\n' "$tok" > "$path"
  chmod 600 "$path" 2>/dev/null || true
  log_success "Token written to: ${path} (0600)"
}

# ----------------------- Work ---------------------------
log_info "🔐 Connecting to Splunk at ${BASE_URL}"

# 0) Quick reachability / version
_api GET "/services/server/info?output_mode=json" || true
if [[ "${API_CODE}" != "200" ]]; then
  die "${E_GENERAL:-1}" "Unable to reach Splunk management API (HTTP ${API_CODE}). Check host/port/credentials."
fi
if _jq; then
  ver="$(_json_get '.entry[0].content.version' || true)"
  build="$(_json_get '.entry[0].content.build' || true)"
  [[ -n "${ver}" ]] && log_info "Splunk version: ${ver} (build ${build:-?})"
fi

# 1) Ensure index exists
log_info "📦 Checking index '${INDEX_NAME}'..."
_api GET "/services/data/indexes/${INDEX_NAME}?output_mode=json" || true
case "${API_CODE}" in
  200) log_success "Index exists." ;;
  404)
    log_info "Creating index '${INDEX_NAME}'..."
    _api POST "/services/data/indexes?output_mode=json" --data-urlencode "name=${INDEX_NAME}" || true
    case "${API_CODE}" in
      200|201) log_success "Index created." ;;
      409)     log_warn "Index already exists (409 reported). Continuing." ;;
      *)       die "${E_GENERAL:-1}" "Failed to create index (HTTP ${API_CODE}). Body: ${API_BODY}" ;;
    esac
    ;;
  *)  die "${E_GENERAL:-1}" "Index check failed (HTTP ${API_CODE}). Body: ${API_BODY}" ;;
esac

# 2) Best-effort: ensure HEC is enabled globally
log_info "🪝 Ensuring HEC is enabled (best effort)..."
_api POST "/servicesNS/nobody/splunk_httpinput/data/inputs/http/http?output_mode=json" \
  --data-urlencode "disabled=0" || true
case "${API_CODE}" in
  200|201) log_success "HEC enabled." ;;
  404)     log_warn "HEC global endpoint not found (404). Your Splunk build may differ; continuing." ;;
  *)       log_warn "Could not verify/enable HEC (HTTP ${API_CODE}). Continuing." ;;
esac

# 3) Ensure HEC token exists (and matches index/sourcetype if provided)
log_info "🔎 Checking HEC token '${HEC_NAME}'..."
_api GET "/services/data/inputs/http/${HEC_NAME}?output_mode=json" || true
if [[ "${API_CODE}" == "200" ]]; then
  log_success "HEC token exists."
  # Optional reconcile: update index/sourcetype if requested
  wants_update=0
  if [[ -n "${HEC_SOURCETYPE}" ]]; then wants_update=1; fi
  # (We always ensure the index matches INDEX_NAME)
  wants_update=1
  if (( wants_update == 1 )); then
    log_info "Updating HEC token settings (index, sourcetype if provided)..."
    args=( --data-urlencode "index=${INDEX_NAME}" )
    [[ -n "${HEC_SOURCETYPE}" ]] && args+=( --data-urlencode "sourcetype=${HEC_SOURCETYPE}" )
    _api POST "/services/data/inputs/http/${HEC_NAME}?output_mode=json" "${args[@]}" || true
    case "${API_CODE}" in
      200|201) log_success "HEC token updated." ;;
      *)       log_warn "HEC token update returned HTTP ${API_CODE}. Continuing." ;;
    esac
  fi
else
  if [[ "${API_CODE}" == "404" ]]; then
    log_info "Creating HEC token '${HEC_NAME}'..."
    args=( --data-urlencode "name=${HEC_NAME}" --data-urlencode "index=${INDEX_NAME}" --data-urlencode "disabled=0" )
    [[ -n "${HEC_SOURCETYPE}" ]] && args+=( --data-urlencode "sourcetype=${HEC_SOURCETYPE}" )
    _api POST "/services/data/inputs/http?output_mode=json" "${args[@]}" || true
    case "${API_CODE}" in
      200|201) log_success "HEC token created." ;;
      409)     log_warn "HEC token already exists (409). Continuing." ;;
      *)       die "${E_GENERAL:-1}" "Failed to create HEC token (HTTP ${API_CODE}). Body: ${API_BODY}" ;;
    esac
  else
    die "${E_GENERAL:-1}" "HEC token check failed (HTTP ${API_CODE}). Body: ${API_BODY}"
  fi
fi

# 4) Retrieve token value
log_info "🔑 Retrieving HEC token value..."
_api GET "/services/data/inputs/http/${HEC_NAME}?output_mode=json" || true
[[ "${API_CODE}" == "200" ]] || die "${E_GENERAL:-1}" "Failed to retrieve HEC token (HTTP ${API_CODE}). Body: ${API_BODY}"

token_value="$(_json_get '.entry[0].content.token' | head -n1 || true)"
is_empty "${token_value:-}" && die "${E_GENERAL:-1}" "Could not parse HEC token value from response."

# 5) Optional: write to file, otherwise only show masked token
if [[ -n "${TOKEN_FILE}" ]]; then
  _write_token_file "${TOKEN_FILE}" "${token_value}"
fi

# 6) Summary (mask token in logs)
log_success "✅ Splunk configuration complete."
log_info "Index      : ${INDEX_NAME}"
log_info "HEC name   : ${HEC_NAME}"
[[ -n "${HEC_SOURCETYPE}" ]] && log_info "Sourcetype : ${HEC_SOURCETYPE}"
if [[ -n "${TOKEN_FILE}" ]]; then
  log_info "HEC token  : (written to ${TOKEN_FILE})"
else
  log_info "HEC token  : $(_mask "${token_value}")"
fi
