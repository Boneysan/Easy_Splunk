#!/usr/bin/env bash
#
# ==============================================================================
# backup_cluster.sh  — Secure encrypted backup for container volumes
# ==============================================================================
# Features:
#   • Select volumes explicitly (--volumes) or by project/prefix (--project)
#   • Encrypted output via GPG recipient (public key) or symmetric passphrase
#   • Creates manifest + SHA256 checksum
#   • Resilient volume copy via retry + temporary container
#   • Safe file perms (umask 077)
#
# Examples:
#   ./backup_cluster.sh --output-dir ./backups --gpg-recipient ops@example.com \
#       --project my-app --gzip-level 6
#   ./backup_cluster.sh --output-dir ./backups --no-encrypt --volumes my-app_app-data,my-app_redis-data
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/runtime-detection.sh, gpg (unless --no-encrypt)
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# deps
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/error-handling.sh"
source "${SCRIPT_DIR}/lib/runtime-detection.sh"

umask 077  # keep artifacts private

# ---- Defaults -----------------------------------------------------------------
OUTPUT_DIR=""
GPG_RECIPIENT=""
ALGO="gpg"           # gpg | gpg-symmetric
NO_ENCRYPT="false"
VOLUMES_CSV=""       # explicit list "vol1,vol2"
PROJECT_PREFIX=""    # auto-discover volumes starting with this prefix
GZIP_LEVEL="6"       # 1..9
MANIFEST="true"      # write manifest file of contents
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"  # only used for hints/logs

# ---- CLI ----------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") --output-dir <path> [options]

Required:
  --output-dir <path>       Where to write the backup artifacts

Encryption (choose one; default is recipient-based):
  --gpg-recipient <id>      GPG key ID/email to encrypt to (public-key encryption)
  --algo gpg-symmetric      Use symmetric encryption (prompted passphrase)
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
    --output-dir)      OUTPUT_DIR="${2:?}"; shift 2;;
    --gpg-recipient)   GPG_RECIPIENT="${2:?}"; shift 2;;
    --algo)            ALGO="${2:?}"; shift 2;;
    --no-encrypt)      NO_ENCRYPT="true"; shift;;
    --volumes)         VOLUMES_CSV="${2:?}"; shift 2;;
    --project)         PROJECT_PREFIX="${2:?}"; shift 2;;
    --gzip-level)      GZIP_LEVEL="${2:?}"; shift 2;;
    --no-manifest)     MANIFEST="false"; shift;;
    -h|--help)         usage; exit 0;;
    *) die "${E_INVALID_INPUT}" "Unknown option: $1";;
  esac
done

# ---- Validation ---------------------------------------------------------------
if is_empty "${OUTPUT_DIR}"; then
  die "${E_INVALID_INPUT}" "Missing --output-dir"
fi

if [[ "${NO_ENCRYPT}" != "true" ]]; then
  if [[ "${ALGO}" == "gpg" && -z "${GPG_RECIPIENT}" ]]; then
    die "${E_INVALID_INPUT}" "Encryption selected but no --gpg-recipient provided. Use --no-encrypt or --algo gpg-symmetric."
  fi
  if ! command -v gpg &>/dev/null; then
    die "${E_MISSING_DEP}" "gpg is required for encryption."
  fi
  if [[ "${ALGO}" == "gpg" ]] && ! gpg --list-keys "${GPG_RECIPIENT}" &>/dev/null; then
    die "${E_INVALID_INPUT}" "GPG recipient '${GPG_RECIPIENT}' not found in keyring."
  fi
fi

if [[ -n "${VOLUMES_CSV}" && -n "${PROJECT_PREFIX}" ]]; then
  die "${E_INVALID_INPUT}" "Use either --volumes or --project, not both."
fi

if ! [[ "${GZIP_LEVEL}" =~ ^[1-9]$ ]]; then
  die "${E_INVALID_INPUT}" "--gzip-level must be 1..9"
fi

mkdir -p "${OUTPUT_DIR}"

# ---- Runtime & volume discovery ----------------------------------------------
detect_container_runtime

# Build list of volumes
declare -a VOLUMES_TO_BACKUP=()
if [[ -n "${VOLUMES_CSV}" ]]; then
  IFS=',' read -r -a VOLUMES_TO_BACKUP <<< "${VOLUMES_CSV}"
elif [[ -n "${PROJECT_PREFIX}" ]]; then
  # List volumes and filter by prefix_
  mapfile -t VOLUMES_TO_BACKUP < <("${CONTAINER_RUNTIME}" volume ls --format '{{.Name}}' | grep -E "^${PROJECT_PREFIX}_" || true)
  if ((${#VOLUMES_TO_BACKUP[@]} == 0)); then
    die "${E_INVALID_INPUT}" "No volumes found with prefix '${PROJECT_PREFIX}_'."
  fi
else
  # Fallback: the original defaults from your script (kept for backward compat)
  VOLUMES_TO_BACKUP=( "my-app_app-data" "my-app_redis-data" "my-app_prometheus-data" "my-app_grafana-data" )
  log_warn "No --volumes/--project provided; using default volume list: ${VOLUMES_TO_BACKUP[*]}"
fi

# ---- Helpers ------------------------------------------------------------------
_copy_volume_into_stage() {
  local volume="$1" stage_dir="$2"
  log_info "  -> Backing up volume: ${volume}"
  # Use a temporary container to copy files preserving metadata
  # (cp -a is OK for typical app data; tar streaming could be added if needed)
  retry_command 2 3 "${CONTAINER_RUNTIME}" run --rm \
    -v "${volume}:/volume_data:ro" \
    -v "${stage_dir}:/backup_stage" \
    alpine sh -c "mkdir -p /backup_stage/${volume} && cp -a /volume_data/. /backup_stage/${volume}/"
}

write_checksum() {
  local file="$1"
  local out="${file}.sha256"
  if command -v sha256sum &>/dev/null; then
    sha256sum "$(basename -- "$file")" > "${out}"
  else
    shasum -a 256 "$(basename -- "$file")" > "${out}"
  fi
  log_info "Checksum written: ${out}"
}

# ---- Main ---------------------------------------------------------------------
main() {
  log_info "🚀 Starting Encrypted Backup"
  log_info "Runtime: ${CONTAINER_RUNTIME}"

  # Staging
  local staging_dir
  staging_dir="$(mktemp -d -t cluster-backup-XXXXXX)"
  add_cleanup_task "rm -rf '${staging_dir}'"
  log_debug "Staging: ${staging_dir}"

  # Extract volumes
  log_info "Extracting data from volumes..."
  local any_found=false
  for v in "${VOLUMES_TO_BACKUP[@]}"; do
    if ! "${CONTAINER_RUNTIME}" volume inspect "${v}" &>/dev/null; then
      log_warn "  !! Volume not found, skipping: ${v}"
      continue
    fi
    any_found=true
    _copy_volume_into_stage "${v}" "${staging_dir}"
  done
  if ! is_true "${any_found}"; then
    die "${E_INVALID_INPUT}" "No valid volumes were found to back up."
  fi

  # Manifest (what & when)
  if is_true "${MANIFEST}"; then
    cat > "${staging_dir}/MANIFEST.txt" <<EOF
# Backup Manifest
Created: $(date -u +'%Y-%m-%dT%H:%M:%SZ')
Runtime: ${CONTAINER_RUNTIME}
Compose file (hint): ${COMPOSE_FILE}
Volumes:
$(printf -- ' - %s\n' "${VOLUMES_TO_BACKUP[@]}")
EOF
  fi

  # Create tarball
  local ts archive_name archive_path
  ts="$(date +%Y%m%d-%H%M%S)"
  archive_name="backup-${ts}.tar.gz"
  archive_path="${staging_dir}/${archive_name}"
  log_info "Creating compressed archive (${archive_name})..."
  # shellcheck disable=SC2046
  ( cd "${staging_dir}" && tar -czf "${archive_path}" --owner=0 --group=0 --mode=go-w --gzip --options "gzip:compression-level=${GZIP_LEVEL}" . )
  log_success "Archive created."

  # Move + encrypt
  local final_plain="${OUTPUT_DIR}/${archive_name}"
  mv -f "${archive_path}" "${final_plain}"

  if [[ "${NO_ENCRYPT}" == "true" ]]; then
    log_warn "Encryption disabled by --no-encrypt. Writing plaintext archive."
    ( cd "${OUTPUT_DIR}" && write_checksum "${final_plain}" )
    log_success "✅ Backup complete (UNENCRYPTED): ${final_plain}"
    return 0
  fi

  local encrypted="${final_plain}.gpg"
  log_info "Encrypting archive -> ${encrypted}"
  if [[ "${ALGO}" == "gpg-symmetric" ]]; then
    # Symmetric: prompt for passphrase interactively (safe for cron with gpg-agent)
    if ! gpg --batch --yes --symmetric --cipher-algo AES256 --output "${encrypted}" "${final_plain}"; then
      die "${E_GENERAL}" "GPG symmetric encryption failed."
    fi
  else
    # Recipient-based
    if ! gpg --batch --yes --encrypt --recipient "${GPG_RECIPIENT}" --output "${encrypted}" "${final_plain}"; then
      die "${E_GENERAL}" "GPG recipient encryption failed."
    fi
  fi

  # Tamper-evident checksum of the encrypted blob
  ( cd "${OUTPUT_DIR}" && write_checksum "${encrypted}" )

  # Remove plaintext after successful encryption
  rm -f "${final_plain}"

  log_success "✅ Encrypted backup created: ${encrypted}"
  log_info    "   Checksum file: ${encrypted}.sha256"
}

main "$@"
