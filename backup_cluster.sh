#!/usr/bin/env bash
#
# ==============================================================================
# backup_cluster.sh  — Secure encrypted backup for container volumes
# ==============================================================================
# Features:
#   • Select volumes explicitly (--volumes) or by project/prefix (--project)
#   • Encrypted output via GPG recipient (public key) or symmetric passphrase
#   • Creates manifest + SHA256 checksum
#   • Resilient volume copy via retry + temporary container (alpine/busybox)
#   • Safe file perms (umask 077)
#   • Integration with new backup manager system
#
# Examples:
#   ./backup_cluster.sh --output-dir ./backups --gpg-recipient ops@example.com \
#       --project my-app --gzip-level 6
#   ./backup_cluster.sh --output-dir ./backups --no-encrypt \
#       --volumes my-app_app-data,my-app_redis-data
#   ./backup_cluster.sh --use-backup-manager --type full
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/runtime-detection.sh, lib/security.sh, gpg (unless --no-encrypt)
# Version: 2.0.0
# ==============================================================================

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "backup_cluster"

# Set error handling
set -euo pipefail
IFS=$'\n\t'

# deps
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/runtime-detection.sh
source "${SCRIPT_DIR}/lib/runtime-detection.sh"
# shellcheck source=lib/security.sh
source "${SCRIPT_DIR}/lib/security.sh"

# --- Version Checks ------------------------------------------------------------
if [[ "${SECURITY_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "backup_cluster.sh requires security.sh version >= 1.0.0"
fi

umask 077

# ---- Defaults -----------------------------------------------------------------
OUTPUT_DIR=""
GPG_RECIPIENT=""
ALGO="gpg"
NO_ENCRYPT="false"
VOLUMES_CSV=""
PROJECT_PREFIX=""
GZIP_LEVEL="6"
MANIFEST="true"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
TMP_IMAGE_ALPINE="${TMP_IMAGE_ALPINE:-alpine:3.20}"
TMP_IMAGE_BUSYBOX="${TMP_IMAGE_BUSYBOX:-busybox:1.36}"
: "${GPG_PASSPHRASE:=}"
: "${SECRETS_DIR:=./secrets}"

usage() {
  cat <<EOF
Usage: $(basename "$0") --output-dir <path> [options]

Required:
  --output-dir <path>       Where to write the backup artifacts

Encryption (choose one; default is recipient-based):
  --gpg-recipient <id>      GPG key ID/email to encrypt to (public-key encryption)
  --algo gpg-symmetric      Use symmetric encryption (uses \$GPG_PASSPHRASE if set, else prompts)
  --no-encrypt              Do NOT encrypt the archive (testing only)

Volume selection (choose one):
  --volumes <csv>           Comma-separated named volumes to back up
  --project <prefix>        Back up all volumes whose name starts with <prefix>_

Options:
  --gzip-level <1-9>        gzip compression level (default: ${GZIP_LEVEL})
  --no-manifest             Do not write a contents manifest
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)      OUTPUT_DIR="${2:?}"; shift 2 ;;
    --gpg-recipient)   GPG_RECIPIENT="${2:?}"; shift 2 ;;
    --algo)            ALGO="${2:?}"; shift 2 ;;
    --no-encrypt)      NO_ENCRYPT="true"; shift ;;
    --volumes)         VOLUMES_CSV="${2:?}"; shift 2 ;;
    --project)         PROJECT_PREFIX="${2:?}"; shift 2 ;;
    --gzip-level)      GZIP_LEVEL="${2:?}"; shift 2 ;;
    --no-manifest)     MANIFEST="false"; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) die "${E_INVALID_INPUT:-2}" "Unknown option: $1" ;;
  esac
done

# ---- Validation ---------------------------------------------------------------
if is_empty "${OUTPUT_DIR}"; then
  die "${E_INVALID_INPUT:-2}" "Missing --output-dir"
fi
if [[ "${NO_ENCRYPT}" != "true" ]]; then
  if [[ "${ALGO}" == "gpg" && -z "${GPG_RECIPIENT}" ]]; then
    die "${E_INVALID_INPUT:-2}" "Encryption selected but no --gpg-recipient provided. Use --no-encrypt or --algo gpg-symmetric."
  fi
  if ! command -v gpg &>/dev/null; then
    die "${E_MISSING_DEP:-3}" "gpg is required for encryption."
  fi
  if [[ "${ALGO}" == "gpg" ]] && ! gpg --list-keys "${GPG_RECIPIENT}" &>/dev/null; then
    die "${E_INVALID_INPUT:-2}" "GPG recipient '${GPG_RECIPIENT}' not found in keyring."
  fi
fi
if [[ -n "${VOLUMES_CSV}" && -n "${PROJECT_PREFIX}" ]]; then
  die "${E_INVALID_INPUT:-2}" "Use either --volumes or --project, not both."
fi
if ! [[ "${GZIP_LEVEL}" =~ ^[1-9]$ ]]; then
  die "${E_INVALID_INPUT:-2}" "--gzip-level must be 1..9"
fi
mkdir -p "${OUTPUT_DIR}"
harden_file_permissions "${OUTPUT_DIR}" "700" "backup directory" || true

# ---- Runtime & volume discovery ----------------------------------------------
detect_container_runtime

_escape_ere() {
  printf '%s' "$1" | sed -e 's/[.[\*^$()+?{}|\\]/\\&/g'
}

declare -a VOLUMES_TO_BACKUP=()
if [[ -n "${VOLUMES_CSV}" ]]; then
  IFS=',' read -r -a VOLUMES_TO_BACKUP <<< "${VOLUMES_CSV}"
elif [[ -n "${PROJECT_PREFIX}" ]]; then
  safe_prefix="$(_escape_ere "${PROJECT_PREFIX}")"
  mapfile -t VOLUMES_TO_BACKUP < <("${CONTAINER_RUNTIME}" volume ls --format '{{.Name}}' | grep -E "^${safe_prefix}_" || true)
  if ((${#VOLUMES_TO_BACKUP[@]} == 0)); then
    die "${E_INVALID_INPUT:-2}" "No volumes found with prefix '${PROJECT_PREFIX}_'."
  fi
else
  VOLUMES_TO_BACKUP=( "my-app_app-data" "my-app_redis-data" "my-app_prometheus-data" "my-app_grafana-data" )
  log_warn "No --volumes/--project provided; using default volume list: ${VOLUMES_TO_BACKUP[*]}"
fi

# ---- Helpers ------------------------------------------------------------------
ensure_helper_image() {
  if "${CONTAINER_RUNTIME}" image inspect "${TMP_IMAGE_ALPINE}" >/dev/null 2>&1; then
    echo "${TMP_IMAGE_ALPINE}"
    return 0
  fi
  if retry_command 2 3 "${CONTAINER_RUNTIME}" pull "${TMP_IMAGE_ALPINE}"; then
    echo "${TMP_IMAGE_ALPINE}"
    return 0
  fi
  log_warn "Could not use ${TMP_IMAGE_ALPINE}; trying ${TMP_IMAGE_BUSYBOX}..."
  if "${CONTAINER_RUNTIME}" image inspect "${TMP_IMAGE_BUSYBOX}" >/dev/null 2>&1 || \
     retry_command 2 3 "${CONTAINER_RUNTIME}" pull "${TMP_IMAGE_BUSYBOX}"; then
    echo "${TMP_IMAGE_BUSYBOX}"
    return 0
  fi
  die "${E_GENERAL:-1}" "No suitable helper image (alpine/busybox) available to copy volumes."
}

_copy_volume_into_stage() {
  local volume="$1" stage_dir="$2" helper_image="$3"
  log_info "  -> Backing up volume: ${volume}"
  mkdir -p "${stage_dir}/${volume}"
  if [[ "${helper_image}" == "${TMP_IMAGE_ALPINE}" ]]; then
    retry_command 2 3 bash -c \
      "'${CONTAINER_RUNTIME}' run --rm -v '${volume}:/volume_data:ro' ${helper_image} \
        sh -c \"cd /volume_data && tar -cpf - .\" \
        | tar -xpf - -C '${stage_dir}/${volume}'"
  else
    retry_command 2 3 bash -c \
      "'${CONTAINER_RUNTIME}' run --rm -v '${volume}:/volume_data:ro' ${helper_image} \
        sh -c \"cd /volume_data && tar -cpf - .\" \
        | tar -xpf - -C '${stage_dir}/${volume}'"
  fi
}

write_checksum() {
  local file="$1"
  local out="${file}.sha256"
  if command -v sha256sum &>/dev/null; then
    ( cd "$(dirname -- "${file}")" && sha256sum "$(basename -- "${file}")" ) | write_secret_file "${out}" - "checksum"
  else
    ( cd "$(dirname -- "${file}")" && shasum -a 256 "$(basename -- "${file}")" ) | write_secret_file "${out}" - "checksum"
  fi
  log_info "Checksum written: ${out}"
}

# ---- Main ---------------------------------------------------------------------
main() {
  log_info "🚀 Starting Encrypted Backup"
  log_info "Runtime: ${CONTAINER_RUNTIME}"
  local helper_image
  helper_image="$(ensure_helper_image)"
  local staging_dir
  staging_dir="$(mktemp -d -t cluster-backup-XXXXXX)"
  register_cleanup "rm -rf '${staging_dir}'"
  log_debug "Staging: ${staging_dir}"
  log_info "Extracting data from volumes..."
  local any_found="false"
  for v in "${VOLUMES_TO_BACKUP[@]}"; do
    if ! "${CONTAINER_RUNTIME}" volume inspect "${v}" &>/dev/null; then
      log_warn "  !! Volume not found, skipping: ${v}"
      continue
    fi
    any_found="true"
    _copy_volume_into_stage "${v}" "${staging_dir}" "${helper_image}"
  done
  if ! is_true "${any_found}"; then
    die "${E_INVALID_INPUT:-2}" "No valid volumes were found to back up."
  fi
  if is_true "${MANIFEST}"; then
    write_secret_file "${staging_dir}/MANIFEST.txt" "$(cat <<EOF
# Backup Manifest
Created: $(date -u +'%Y-%m-%dT%H:%M:%SZ')
Runtime: ${CONTAINER_RUNTIME}
Compose file (hint): ${COMPOSE_FILE}
Volumes:
$(printf -- ' - %s\n' "${VOLUMES_TO_BACKUP[@]}")
EOF
)" "MANIFEST.txt"
  fi
  local ts archive_name archive_path
  ts="$(date +%Y%m%d-%H%M%S)"
  archive_name="backup-${ts}.tar.gz"
  archive_path="${staging_dir}/${archive_name}"
  log_info "Creating compressed archive (${archive_name})..."
  ( cd "${staging_dir}" && GZIP="-${GZIP_LEVEL}" tar -czf "${archive_path}" --owner=0 --group=0 . )
  [[ -s "${archive_path}" ]] || die "${E_GENERAL:-1}" "Archive creation failed."
  log_success "Archive created."
  local final_plain="${OUTPUT_DIR}/${archive_name}"
  mv -f "${archive_path}" "${final_plain}"
  harden_file_permissions "${final_plain}" "600" "backup archive" || true
  if [[ "${NO_ENCRYPT}" == "true" ]]; then
    log_warn "Encryption disabled by --no-encrypt. Writing plaintext archive."
    write_checksum "${final_plain}"
    audit_security_configuration "${OUTPUT_DIR}/security-audit.txt"
    log_success "✅ Backup complete (UNENCRYPTED): ${final_plain}"
    return 0
  fi
  local encrypted="${final_plain}.gpg"
  log_info "Encrypting archive -> ${encrypted}"
  if [[ "${ALGO}" == "gpg-symmetric" ]]; then
    if [[ -n "${GPG_PASSPHRASE}" ]]; then
      gpg --batch --yes --pinentry-mode=loopback --passphrase "${GPG_PASSPHRASE}" \
          --symmetric --cipher-algo AES256 --output "${encrypted}" "${final_plain}" \
        || die "${E_GENERAL:-1}" "GPG symmetric encryption failed."
    else
      gpg --batch --yes --symmetric --cipher-algo AES256 --output "${encrypted}" "${final_plain}" \
        || die "${E_GENERAL:-1}" "GPG symmetric encryption failed (no passphrase in env; interactive prompt may be required)."
    fi
  else
    gpg --batch --yes --encrypt --recipient "${GPG_RECIPIENT}" --output "${encrypted}" "${final_plain}" \
      || die "${E_GENERAL:-1}" "GPG recipient encryption failed."
  fi
  [[ -s "${encrypted}" ]] || die "${E_GENERAL:-1}" "Encrypted archive is empty."
  harden_file_permissions "${encrypted}" "600" "encrypted backup" || true
  write_checksum "${encrypted}"
  rm -f "${final_plain}"
  audit_security_configuration "${OUTPUT_DIR}/security-audit.txt"
  log_success "✅ Encrypted backup created: ${encrypted}"
  log_info    "   Checksum file: ${encrypted}.sha256"
}

BACKUP_CLUSTER_VERSION="1.0.0"
main "$@"