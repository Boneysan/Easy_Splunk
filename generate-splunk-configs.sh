#!/usr/bin/env bash
#
# ==============================================================================
# generate-splunk-configs.sh
# ------------------------------------------------------------------------------
# Automates Splunk setup: creates an index and a HEC token (idempotent).
#
# Flags:
#   --splunk-user <user>        (required)
#   --splunk-password <pass>    (prompted if omitted)
#   --index-name <name>         (required, e.g. my_app_prod)
#   --hec-name <name>           HEC token name (default: app_<index>_token)
#   --splunk-api-host <host>    (default: localhost)
#   --splunk-api-port <port>    (default: 8089)
#   --protocol <https|http>     (default: https)
#   --insecure                  Ignore TLS verify (default: on)
#   --no-insecure               Enforce TLS verify
#   --timeout <sec>             curl max time (default: 20)
#   --retries <n>               curl retries (default: 2)
#   -h, --help
#
# Dependencies: lib/core.sh, lib/error-handling.sh
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/error-handling.sh"

# ----------------------- Defaults -----------------------
SPLUNK_API_HOST="localhost"
SPLUNK_API_PORT="8089"
SPLUNK_USER=""
SPLUNK_PASSWORD=""
INDEX_NAME=""
HEC_NAME=""
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --splunk-user) SPLUNK_USER="${2:?}"; shift 2 ;;
    --splunk-password) SPLUNK_PASSWORD="${2:?}"; shift 2 ;;
    --index-name) INDEX_NAME="${2:?}"; shift 2 ;;
    --hec-name) HEC_NAME="${2:?}"; shift 2 ;;
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

# ----------------------- Validation -----------------------
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

# Small helpers: perform API call and capture code/body
_api() {
  # _api <METHOD> <PATH> [curl -d/-H ...]
  local method="$1"; shift
  local path="$1"; shift || true
  local tmp_out; tmp_out="$(mktemp)"; local code
  if ! code="$(curl "${CURL_COMMON[@]}" -X "${method}" "${BASE_URL}${path}" "$@" -w '%{http_code}' -o "${tmp_out}")"; then
    cat "${tmp_out}" >&2 || true
    rm -f "${tmp_out}"
    return 99
  fi
  printf '%s\n' "${code}"
  cat "${tmp_out}"
  rm -f "${tmp_out}"
}

# JSON value extractor: jq if present, otherwise grep/sed best-effort
_json_get() {
  local key="$1"
  if command -v jq >/dev/null 2>&1; then jq -r "$key"; else sed -n "s/.*\"${key##*.}\":[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p"; fi
}

# ----------------------- Work -----------------------
log_info "🚀 Configuring Splunk at ${BASE_URL}"

# 1) Ensure index exists
log_info "Checking index '${INDEX_NAME}'..."
read -r code body < <(_api GET "/services/data/indexes/${INDEX_NAME}?output_mode=json")
if [[ "${code}" == "200" ]]; then
  log_success "  -> Index exists."
elif [[ "${code}" == "404" ]]; then
  log_info "  -> Creating index..."
  read -r code body < <(_api POST "/services/data/indexes?output_mode=json" --data-urlencode "name=${INDEX_NAME}")
  [[ "${code}" == "201" || "${code}" == "200" ]] || die "${E_GENERAL:-1}" "Failed to create index (HTTP ${code})."
  log_success "  -> Index created."
else
  die "${E_GENERAL:-1}" "Index check failed (HTTP ${code})."
fi

# 2) Best-effort: make sure HEC is globally enabled (varies by Splunk version/app)
# If this endpoint 404s, continue without failing.
log_info "Ensuring HEC is enabled (best effort)..."
read -r code body < <(_api POST "/servicesNS/nobody/splunk_httpinput/data/inputs/http/http?output_mode=json" \
  --data-urlencode "disabled=0")
if [[ "${code}" == "200" || "${code}" == "201" ]]; then
  log_success "  -> HEC enabled."
else
  log_warn "  -> Could not verify/enable HEC globally (HTTP ${code}); continuing."
fi

# 3) Ensure HEC token exists (and points to the index)
log_info "Checking HEC token '${HEC_NAME}'..."
read -r code body < <(_api GET "/services/data/inputs/http/${HEC_NAME}?output_mode=json")
if [[ "${code}" == "200" ]]; then
  log_success "  -> HEC token exists."
else
  if [[ "${code}" == "404" ]]; then
    log_info "  -> Creating HEC token..."
    read -r code body < <(_api POST "/services/data/inputs/http?output_mode=json" \
      --data-urlencode "name=${HEC_NAME}" \
      --data-urlencode "index=${INDEX_NAME}" \
      --data-urlencode "disabled=0")
    [[ "${code}" == "201" || "${code}" == "200" ]] || die "${E_GENERAL:-1}" "Failed to create HEC token (HTTP ${code})."
    log_success "  -> HEC token created."
  else
    die "${E_GENERAL:-1}" "HEC token check failed (HTTP ${code})."
  fi
fi

# 4) Retrieve token value
log_info "Retrieving HEC token value..."
read -r code body < <(_api GET "/services/data/inputs/http/${HEC_NAME}?output_mode=json")
[[ "${code}" == "200" ]] || die "${E_GENERAL:-1}" "Failed to retrieve HEC token (HTTP ${code})."

token_value="$(printf '%s' "${body}" | _json_get '.entry[0].content.token' | head -n1)"
if [[ -z "${token_value}" || "${token_value}" == "null" ]]; then
  # fallback: loose grep if jq absent and structure unexpected
  token_value="$(printf '%s' "${body}" | grep -oE '"token"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | sed 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
fi
is_empty "${token_value}" && die "${E_GENERAL:-1}" "Could not parse HEC token value from response."

log_success "✅ Splunk configuration complete."
log_info "Index: ${INDEX_NAME}"
log_info "HEC name: ${HEC_NAME}"
log_info "HEC token: ${token_value}"
