#!/usr/bin/env bash
#
# ==============================================================================
# integration-guide.sh — v2.0 → current migration guide (read-only)
#
# Checks a legacy config for renamed/removed keys and structure changes.
# Outputs a human-friendly report (text by default, or markdown with --output).
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/security.sh
# Version: 1.0.0
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"
# shellcheck source=lib/security.sh
source "${SCRIPT_DIR}/lib/security.sh"

# --- Version Checks ------------------------------------------------------------
if [[ "${SECURITY_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "integration-guide.sh requires security.sh version >= 1.0.0"
fi

ISSUES_FOUND=0
WARNINGS_FOUND=0
OUTPUT_FORMAT="text"
REPORT_FILE=""
: "${SECRETS_DIR:=./secrets}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--output text|markdown] [--report <file>] <path_to_v2_config>

Analyzes a v2.0 configuration file and reports migration changes.

Options:
  --output text|markdown   Output format (default: text)
  --report <file>          Write the full report to a file (stdout still prints summary)
  -h, --help               Show this help

Example:
  $(basename "$0") --output markdown --report migration_report.md ./old.env
EOF
}

# --- Helpers ---
_has_key() {
  awk -v k="$2" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      line=$0
      sub(/^[[:space:]]*export[[:space:]]+/, "", line)
      split(line, a, "=")
      sub(/^[[:space:]]+/, "", a[1]); sub(/[[:space:]]+$/, "", a[1])
      if (a[1]==k) { found=1; exit }
    }
    END { exit (found?0:1) }
  ' "$1"
}

_find_lines_for_key() {
  awk -v k="$2" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      line=$0
      check=line
      sub(/^[[:space:]]*export[[:space:]]+/, "", check)
      split(check, a, "=")
      sub(/^[[:space:]]+/, "", a[1]); sub(/[[:space:]]+$/, "", a[1])
      if (a[1]==k) {
        print NR ":" line
      }
    }
  ' "$1"
}

_list_all_keys() {
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      line=$0
      sub(/^[[:space:]]*export[[:space:]]+/, "", line)
      split(line, a, "=")
      sub(/^[[:space:]]+/, "", a[1]); sub(/[[:space:]]+$/, "", a[1])
      if (a[1]!="") print a[1]
    }
  ' "$1"
}

_has_crlf() { grep -Iq $'\r' "$1"; }

_indent_md() {
  local lvl="${1:-1}"
  (( lvl<=1 )) && { printf ''; return; }
  printf '%*s' $(( (lvl-1)*2 )) ''
}

_emit_h() {
  local lvl="$1" txt="$2"
  if [[ "$OUTPUT_FORMAT" == "markdown" ]]; then
    printf '%s %s\n' "$(printf '#%.0s' $(seq 1 "$lvl"))" "$txt"
  else
    if (( lvl==1 )); then log_info "$txt"
    elif (( lvl==2 )); then log_info "== $txt =="
    else log_info "-- $txt --"
    fi
  fi
}

_emit_bullet() {
  local txt="$1" lvl="${2:-1}"
  if [[ "$OUTPUT_FORMAT" == "markdown" ]]; then
    printf '%s- %s\n' "$(_indent_md "$lvl")" "$txt"
  else
    if (( lvl<=1 )); then log_info "  • $txt"
    else
      printf '  %*s• %s\n' $(( (lvl-1)*2 )) '' "$txt"
    fi
  fi
}

_record_issue() { ISSUES_FOUND=$((ISSUES_FOUND+1)); }
_record_warn() { WARNINGS_FOUND=$((WARNINGS_FOUND+1)); }

# --- Rules ---
declare -A RENAMED=(
  [DOCKER_IMAGE_TAG]="Use versions.env: APP_VERSION + APP_IMAGE_REPO (and friends)."
  [DATA_PATH]="Renamed to DATA_DIR."
)

declare -A REMOVED=(
  [ENABLE_LEGACY_MODE]="Legacy mode was removed. Remove the setting; feature no longer exists."
)

LIKELY_IN_VERSIONS_ENV=("APP_VERSION" "APP_IMAGE_REPO" "REDIS_VERSION" "PROMETHEUS_VERSION" "GRAFANA_VERSION")

# --- Main checks ---
check_renamed() {
  local cfg="$1"
  _emit_h 2 "Renamed variables"
  local hit=false
  for key in "${!RENAMED[@]}"; do
    if _has_key "$cfg" "$key"; then
      hit=true
      _record_issue
      local lines; lines="$(_find_lines_for_key "$cfg" "$key" || true)"
      while IFS= read -r l; do
        [[ -z "$l" ]] && continue
        _emit_bullet "[RENAMED] ${key} at line ${l%%:*}. ${RENAMED[$key]}" 2
      done <<<"$lines"
    fi
  done
  [[ "$hit" == false ]] && _emit_bullet "No renamed variables detected." 2
}

check_removed() {
  local cfg="$1"
  _emit_h 2 "Removed variables"
  local hit=false
  for key in "${!REMOVED[@]}"; do
    if _has_key "$cfg" "$key"; then
      hit=true
      _record_issue
      local lines; lines="$(_find_lines_for_key "$cfg" "$key" || true)"
      while IFS= read -r l; do
        [[ -z "$l" ]] && continue
        _emit_bullet "[REMOVED] ${key} at line ${l%%:*}. ${REMOVED[$key]}" 2
      done <<<"$lines"
    fi
  done
  [[ "$hit" == false ]] && _emit_bullet "No removed variables detected." 2
}

check_structure() {
  _emit_h 2 "Structural changes"
  _emit_bullet "Image versions are now centralized in versions.env." 2
  _emit_bullet "Runtime settings are passed via template (--config) or flags to orchestrator." 2
  _emit_bullet "Compose is generated by compose-generator.sh; avoid hand-editing docker-compose.yml." 2
  _record_warn
}

check_duplicates() {
  local cfg="$1"
  _emit_h 2 "Duplicate keys"
  local dups
  dups="$(_list_all_keys "$cfg" | sort | uniq -d || true)"
  if [[ -n "$dups" ]]; then
    _record_issue
    while IFS= read -r k; do
      [[ -z "$k" ]] && continue
      local lines; lines="$(_find_lines_for_key "$cfg" "$k" || true)"
      local nums; nums="$(printf '%s\n' "$lines" | cut -d: -f1 | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
      _emit_bullet "[DUPLICATE] ${k} appears multiple times: ${nums}" 2
    done <<<"$dups"
  else
    _emit_bullet "No duplicate keys found." 2
  fi
}

check_crlf() {
  local cfg="$1"
  _emit_h 2 "Line-endings"
  if _has_crlf "$cfg"; then
    _emit_bullet "Detected CRLF (Windows) line endings; convert to LF to avoid parsing surprises." 2
    _record_warn
  else
    _emit_bullet "LF line endings detected." 2
  fi
}

check_likely_versions_env_misplacements() {
  local cfg="$1"
  _emit_h 2 "Items likely belonging to versions.env"
  local hit=false
  for k in "${LIKELY_IN_VERSIONS_ENV[@]}"; do
    if _has_key "$cfg" "$k"; then
      hit=true
      _emit_bullet "[MOVE] ${k} detected here. Move to versions.env for centralized version pinning." 2
      _record_warn
    fi
  done
  [[ "$hit" == false ]] && _emit_bullet "No misplaced version keys detected." 2
}

check_sensitive_data() {
  local cfg="$1"
  _emit_h 2 "Sensitive data check"
  local sensitive_patterns="password|secret|key|token|credential"
  local findings
  findings="$(grep -Ei "$sensitive_patterns" "$cfg" || true)"
  if [[ -n "$findings" ]]; then
    _emit_bullet "Potential sensitive data detected (lines may contain passwords, keys, or tokens):" 2
    while IFS= read -r line; do
      _emit_bullet "$line" 3
    done <<<"$findings"
    _record_warn
  else
    _emit_bullet "No obvious sensitive data detected (based on common patterns)." 2
  fi
}

# --- Orchestration ---
run_checks() {
  local cfg="$1"
  _emit_h 1 "v2.0 Migration Compatibility Checker"
  _emit_bullet "Analyzing: ${cfg}"
  _emit_bullet "Read-only analysis; no files will be modified."

  echo
  check_renamed "$cfg"
  echo
  check_removed "$cfg"
  echo
  check_structure
  echo
  check_duplicates "$cfg"
  echo
  check_crlf "$cfg"
  echo
  check_likely_versions_env_misplacements "$cfg"
  echo
  check_sensitive_data "$cfg"

  echo
  _emit_h 1 "Summary"
  _emit_bullet "Issues: ${ISSUES_FOUND}  Warnings: ${WARNINGS_FOUND}"
  if (( ISSUES_FOUND == 0 )); then
    log_success "✅ No blocking issues found."
  else
    log_error "❌ ${ISSUES_FOUND} issue(s) require attention."
  fi
}

main() {
  local cfg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output) OUTPUT_FORMAT="${2:-text}"; shift 2 ;;
      --report) REPORT_FILE="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) cfg="$1"; shift ;;
    esac
  done
  [[ -n "$cfg" && -f "$cfg" ]] || die "${E_INVALID_INPUT:-2}" "v2.0 configuration file not found or not specified."
  if [[ "$OUTPUT_FORMAT" != "text" && "$OUTPUT_FORMAT" != "markdown" ]]; then
    die "${E_INVALID_INPUT:-2}" "--output must be 'text' or 'markdown'"
  fi
  mkdir -p "${SECRETS_DIR}"
  harden_file_permissions "${SECRETS_DIR}" "700" "secrets directory" || true
  if [[ -n "$REPORT_FILE" ]]; then
    run_checks "$cfg" | tee "$REPORT_FILE"
    harden_file_permissions "${REPORT_FILE}" "600" "migration report" || true
  else
    run_checks "$cfg"
  fi
  audit_security_configuration "${SCRIPT_DIR}/security-audit.txt"
  if (( ISSUES_FOUND > 0 )); then
    exit 1
  else
    exit 0
  fi
}

INTEGRATION_GUIDE_VERSION="1.0.0"
main "$@"

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "integration-guide"

# Set error handling
set -euo pipefail


