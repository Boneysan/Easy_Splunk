#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# ==============================================================================
# lib/air-gapped.sh
# Air-gapped bundle creation, verification, and loading.
# Version: 1.0.0
readonly AIR_GAPPED_VERSION="1.0.0"
#
# Dependencies (required):
#   - lib/core.sh              (log_*, die, have_cmd, register_cleanup)
#   - lib/error-handling.sh    (atomic_write, atomic_write_file, with_retry)
#   - lib/security.sh          (write_secret_file, audit_security_configuration)
#
# Dependencies (detected/optional at runtime):
#   - lib/runtime.sh (detect_container_runtime, compose, capability vars)
#   - lib/versions.sh          (load_versions_file, verify_versions_env, list_all_images)
#
# Expects (from required deps): log_*, die, have_cmd, atomic_write{,_file}, with_retry
# Provides:
#   - pull_images
#   - save_images_archive
#   - create_airgapped_bundle
#   - load_image_archive
#   - load_airgapped_bundle
#   - create_image_archive (legacy thin helper)
#
# Convenience (new):
#   - collect_images_from_versions_file [versions.env]
#   - create_bundle_from_versions <bundle_dir> [versions.env]
#   - verify_images_present <img...>
#   - verify_bundle <bundle_dir>
#   - bundle_info <bundle_dir>
#   - list_bundle_images <bundle_dir>
#
# Notes:
#   * Archive compression via TARBALL_COMPRESSION = gzip|zstd|none
#   * Checksums use sha256; *.sha256 written via atomic_write
#   * Designed to be idempotent; safe to re-run
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

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1 || ! command -v with_retry >/dev/null 2>&1 || ! command -v write_secret_file >/dev/null 2>&1; then
  echo "FATAL: core.sh, error-handling.sh, and security.sh must be sourced before lib/air-gapped.sh" >&2
  exit 1
fi

# ---- Tunables ------------------------------------------------------------------
: "${PULL_RETRIES:=5}"
: "${PULL_BASE_DELAY:=1}"
: "${PULL_MAX_DELAY:=20}"
: "${TARBALL_COMPRESSION:=gzip}"   # gzip|zstd|none
: "${BUNDLE_SCHEMA_VERSION:=1}"
: "${VERIFY_AFTER_LOAD:=0}"        # 1 = re-list/inspect images after load
: "${SECRETS_DIR:=./secrets}"      # For secure versions.env storage

# ---- Internal: ensure a runtime is set/detected --------------------------------
__ensure_runtime() {
  # Honor already-set runtime
  if [[ -n "${CONTAINER_RUNTIME:-}" ]]; then
    return 0
  fi
  # Try to detect if runtime-detection is available
  if command -v detect_container_runtime >/dev/null 2>&1; then
    detect_container_runtime
    return 0
  fi
  # Heuristic fallback: prefer podman, then docker
  if command -v podman >/dev/null 2>&1; then
    export CONTAINER_RUNTIME="podman"
    return 0
  fi
  if command -v docker >/dev/null 2>&1; then
    export CONTAINER_RUNTIME="docker"
    return 0
  fi
  die "${E_MISSING_DEP:-3}" "No container runtime (podman/docker) found."
}

# ==============================================================================
# Checksum helpers
# ==============================================================================

# __sha256_file <path> -> prints sha256 hex digest
__sha256_file() {
  local file="${1:?file required}"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file}" | awk '{print $1}'
  else
    die "${E_MISSING_DEP:-3}" "Need sha256sum or shasum to compute checksums."
  fi
}

# generate_checksum_file <file>
generate_checksum_file() {
  local file="${1:?file required}"
  [[ -f "${file}" ]] || die "${E_INVALID_INPUT:-2}" "Cannot generate checksum; file not found: ${file}"
  local out="${file}.sha256"
  local sum
  sum="$(__sha256_file "${file}")"
  printf '%s  %s\n' "${sum}" "$(basename -- "${file}")" | atomic_write "${out}" "644"
  log_success "Checksum written: ${out}"
}

# verify_checksum_file <file>  -> 0 valid, 1 invalid
verify_checksum_file() {
  local file="${1:?file required}"
  local sumfile="${file}.sha256"
  if [[ ! -f "${file}" || ! -f "${sumfile}" ]]; then
    log_error "Missing file or checksum: ${file} / ${sumfile}"
    return 1
  fi
  local expected actual
  expected="$(awk '{print $1}' < "${sumfile}")"
  actual="$(__sha256_file "${file}")"
  if [[ "${expected}" == "${actual}" ]]; then
    log_debug "Checksum ok for $(basename -- "${file}")"
    return 0
  fi
  log_error "Checksum mismatch for ${file}"
  return 1
}

# ==============================================================================
# Image pulling & saving
# ==============================================================================

# pull_images <img...>
pull_images() {
  __ensure_runtime
  local imgs=( "$@" )
  (( ${#imgs[@]} > 0 )) || die "${E_INVALID_INPUT:-2}" "pull_images: no images"
  log_info "Pulling ${#imgs[@]} image(s) with ${CONTAINER_RUNTIME}..."
  local img
  for img in "${imgs[@]}"; do
    log_info "  -> ${img}"
    with_retry --retries "${PULL_RETRIES}" --base-delay "${PULL_BASE_DELAY}" --max-delay "${PULL_MAX_DELAY}" -- \
      "${CONTAINER_RUNTIME}" pull "${img}"
  done
  log_success "All images pulled."
}

# save_images_archive <output_tar> <img...>
# Respects TARBALL_COMPRESSION (gzip|zstd|none)
save_images_archive() {
  __ensure_runtime
  local out="${1:?output tar required}"; shift
  local imgs=( "$@" )
  (( ${#imgs[@]} > 0 )) || die "${E_INVALID_INPUT:-2}" "save_images_archive: no images"

  local out_dir; out_dir="$(dirname -- "${out}")"
  mkdir -p -- "${out_dir}"

  local tmp_tar
  tmp_tar="$(mktemp "${out}.tmp.XXXXXX")"
  register_cleanup "rm -f '${tmp_tar}'"

  log_info "Saving ${#imgs[@]} image(s) to archive..."
  "${CONTAINER_RUNTIME}" save -o "${tmp_tar}" "${imgs[@]}"

  local final="${out}"
  case "${TARBALL_COMPRESSION}" in
    gzip)
      log_info "Compressing archive with gzip..."
      if have_cmd pigz; then pigz -f "${tmp_tar}" && final="${out}.gz"
      else gzip -f "${tmp_tar}" && final="${out}.gz"
      fi
      ;;
    zstd)
      have_cmd zstd || die "${E_MISSING_DEP:-3}" "zstd not found; install or set TARBALL_COMPRESSION=gzip/none."
      log_info "Compressing archive with zstd..."
      zstd -q -f -T0 "${tmp_tar}" -o "${out}.zst"
      rm -f "${tmp_tar}"
      final="${out}.zst"
      ;;
    none) final="${out}" ;;
    *) die "${E_INVALID_INPUT:-2}" "Unknown TARBALL_COMPRESSION='${TARBALL_COMPRESSION}'" ;;
  esac

  # If we used compression, tmp_tar may already be removed.
  [[ -f "${final}" ]] || { mv -f -- "${tmp_tar}" "${final}"; }

  log_success "Image archive created: ${final}"
  generate_checksum_file "${final}"
  printf '%s\n' "${final}"
}

# ==============================================================================
# Bundle (directory) layout
# ==============================================================================

# __bundle_manifest_json <archive_path> <images...>  -> emits JSON to stdout
__bundle_manifest_json() {
  local archive_path="${1:?archive required}"; shift
  local imgs=( "$@" )

  local bundle_version="${BUNDLE_VERSION:-}"
  local bundle_arch="${BUNDLE_ARCHITECTURE:-}"
  local created_date_iso="$(date -u +%FT%TZ)"
  local created_from="${USER:-unknown}@$(hostname 2>/dev/null || echo unknown)"

  cat <<JSON
{
  "schema": ${BUNDLE_SCHEMA_VERSION},
  "created": "${created_date_iso}",
  "created_by": "${created_from}",
  "runtime": "${CONTAINER_RUNTIME}",
  "compression": "${TARBALL_COMPRESSION}",
  "archive": "$(basename -- "${archive_path}")",
  "bundle_version": "${bundle_version}",
  "architecture": "${bundle_arch}",
  "images": [
JSON
  local i
  for (( i=0; i<${#imgs[@]}; i++ )); do
    local sep=,
    (( i == ${#imgs[@]}-1 )) && sep=""
    printf '    "%s"%s\n' "${imgs[$i]}" "${sep}"
  done
  cat <<'JSON'
  ]
}
JSON
}

# Enhanced manifest with image digests and compose checksum
__enhanced_bundle_manifest_json() {
  local bundle_dir="${1:?bundle_dir required}"
  local compose_file="${2:-${bundle_dir}/docker-compose.yml}"
  shift 2
  local imgs=( "$@" )

  local bundle_version="${BUNDLE_VERSION:-}"
  local bundle_arch="${BUNDLE_ARCHITECTURE:-}"
  local created_date_iso="$(date -u +%FT%TZ)"
  local created_from="${USER:-unknown}@$(hostname 2>/dev/null || echo unknown)"

  # Get compose version and checksum
  local compose_version="3.8"
  local compose_checksum=""
  if [[ -f "$compose_file" ]]; then
    compose_version="$(grep -E '^version:' "$compose_file" | head -1 | sed 's/version:\s*//' | tr -d '"' || echo "3.8")"
    compose_checksum="$(sha256sum "$compose_file" | awk '{print $1}')"
  fi

  cat <<JSON
{
  "schema": "air-gapped-bundle-v2",
  "created": "${created_date_iso}",
  "created_by": "${created_from}",
  "runtime": "${CONTAINER_RUNTIME}",
  "compression": "${TARBALL_COMPRESSION}",
  "compose_version": "${compose_version}",
  "compose_checksum": "${compose_checksum}",
  "images": [
JSON
  local i
  for (( i=0; i<${#imgs[@]}; i++ )); do
    local sep=,
    (( i == ${#imgs[@]}-1 )) && sep=""
    local image="${imgs[$i]}"
    local digest=""
    if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
      digest="$(docker inspect "$image" --format='{{index .RepoDigests 0}}' 2>/dev/null || echo "")"
    elif [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
      digest="$(podman inspect "$image" --format='{{index .RepoDigests 0}}' 2>/dev/null || echo "")"
    fi
    printf '    {"name": "%s", "digest": "%s"}%s\n' "${image}" "${digest:-unknown}" "${sep}"
  done
  cat <<'JSON'
  ],
  "files": {
JSON

  # Add checksums for all files in bundle
  local first_file=1
  for file in "${bundle_dir}"/*; do
    if [[ -f "$file" ]]; then
      local filename
      filename="$(basename -- "$file")"
      if [[ "$filename" != "bundle-manifest.json" ]]; then
        if (( first_file == 0 )); then
          echo "," >> /dev/stdout
        fi
        local checksum
        checksum="$(sha256sum "$file" | awk '{print $1}')"
        printf '    "%s": "%s"\n' "${filename}" "${checksum}"
        first_file=0
      fi
    fi
  done

  cat <<'JSON'
  }
}
JSON
}

# create_enhanced_airgapped_bundle <bundle_dir> <compose_file> <img...>
# Creates enhanced bundle with comprehensive manifest
create_enhanced_airgapped_bundle() {
  __ensure_runtime
  local bundle="${1:?bundle_dir required}"
  local compose_file="${2:?compose_file required}"
  shift 2
  local imgs=( "$@" )
  (( ${#imgs[@]} > 0 )) || die "${E_INVALID_INPUT:-2}" "create_enhanced_airgapped_bundle: no images"

  mkdir -p -- "${bundle}"
  chmod 755 "${bundle}" 2>/dev/null || true

  # Pull everything first
  pull_images "${imgs[@]}"

  # Save to tarball inside bundle
  local base="${bundle}/images.tar"
  local archive_path
  archive_path="$(save_images_archive "${base}" "${imgs[@]}")"

  # Copy compose file to bundle
  if [[ -f "$compose_file" ]]; then
    cp "$compose_file" "${bundle}/docker-compose.yml"
    chmod 644 "${bundle}/docker-compose.yml"
  fi

  # Write enhanced manifest (atomic)
  __enhanced_bundle_manifest_json "${bundle}" "${compose_file}" "${imgs[@]}" | atomic_write "${bundle}/bundle-manifest.json" "644"

  # Snapshot versions.env securely if available
  if [[ -f "./versions.env" ]]; then
    write_secret_file "${bundle}/versions.env" "$(cat ./versions.env)" "versions.env"
  fi

  # Enhanced README with verification instructions
  cat <<EOF | atomic_write "${bundle}/README" "644"
Air-gapped Bundle (Enhanced)
----------------------------
Created: $(date -u +%FT%TZ)
Runtime: ${CONTAINER_RUNTIME}
Compression: ${TARBALL_COMPRESSION}
Compose Version: ${compose_version:-3.8}

Files:
  - $(basename -- "${archive_path}")
  - $(basename -- "${archive_path}").sha256
  - bundle-manifest.json (enhanced manifest)
  - docker-compose.yml
  - versions.env (if present)

Pre-deployment Verification:
  1) Verify bundle integrity:
       ./bundle-hardening.sh /path/to/bundle

  2) Verify tarballs:
       cd /path/to/bundle && sha256sum -c *.sha256

Load on target:
  1) Verify checksum:
       sha256sum $(basename -- "${archive_path}") | awk '{print \$1}' && cat $(basename -- "${archive_path}").sha256
  2) Load into runtime:
       docker load -i $(basename -- "${archive_path}")        # or
       podman load -i $(basename -- "${archive_path}")
  3) Start services:
       docker compose -f docker-compose.yml up -d
EOF

  # Run security audit
  audit_security_configuration "${bundle}/security-audit.txt"

  log_success "Enhanced air-gapped bundle created at: ${bundle}"
}

# create_airgapped_bundle <bundle_dir> <img...>
# Creates:
#   bundle_dir/
#     images.tar[.gz|.zst]
#     images.tar[.gz|.zst].sha256
#     manifest.json
#     versions.env (if present in current dir)
#     README
create_airgapped_bundle() {
  __ensure_runtime
  local bundle="${1:?bundle_dir required}"; shift
  local imgs=( "$@" )
  (( ${#imgs[@]} > 0 )) || die "${E_INVALID_INPUT:-2}" "create_airgapped_bundle: no images"

  mkdir -p -- "${bundle}"
  chmod 755 "${bundle}" 2>/dev/null || true

  # Pull everything first
  pull_images "${imgs[@]}"

  # Save to tarball inside bundle
  local base="${bundle}/images.tar"
  local archive_path
  archive_path="$(save_images_archive "${base}" "${imgs[@]}")"

  # Write manifest (atomic)
  __bundle_manifest_json "${archive_path}" "${imgs[@]}" | atomic_write "${bundle}/manifest.json" "644"

  # Snapshot versions.env securely if available
  if [[ -f "./versions.env" ]]; then
    write_secret_file "${bundle}/versions.env" "$(cat ./versions.env)" "versions.env"
  fi

  # README
  cat <<EOF | atomic_write "${bundle}/README" "644"
Air-gapped bundle
-----------------
Created: $(date -u +%FT%TZ)
Runtime: ${CONTAINER_RUNTIME}
Compression: ${TARBALL_COMPRESSION}

Files:
  - $(basename -- "${archive_path}")
  - $(basename -- "${archive_path}").sha256
  - manifest.json
  - versions.env (if present)

Load on target:
  1) Verify checksum:
       sha256sum $(basename -- "${archive_path}") | awk '{print \$1}' && cat $(basename -- "${archive_path}").sha256
  2) Load into runtime:
       docker load -i $(basename -- "${archive_path}")        # or
       podman load -i $(basename -- "${archive_path}")
EOF

  # Run security audit
  audit_security_configuration "${bundle}/security-audit.txt"

  log_success "Bundle created at: ${bundle}"
}

# ==============================================================================
# Loading / Verifying
# ==============================================================================

# load_image_archive <archive_path>
# Accepts raw .tar or compressed .tar.gz/.tar.zst (docker/podman accept compressed -i).
load_image_archive() {
  __ensure_runtime
  local in="${1:?archive path required}"
  [[ -f "${in}" ]] || die "${E_INVALID_INPUT:-2}" "Archive not found: ${in}"

  # Verify checksum if present
  if [[ -f "${in}.sha256" ]]; then
    log_info "Verifying archive checksum..."
    verify_checksum_file "${in}" || die "${E_GENERAL:-1}" "Checksum verification failed for ${in}"
    log_success "Checksum OK."
  else
    log_warn "No checksum file found for ${in}; proceeding without verification."
  fi

  log_info "Loading images into ${CONTAINER_RUNTIME} from: ${in}"
  "${CONTAINER_RUNTIME}" load -i "${in}"

  log_success "Images loaded."

  if (( VERIFY_AFTER_LOAD == 1 )); then
    log_info "Listing images after load:"
    "${CONTAINER_RUNTIME}" images || true
  fi
}

# load_airgapped_bundle <bundle_dir>
load_airgapped_bundle() {
  __ensure_runtime
  local bundle="${1:?bundle_dir required}"
  [[ -d "${bundle}" ]] || die "${E_INVALID_INPUT:-2}" "Not a directory: ${bundle}"

  local manifest="${bundle}/manifest.json"
  local archive=""
  if [[ -f "${manifest}" ]]; then
    archive="$(awk -F\" '/"archive":/ {print $4}' "${manifest}")"
  fi
  if [[ -z "${archive}" ]]; then
    archive="$(ls -1 "${bundle}"/images.tar* 2>/dev/null | head -n1)"
    [[ -n "${archive}" ]] || die "${E_INVALID_INPUT:-2}" "No images archive found in ${bundle}"
  else
    archive="${bundle}/${archive}"
  fi

  load_image_archive "${archive}"
}

# verify_images_present <img...> -> 0 if all present, 1 otherwise
verify_images_present() {
  __ensure_runtime
  local imgs=( "$@" )
  (( ${#imgs[@]} > 0 )) || die "${E_INVALID_INPUT:-2}" "verify_images_present: no images"
  local missing=0 img
  for img in "${imgs[@]}"; do
    if ! "${CONTAINER_RUNTIME}" image inspect "${img}" >/dev/null 2>&1; then
      log_error "Missing image: ${img}"
      ((missing++))
    else
      log_debug "Image present: ${img}"
    fi
  done
  if (( missing > 0 )); then
    log_error "${missing} image(s) missing."
    return 1
  fi
  log_success "All ${#imgs[@]} image(s) present."
  return 0
}

# verify_bundle <bundle_dir> -> verifies checksum & presence after load (if images listed)
verify_bundle() {
  local bundle="${1:?bundle_dir required}"
  [[ -d "${bundle}" ]] || die "${E_INVALID_INPUT:-2}" "Not a directory: ${bundle}"

  local manifest="${bundle}/manifest.json"
  [[ -f "${manifest}" ]] || die "${E_INVALID_INPUT:-2}" "Manifest not found: ${manifest}"

  local archive
  archive="$(awk -F\" '/"archive":/ {print $4}' "${manifest}")"
  [[ -n "${archive}" ]] || die "${E_INVALID_INPUT:-2}" "Archive not specified in manifest."
  archive="${bundle}/${archive}"

  log_info "Verifying bundle archive checksum..."
  verify_checksum_file "${archive}" || return 1

  # Collect images from manifest and verify they are present
  mapfile -t imgs < <(awk -F\" '/^\s*"images": \[|^\s*\]/{p=!p} p && /"/{print $2}' "${manifest}")
  if (( ${#imgs[@]} > 0 )); then
    log_info "Verifying ${#imgs[@]} image(s) are present in the local runtime..."
    verify_images_present "${imgs[@]}"
  else
    log_warn "No images listed in manifest; skipping presence verification."
  fi
}

# bundle_info <bundle_dir> -> pretty print a short summary
bundle_info() {
  local bundle="${1:?bundle_dir required}"
  local manifest="${bundle}/manifest.json"
  [[ -f "${manifest}" ]] || die "${E_INVALID_INPUT:-2}" "Manifest not found: ${manifest}"
  log_info "Bundle manifest summary:"
  awk '
    /"schema":|\"created\":|\"runtime\":|\"compression\":|\"archive":|\"bundle_version":|\"architecture":/ {
      gsub(/^[ \t]+|[ \t,]+$/,"",$0); print "  " $0
    }' "${manifest}" || true
  local archive
  archive="$(awk -F\" '/"archive":/ {print $4}' "${manifest}")"
  [[ -n "${archive}" ]] && ls -lh "${bundle}/${archive}" 2>/dev/null || true
}

# list_bundle_images <bundle_dir>
list_bundle_images() {
  local bundle="${1:?bundle_dir required}"
  local manifest="${bundle}/manifest.json"
  [[ -f "${manifest}" ]] || die "${E_INVALID_INPUT:-2}" "Manifest not found: ${manifest}"
  awk -F\" '/^\s*"images": \[|^\s*\]/{p=!p} p && /"/{print $2}' "${manifest}"
}

# ==============================================================================
# versions.env integration (optional but handy)
# ==============================================================================

# collect_images_from_versions_file [versions_file]
# Prints one image ref per line, deduplicated, from *_IMAGE variables.
collect_images_from_versions_file() {
  local versions_file="${1:-versions.env}"

  [[ -f "${versions_file}" ]] || die "${E_INVALID_INPUT:-2}" "Versions file not found: ${versions_file}"

  # Prefer official loader/validator if available
  if command -v load_versions_file >/dev/null 2>&1; then
    if [[ "${VERSIONS_VERSION:-0.0.0}" < "1.0.0" ]]; then
      die "${E_GENERAL}" "collect_images_from_versions_file requires versions.sh version >= 1.0.0"
    fi
    load_versions_file "${versions_file}"
  else
    # Validate in a subshell first (syntax only)
    if ! ( set -e; . "${versions_file}" ) >/dev/null 2>&1; then
      die "${E_INVALID_INPUT:-2}" "Invalid syntax in versions file: ${versions_file}"
    fi
    # Source for real
    . "${versions_file}"
  fi

  # Gather *_IMAGE variables from current env
  local imgs=()
  while IFS='=' read -r k v; do
    if [[ "${k}" == *_IMAGE ]]; then
      imgs+=( "${!k}" )
    fi
  done < <(env | LC_ALL=C sort)

  # Deduplicate while preserving order
  local -A seen=()
  local out=()
  local i
  for i in "${imgs[@]}"; do
    [[ -n "${i}" ]] || continue
    if [[ -z "${seen[${i}]:-}" ]]; then
      seen["${i}"]=1
      out+=( "${i}" )
    fi
  done

  printf '%s\n' "${out[@]}"
}

# create_bundle_from_versions <bundle_dir> [versions_file]
create_bundle_from_versions() {
  local bundle="${1:?bundle_dir required}"
  local versions_file="${2:-versions.env}"

  mapfile -t imgs < <(collect_images_from_versions_file "${versions_file}")
  (( ${#imgs[@]} > 0 )) || die "${E_INVALID_INPUT:-2}" "No *_IMAGE entries found in ${versions_file}"

  log_info "Creating air-gapped bundle from ${versions_file} (${#imgs[@]} image(s))..."
  create_airgapped_bundle "${bundle}" "${imgs[@]}"
}

# ==============================================================================
# Legacy single-file helpers (compat with your original signatures)
# ==============================================================================

# create_image_archive <output_tar> <img...>
# (kept for compatibility; no manifest/versions.env, just a tar(+checksum))
create_image_archive() {
  __ensure_runtime
  local out="${1:?output tar required}"; shift
  pull_images "$@"
  save_images_archive "${out}" "$@" >/dev/null
}

# ==============================================================================
# Export key functions (for subshells)
# ==============================================================================
export -f generate_checksum_file verify_checksum_file \
          pull_images save_images_archive create_airgapped_bundle \
          load_image_archive load_airgapped_bundle verify_images_present \
          verify_bundle bundle_info list_bundle_images \
          collect_images_from_versions_file create_bundle_from_versions \
          create_image_archive create_enhanced_airgapped_bundle

# Define version
