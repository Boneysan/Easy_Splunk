#!/usr/bin/env bash
# ==============================================================================
# lib/air-gapped.sh
# Air-gapped bundle creation, verification, and loading.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/runtime-detection.sh
# Expects: log_*, die, have_cmd, atomic_write, atomic_write_file, with_retry,
#          detect_container_runtime, compose(), etc.
# ==============================================================================

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1 || ! command -v with_retry >/dev/null 2>&1; then
  echo "FATAL: core.sh and error-handling.sh must be sourced before lib/air-gapped.sh" >&2
  exit 1
fi

# ---- Tunables ------------------------------------------------------------------
: "${PULL_RETRIES:=5}"
: "${PULL_BASE_DELAY:=1}"
: "${PULL_MAX_DELAY:=20}"
: "${TARBALL_COMPRESSION:=gzip}"   # gzip|zstd|none
: "${BUNDLE_SCHEMA_VERSION:=1}"
: "${VERIFY_AFTER_LOAD:=0}"        # 1 = re-list/inspect images after load

# Ensure runtime variables exist; detect if needed
__ensure_runtime() {
  if [[ -z "${CONTAINER_RUNTIME:-}" ]]; then
    if ! command -v detect_container_runtime >/dev/null 2>&1; then
      echo "FATAL: lib/runtime-detection.sh must be sourced before lib/air-gapped.sh" >&2
      exit 1
    fi
    detect_container_runtime
  fi
}

# ------------------------------------------------------------------------------
# Checksum helpers
# ------------------------------------------------------------------------------

# __sha256_file <path> -> prints sha256 hex digest
__sha256_file() {
  local file="${1:?file required}"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file}" | awk '{print $1}'
  else
    die "${E_MISSING_DEP}" "Need sha256sum or shasum to compute checksums."
  fi
}

# generate_checksum_file <file>
generate_checksum_file() {
  local file="${1:?file required}"
  [[ -f "${file}" ]] || die "${E_INVALID_INPUT}" "Cannot generate checksum; file not found: ${file}"
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

# ------------------------------------------------------------------------------
# Image pulling & saving
# ------------------------------------------------------------------------------

# pull_images <img...>
pull_images() {
  __ensure_runtime
  local imgs=( "$@" )
  (( ${#imgs[@]} > 0 )) || die "${E_INVALID_INPUT}" "pull_images: no images"
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
  (( ${#imgs[@]} > 0 )) || die "${E_INVALID_INPUT}" "save_images_archive: no images"

  local out_dir; out_dir="$(dirname -- "${out}")"
  mkdir -p -- "${out_dir}"

  local tmp_tar
  tmp_tar="$(mktemp "${out}.tmp.XXXXXX")"
  register_cleanup "rm -f '${tmp_tar}'"

  log_info "Saving ${#imgs[@]} image(s) to archive..."
  # Both docker and podman support multiple images in one save
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
      have_cmd zstd || die "${E_MISSING_DEP}" "zstd not found; install or set TARBALL_COMPRESSION=gzip/none."
      log_info "Compressing archive with zstd..."
      zstd -q -f -T0 "${tmp_tar}" -o "${out}.zst"
      rm -f "${tmp_tar}"
      final="${out}.zst"
      ;;
    none)
      final="${out}"
      ;;
    *)
      die "${E_INVALID_INPUT}" "Unknown TARBALL_COMPRESSION='${TARBALL_COMPRESSION}'"
      ;;
  esac

  # If we used compression, tmp_tar may already be removed.
  [[ -f "${final}" ]] || { mv -f -- "${tmp_tar}" "${final}"; }

  log_success "Image archive created: ${final}"
  generate_checksum_file "${final}"
  printf '%s\n' "${final}"
}

# ------------------------------------------------------------------------------
# Bundle (directory) layout
# ------------------------------------------------------------------------------

# create_airgapped_bundle <bundle_dir> <img...>
# Creates:
#   bundle_dir/
#     images.tar[.gz|.zst]
#     images.tar[.gz|.zst].sha256
#     manifest.json
#     versions.env (if present in current tree)
#     README
create_airgapped_bundle() {
  __ensure_runtime
  local bundle="${1:?bundle_dir required}"; shift
  local imgs=( "$@" )
  (( ${#imgs[@]} > 0 )) || die "${E_INVALID_INPUT}" "create_airgapped_bundle: no images"

  mkdir -p -- "${bundle}"
  chmod 755 "${bundle}" 2>/dev/null || true

  # Pull everything first
  pull_images "${imgs[@]}"

  # Save to tarball inside bundle
  local base="${bundle}/images.tar"
  local archive_path
  archive_path="$(save_images_archive "${base}" "${imgs[@]}")"

  # Write manifest
  local manifest="${bundle}/manifest.json"
  {
    echo "{"
    echo "  \"schema\": ${BUNDLE_SCHEMA_VERSION},"
    echo "  \"created\": \"$(date -u +%FT%TZ)\","
    echo "  \"runtime\": \"${CONTAINER_RUNTIME}\","
    echo "  \"compression\": \"${TARBALL_COMPRESSION}\","
    echo "  \"archive\": \"$(basename -- "${archive_path}")\","
    echo "  \"images\": ["
    local i=0
    for img in "${imgs[@]}"; do
      printf '    %s"%s"%s\n' "$([[ $i -gt 0 ]] && echo ,)" "${img}" ""
      ((i++))
    done
    echo "  ]"
    echo "}"
  } | atomic_write "${manifest}" "644"

  # Snapshot versions.env if available
  if [[ -f "./versions.env" ]]; then
    atomic_write_file "./versions.env" "${bundle}/versions.env" "644"
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

  log_success "Bundle created at: ${bundle}"
}

# ------------------------------------------------------------------------------
# Loading
# ------------------------------------------------------------------------------

# load_image_archive <archive_path>
# Accepts raw .tar or compressed .tar.gz/.tar.zst (podman/docker accept compressed stdin).
load_image_archive() {
  __ensure_runtime
  local in="${1:?archive path required}"
  [[ -f "${in}" ]] || die "${E_INVALID_INPUT}" "Archive not found: ${in}"

  # Verify checksum if present
  if [[ -f "${in}.sha256" ]]; then
    log_info "Verifying archive checksum..."
    verify_checksum_file "${in}" || die "${E_GENERAL}" "Checksum verification failed for ${in}"
    log_success "Checksum OK."
  else
    log_warn "No checksum file found for ${in}; proceeding without verification."
  fi

  log_info "Loading images into ${CONTAINER_RUNTIME} from: ${in}"
  if [[ "${in}" == *.gz ]]; then
    gzip -t "${in}" 2>/dev/null || log_warn "gzip test failed; continuing"
    # docker/podman can read gzipped tar directly with -i
    "${CONTAINER_RUNTIME}" load -i "${in}"
  elif [[ "${in}" == *.zst ]]; then
    have_cmd zstd || die "${E_MISSING_DEP}" "zstd is required to handle .zst archives."
    "${CONTAINER_RUNTIME}" load -i "${in}"
  else
    "${CONTAINER_RUNTIME}" load -i "${in}"
  fi

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
  [[ -d "${bundle}" ]] || die "${E_INVALID_INPUT}" "Not a directory: ${bundle}"

  local manifest="${bundle}/manifest.json"
  local archive
  if [[ -f "${manifest}" ]]; then
    archive="$(awk -F\" '/"archive":/ {print $4}' "${manifest}")"
  fi
  if [[ -z "${archive}" ]]; then
    # Fallback: pick the first images.tar* we find
    archive="$(ls -1 "${bundle}"/images.tar* 2>/dev/null | head -n1)"
    [[ -n "${archive}" ]] || die "${E_INVALID_INPUT}" "No images archive found in ${bundle}"
  else
    archive="${bundle}/${archive}"
  fi

  load_image_archive "${archive}"
}

# ------------------------------------------------------------------------------
# Legacy single-file helpers (compat with your original signatures)
# ------------------------------------------------------------------------------

# create_image_archive <output_tar> <img...>
# (kept for compatibility; no manifest/versions.env, just a tar(+checksum))
create_image_archive() {
  __ensure_runtime
  local out="${1:?output tar required}"; shift
  pull_images "$@"
  save_images_archive "${out}" "$@" >/dev/null
}

