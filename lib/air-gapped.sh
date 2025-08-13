```bash
#!/usr/bin/env bash
# ==============================================================================
# lib/air-gapped.sh
# Air-gapped bundle creation, verification, and loading.
#
# Dependencies (required):
#   - lib/core.sh              (log_*, die, have_cmd, register_cleanup)
#   - lib/error-handling.sh    (atomic_write, atomic_write_file, with_retry)
#   - lib/security.sh          (write_secret_file, audit_security_configuration)
#
# Dependencies (detected/optional at runtime):
#   - lib/runtime-detection.sh (detect_container_runtime, compose, capability vars)
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
          create_image_archive

# Define version
AIR_GAPPED_VERSION="1.0.0"
```