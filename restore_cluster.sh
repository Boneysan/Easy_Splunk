#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

#
# ==============================================================================
# restore_cluster.sh — Safe, flexible restore of container volumes
# ==============================================================================
# Features:
#   • Verifies checksum if <backup>.sha256 is present
#   • Supports .tar.gz.gpg, .tgz.gpg, .tar.gz, .tgz inputs
#   • Reads MANIFEST.txt (if present) to discover volume list
#   • Optional explicit --only-volumes (CSV) and/or --map-prefix old:new
#   • Optional rollback backup (uses backup_cluster.sh)
#   • Safe volume wipe (no rm -rf /volume_data/.* footgun)
#   • Works with Docker or Podman; retries on transient errors
#   • Honors GPG_PASSPHRASE env for non-interactive decryption when possible
#
# Examples:
#   ./restore_cluster.sh --backup-file backups/backup-20250101-120000.tar.gz.gpg \
#       --rollback-gpg-recipient ops@example.com --map-prefix prod:dev
#   ./restore_cluster.sh --backup-file backups/plain.tgz --skip-rollback \
#       --only-volumes dev_app-data,dev_redis-data
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/runtime-detection.sh, lib/security.sh, backup_cluster.sh, gpg (if .gpg)
# Version: 1.0.0
# ==============================================================================


# BEGIN: Fallback functions for error handling library compatibility
# These functions provide basic functionality when lib/error-handling.sh fails to load

# Fallback log_message function for error handling library compatibility
if ! type log_message &>/dev/null; then
  log_message() {
    local level="${1:-INFO}"
    local message="${2:-}"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    case "$level" in
      ERROR)   echo -e "\033[31m[$timestamp] ERROR: $message\033[0m" >&2 ;;
      WARNING) echo -e "\033[33m[$timestamp] WARNING: $message\033[0m" >&2 ;;
      SUCCESS) echo -e "\033[32m[$timestamp] SUCCESS: $message\033[0m" ;;
      DEBUG)   [[ "${VERBOSE:-false}" == "true" ]] && echo -e "\033[36m[$timestamp] DEBUG: $message\033[0m" ;;
      *)       echo -e "[$timestamp] INFO: $message" ;;
    esac
  }
fi

# Fallback error_exit function for error handling library compatibility
if ! type error_exit &>/dev/null; then
  error_exit() {
    local error_code=1
    local error_message=""
    
    if [[ $# -eq 1 ]]; then
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        error_code="$1"
        error_message="Script failed with exit code $error_code"
      else
        error_message="$1"
      fi
    elif [[ $# -eq 2 ]]; then
      error_message="$1"
      error_code="$2"
    fi
    
    if [[ -n "$error_message" ]]; then
      log_message ERROR "${error_message:-Unknown error}"
    fi
    
    exit "$error_code"
  }
fi

# Fallback init_error_handling function for error handling library compatibility
if ! type init_error_handling &>/dev/null; then
  init_error_handling() {
    # Basic error handling setup - no-op fallback
    set -euo pipefail
  }
fi

# Fallback register_cleanup function for error handling library compatibility
if ! type register_cleanup &>/dev/null; then
  register_cleanup() {
    # Basic cleanup registration - no-op fallback
    # Production systems should use proper cleanup handling
    return 0
  }
fi

# Fallback validate_safe_path function for error handling library compatibility
if ! type validate_safe_path &>/dev/null; then
  validate_safe_path() {
    local path="$1"
    local description="${2:-path}"
    
    # Basic path validation
    if [[ -z "$path" ]]; then
      log_message ERROR "$description cannot be empty"
      return 1
    fi
    
    if [[ "$path" == *".."* ]]; then
      log_message ERROR "$description contains invalid characters (..)"
      return 1
    fi
    
    return 0
  }
fi

# Fallback with_retry function for error handling library compatibility
if ! type with_retry &>/dev/null; then
  with_retry() {
    local max_attempts=3
    local delay=2
    local attempt=1
    local cmd=("$@")
    
    while [[ $attempt -le $max_attempts ]]; do
      if "${cmd[@]}"; then
        return 0
      fi
      
      local rc=$?
      if [[ $attempt -eq $max_attempts ]]; then
        log_message ERROR "with_retry: command failed after ${attempt} attempts (rc=${rc}): ${cmd[*]}" 2>/dev/null || echo "ERROR: with_retry failed after ${attempt} attempts" >&2
        return $rc
      fi
      
      log_message WARNING "Attempt ${attempt} failed (rc=${rc}); retrying in ${delay}s..." 2>/dev/null || echo "WARNING: Attempt ${attempt} failed, retrying in ${delay}s..." >&2
      sleep $delay
      ((attempt++))
      ((delay *= 2))
    done
  }
fi
# END: Fallback functions for error handling library compatibility


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# deps
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"
source "${SCRIPT_DIR}/lib/run-with-log.sh"
# shellcheck source=lib/runtime-detection.sh
source "${SCRIPT_DIR}/lib/runtime-detection.sh"
# shellcheck source=lib/security.sh
source "${SCRIPT_DIR}/lib/security.sh"
# shellcheck source=backup_cluster.sh
source "${SCRIPT_DIR}/backup_cluster.sh"

# --- Version Checks ------------------------------------------------------------
if [[ "${SECURITY_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "restore_cluster.sh requires security.sh version >= 1.0.0"
fi
if [[ "${BACKUP_CLUSTER_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "restore_cluster.sh requires backup_cluster.sh version >= 1.0.0"
fi

umask 077

# ---- Args ---------------------------------------------------------------------
BACKUP_FILE=""
SKIP_ROLLBACK="false"
ROLLBACK_GPG_RECIPIENT=""
ONLY_VOLUMES_CSV=""
MAP_PREFIX=""
AUTO_YES=0
: "${GPG_PASSPHRASE:=}"
: "${SECRETS_DIR:=./secrets}"

usage() {
  cat <<'EOF'
Usage: restore_cluster.sh --backup-file <path> [options]

Required:
  --backup-file <path>         Path to backup (.tar.gz[.gpg] or .tgz[.gpg])

Rollback:
  --rollback-gpg-recipient <id>   GPG key ID/email to encrypt rollback backup
  --skip-rollback                 Skip pre-restore backup (NOT recommended)

Selection/Mapping:
  --only-volumes <csv>            Comma-separated target volume names to restore
  --map-prefix <old:new>          Replace leading "<old>_" with "<new>_" on restore
                                  (e.g., prod -> dev)

Other:
  --yes, -y                       Non-interactive (assume yes)
  -h, --help                      Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-file) BACKUP_FILE="${2:?}"; shift 2 ;;
    --skip-rollback) SKIP_ROLLBACK="true"; shift ;;
    --rollback-gpg-recipient) ROLLBACK_GPG_RECIPIENT="${2:?}"; shift 2 ;;
    --only-volumes) ONLY_VOLUMES_CSV="${2:?}"; shift 2 ;;
    --map-prefix) MAP_PREFIX="${2:?old:new}"; shift 2 ;;
    -y|--yes) AUTO_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "${E_INVALID_INPUT:-2}" "Unknown option: $1" ;;
  esac
done

[[ -n "${BACKUP_FILE}" && -f "${BACKUP_FILE}" ]] || die "${E_INVALID_INPUT:-2}" "Backup file missing: ${BACKUP_FILE}"
mkdir -p "${SECRETS_DIR}"
harden_file_permissions "${SECRETS_DIR}" "700" "secrets directory" || true

# ---- Helpers ------------------------------------------------------------------
_confirm_or_exit() {
  local prompt="${1:-Proceed?}"
  if (( AUTO_YES == 1 )); then return 0; fi
  while true; do
    read -r -p "${prompt} [y/N] " ans </dev/tty || ans=""
    case "$ans" in
      [yY]|[yY][eE][sS]) return 0 ;;
      [nN]|[nN][oO]|"")  die 0 "Operation cancelled by user." ;;
      *) log_warn "Please answer 'y' or 'n'." ;;
    esac
  done
}

_have_cmd() { command -v "$1" >/dev/null 2>&1; }

_verify_checksum_if_present() {
  local f="$1"
  if [[ -f "${f}.sha256" ]]; then
    log_info "Verifying checksum: ${f}.sha256"
    local dir base; dir="$(dirname "$f")"; base="$(basename "$f")"
    pushd "${dir}" >/dev/null
    if _have_cmd sha256sum; then
      sha256sum -c "${base}.sha256"
    else
      if ! grep -q " ${base}$" "${base}.sha256" 2>/dev/null; then
        log_warn "Checksum file may not include the filename; attempting validation anyway."
      fi
      shasum -a 256 -c "${base}.sha256"
    fi
    popd >/dev/null
    log_success "Checksum OK."
  else
    log_warn "No checksum file found; skipping integrity verification."
  fi
}

_decrypt_if_needed() {
  local in="$1" out_dir="$2"
  local out_tgz="${out_dir}/backup.tar.gz"
  case "$in" in
    *.gpg)
      _have_cmd gpg || die "${E_MISSING_DEP:-3}" "gpg is required to decrypt ${in}"
      log_info "Decrypting backup..."
      if [[ -n "${GPG_PASSPHRASE}" ]]; then
        gpg --batch --yes --pinentry-mode=loopback --passphrase "${GPG_PASSPHRASE}" \
            --decrypt --output "${out_tgz}" "${in}" \
          || die "${E_GENERAL:-1}" "GPG decryption failed (loopback)."
      else
        gpg --quiet --decrypt --output "${out_tgz}" "${in}" \
          || die "${E_GENERAL:-1}" "GPG decryption failed."
      fi
      harden_file_permissions "${out_tgz}" "600" "decrypted backup" || true
      echo "${out_tgz}"
      ;;
    *.tar.gz|*.tgz)
      cp -f "${in}" "${out_tgz}"
      harden_file_permissions "${out_tgz}" "600" "backup archive" || true
      echo "${out_tgz}"
      ;;
    *)
      die "${E_INVALID_INPUT:-2}" "Unsupported backup extension. Use .tar.gz(.gpg) or .tgz(.gpg)."
      ;;
  esac
}

_tar_extract() {
  local tgz="$1" dest="$2"
  log_info "Unpacking backup archive..."
  tar -xzf "${tgz}" -C "${dest}"
  audit_security_configuration "${dest}/security-audit.txt"
}

ensure_helper_image() {
  if "${CONTAINER_RUNTIME}" image inspect "${TMP_IMAGE_ALPINE}" >/dev/null 2>&1; then
    echo "${TMP_IMAGE_ALPINE}"; return 0
  fi
  if retry_command 2 3 "${CONTAINER_RUNTIME}" pull "${TMP_IMAGE_ALPINE}"; then
    echo "${TMP_IMAGE_ALPINE}"; return 0
  fi
  log_warn "Could not use ${TMP_IMAGE_ALPINE}; trying ${TMP_IMAGE_BUSYBOX}..."
  if "${CONTAINER_RUNTIME}" image inspect "${TMP_IMAGE_BUSYBOX}" >/dev/null 2>&1 || \
     retry_command 2 3 "${CONTAINER_RUNTIME}" pull "${TMP_IMAGE_BUSYBOX}"; then
    echo "${TMP_IMAGE_BUSYBOX}"; return 0
  fi
  die "${E_GENERAL:-1}" "No suitable helper image (alpine/busybox) available."
}

_safe_wipe_volume() {
  local vol="$1" helper_image="$2"
  "${CONTAINER_RUNTIME}" run --rm -v "${vol}:/volume_data" "${helper_image}" \
    sh -c "find /volume_data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +"
}

_copy_into_volume() {
  local src_dir="$1" vol="$2" helper_image="$3"
  retry_command 2 3 bash -c \
    "'${CONTAINER_RUNTIME}' run --rm -v '${vol}:/volume_data' -v '${src_dir}:/backup_data:ro' ${helper_image} \
       sh -c \"cd /backup_data && tar -cpf - .\" \
       | '${CONTAINER_RUNTIME}' run --rm -i -v '${vol}:/volume_data' ${helper_image} \
         sh -c \"cd /volume_data && tar -xpf -\""
}

_apply_prefix_map() {
  local name="$1"
  if [[ -z "${MAP_PREFIX}" ]]; then echo "${name}"; return; fi
  local old="${MAP_PREFIX%%:*}"
  local new="${MAP_PREFIX##*:}"
  if [[ "${name}" == "${old}_"* ]]; then
    echo "${new}_${name#${old}_}"
  else
    echo "${name}"
  fi
}

_discover_volumes_from_manifest_or_dirs() {
  local stage="$1"
  local -a vols=()
  if [[ -f "${stage}/MANIFEST.txt" ]]; then
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*-\ (.+)$ ]] || continue
      vols+=("${BASH_REMATCH[1]}")
    done < <(sed -n '/^Volumes:/,$p' "${stage}/MANIFEST.txt")
  fi
  if ((${#vols[@]}==0)); then
    while IFS= read -r d; do
      local base; base="$(basename "$d")"
      [[ "${base}" == "MANIFEST.txt" ]] && continue
      vols+=("${base}")
    done < <(find "${stage}" -mindepth 1 -maxdepth 1 -type d -print)
  fi
  printf '%s\n' "${vols[@]}"
}

# ---- Main ---------------------------------------------------------------------
main() {
  log_info "🚀 Starting Cluster Restore"
  detect_container_runtime
  local helper_image; helper_image="$(ensure_helper_image)"
  local running
  running="$("${CONTAINER_RUNTIME}" ps -q || true)"
  if [[ -n "${running}" ]]; then
    die "${E_GENERAL:-1}" "Active containers detected. Stop the cluster before restoring."
  fi
  if ! is_true "${SKIP_ROLLBACK}"; then
    [[ -n "${ROLLBACK_GPG_RECIPIENT}" ]] || die "${E_INVALID_INPUT:-2}" "Missing --rollback-gpg-recipient (or use --skip-rollback)."
    log_warn "A rollback backup of CURRENT data will be created before restore."
    _confirm_or_exit "Proceed with rollback backup?"
    mkdir -p "${SCRIPT_DIR}/rollback_backups"
    harden_file_permissions "${SCRIPT_DIR}/rollback_backups" "700" "rollback backups directory" || true
    "${SCRIPT_DIR}/backup_cluster.sh" --output-dir "${SCRIPT_DIR}/rollback_backups" \
      --gpg-recipient "${ROLLBACK_GPG_RECIPIENT}" \
      || die "${E_GENERAL:-1}" "Failed to create rollback backup."
    log_success "Rollback backup created in ${SCRIPT_DIR}/rollback_backups/"
  else
    log_warn "Skipping rollback backup at user request."
  fi
  _verify_checksum_if_present "${BACKUP_FILE}"
  local staging; staging="$(mktemp -d -t cluster-restore-XXXXXX)"
  register_cleanup "rm -rf '${staging}'"
  harden_file_permissions "${staging}" "700" "staging directory" || true
  local tgz; tgz="$(_decrypt_if_needed "${BACKUP_FILE}" "${staging}")"
  _tar_extract "${tgz}" "${staging}"
  declare -a src_vols
  if [[ -n "${ONLY_VOLUMES_CSV}" ]]; then
    IFS=',' read -r -a src_vols <<< "${ONLY_VOLUMES_CSV}"
  else
    mapfile -t src_vols < <(_discover_volumes_from_manifest_or_dirs "${staging}")
  fi
  ((${#src_vols[@]})) || die "${E_GENERAL:-1}" "No source volumes discovered in backup."
  log_info "Volumes to restore (source names): ${src_vols[*]}"
  [[ -n "${MAP_PREFIX}" ]] && log_info "Applying prefix map: ${MAP_PREFIX}"
  for src_name in "${src_vols[@]}"; do
    local src_dir="${staging}/${src_name}"
    if [[ ! -d "${src_dir}" ]]; then
      log_warn "Source directory missing in backup: ${src_name} — skipping."
      continue
    fi
    local dest_vol; dest_vol="$(_apply_prefix_map "${src_name}")"
    log_info "  -> Restoring '${src_name}' -> volume '${dest_vol}'"
    "${CONTAINER_RUNTIME}" volume create "${dest_vol}" >/dev/null
    _safe_wipe_volume "${dest_vol}" "${helper_image}"
    _copy_into_volume "${src_dir}" "${dest_vol}" "${helper_image}"
    log_success "     Restored volume '${dest_vol}'."
  done
  audit_security_configuration "${staging}/security-audit.txt"
  log_success "✅ Restore complete. You can now start the cluster (e.g., ./start_cluster.sh)."
}

RESTORE_CLUSTER_VERSION="1.0.0"
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  run_entrypoint main "$@"
fi

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "restore_cluster"

# Set error handling


