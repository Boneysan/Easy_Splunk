#!/usr/bin/env bash
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
#
# Examples:
#   ./restore_cluster.sh --backup-file backups/backup-20250101-120000.tar.gz.gpg \
#       --rollback-gpg-recipient ops@example.com --map-prefix prod:dev
#   ./restore_cluster.sh --backup-file backups/plain.tgz --skip-rollback \
#       --only-volumes dev_app-data,dev_redis-data
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/runtime-detection.sh, gpg (if .gpg)
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# deps
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/error-handling.sh"
source "${SCRIPT_DIR}/lib/runtime-detection.sh"

# ---- Args ---------------------------------------------------------------------
BACKUP_FILE=""
SKIP_ROLLBACK="false"
ROLLBACK_GPG_RECIPIENT=""
ONLY_VOLUMES_CSV=""      # explicit list of target volume names to restore
MAP_PREFIX=""            # old:new (rename volumes during restore)
AUTO_YES=0

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
    --backup-file) BACKUP_FILE="${2:?}"; shift 2;;
    --skip-rollback) SKIP_ROLLBACK="true"; shift;;
    --rollback-gpg-recipient) ROLLBACK_GPG_RECIPIENT="${2:?}"; shift 2;;
    --only-volumes) ONLY_VOLUMES_CSV="${2:?}"; shift 2;;
    --map-prefix) MAP_PREFIX="${2:?old:new}"; shift 2;;
    -y|--yes) AUTO_YES=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "${E_INVALID_INPUT:-2}" "Unknown option: $1";;
  esac
done

[[ -n "${BACKUP_FILE}" && -f "${BACKUP_FILE}" ]] || die "${E_INVALID_INPUT:-2}" "Backup file missing: ${BACKUP_FILE}"

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
      # normalize format to "<hash>  <file>"
      if ! grep -q " ${base}$" "${base}.sha256"; then
        log_warn "Checksum file format may not match expected 'hash  file' style."
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
      gpg --quiet --decrypt --output "${out_tgz}" "${in}" \
        || die "${E_GENERAL:-1}" "GPG decryption failed. Wrong key/passphrase?"
      echo "${out_tgz}"
      ;;
    *.tar.gz|*.tgz)
      cp -f "${in}" "${out_tgz}"
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
}

_safe_wipe_volume() {
  # Do NOT use rm -rf /volume_data/.* (dangerous).
  # Use find with -mindepth to avoid . and ..
  "${CONTAINER_RUNTIME}" run --rm -v "$1:/volume_data" alpine \
    sh -c "find /volume_data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +"
}

_copy_into_volume() {
  local src_dir="$1" vol="$2"
  # Preserve perms/mtime/links reasonably via cp -a; Alpine provides it.
  retry_command 2 3 "${CONTAINER_RUNTIME}" run --rm \
    -v "${vol}:/volume_data" -v "${src_dir}:/backup_data:ro" \
    alpine sh -c "cp -a /backup_data/. /volume_data/"
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
    # Manifest entries formatted as:
    # Volumes:
    #  - prefix_volume
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*-\ (.+)$ ]] || continue
      vols+=("${BASH_REMATCH[1]}")
    done < <(sed -n '/^Volumes:/,$p' "${stage}/MANIFEST.txt")
  fi

  # Fallback: any first-level directories other than MANIFEST.txt
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

  # 0) Sanity: ask user to confirm containers are stopped
  local running
  running="$("${CONTAINER_RUNTIME}" ps -q || true)"
  if [[ -n "${running}" ]]; then
    die "${E_GENERAL:-1}" "Active containers detected. Stop the cluster before restoring."
  fi

  # 1) Optional rollback backup
  if ! is_true "${SKIP_ROLLBACK}"; then
    [[ -n "${ROLLBACK_GPG_RECIPIENT}" ]] || die "${E_INVALID_INPUT:-2}" "Missing --rollback-gpg-recipient (or use --skip-rollback)."
    log_warn "A rollback backup of CURRENT data will be created before restore."
    _confirm_or_exit "Proceed with rollback backup?"
    mkdir -p rollback_backups
    ./backup_cluster.sh --output-dir rollback_backups --gpg-recipient "${ROLLBACK_GPG_RECIPIENT}" \
      || die "${E_GENERAL:-1}" "Failed to create rollback backup."
    log_success "Rollback backup created in ./rollback_backups/"
  else
    log_warn "Skipping rollback backup at user request."
  fi

  # 2) Verify checksum if present
  _verify_checksum_if_present "${BACKUP_FILE}"

  # 3) Decrypt (if needed) and unpack into staging
  local staging; staging="$(mktemp -d -t cluster-restore-XXXXXX)"
  add_cleanup_task "rm -rf '${staging}'"
  local tgz; tgz="$(_decrypt_if_needed "${BACKUP_FILE}" "${staging}")"
  _tar_extract "${tgz}" "${staging}"

  # 4) Determine which volumes to restore
  declare -a src_vols
  if [[ -n "${ONLY_VOLUMES_CSV}" ]]; then
    IFS=',' read -r -a src_vols <<< "${ONLY_VOLUMES_CSV}"
  else
    mapfile -t src_vols < <(_discover_volumes_from_manifest_or_dirs "${staging}")
  fi

  if ((${#src_vols[@]}==0)); then
    die "${E_GENERAL:-1}" "No source volumes discovered in backup."
  fi

  log_info "Volumes to restore (source names): ${src_vols[*]}"
  [[ -n "${MAP_PREFIX}" ]] && log_info "Applying prefix map: ${MAP_PREFIX}"

  # 5) Restore loop
  for src_name in "${src_vols[@]}"; do
    local src_dir="${staging}/${src_name}"
    if [[ ! -d "${src_dir}" ]]; then
      log_warn "Source directory missing in backup: ${src_name} — skipping."
      continue
    fi

    local dest_vol; dest_vol="$(_apply_prefix_map "${src_name}")"
    log_info "  -> Restoring '${src_name}' -> volume '${dest_vol}'"

    # Ensure volume exists
    "${CONTAINER_RUNTIME}" volume create "${dest_vol}" >/dev/null

    # Wipe existing content safely, then copy
    _safe_wipe_volume "${dest_vol}"
    _copy_into_volume "${src_dir}" "${dest_vol}"

    log_success "     Restored volume '${dest_vol}'."
  done

  log_success "✅ Restore complete. You can now start the cluster (e.g., ./start_cluster.sh)."
}

main "$@"
