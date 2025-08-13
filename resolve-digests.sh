#!/usr/bin/env bash
# resolve-digests.sh — pin tags in versions.env to immutable digests

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/error-handling.sh"
source "${SCRIPT_DIR}/lib/runtime-detection.sh"

readonly VERSIONS_FILE="versions.env"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Resolves tags in ${VERSIONS_FILE} to SHA256 digests and updates:
  • <PREFIX>_IMAGE_DIGEST
  • <PREFIX>_IMAGE  (to "<REPO>@<DIGEST>")
Creates backups: ${VERSIONS_FILE}.bak (full) and sed sidecars as needed.
EOF
}

# Portable in-place sed
_sed_inplace() {
  # _sed_inplace <pattern> <replacement> <file>
  # expects a full sed script in arg1; uses .sibak temp
  local script="$1" file="$2"
  if sed --version >/dev/null 2>&1; then
    # GNU sed
    sed -i.sibak -e "${script}" "${file}"
  else
    # BSD sed
    sed -i .sibak -e "${script}" "${file}"
  fi
}

# Resolve digest for a given <repo>:<tag> and ensure it matches that repo.
_get_digest_for_image() {
  local image_tag="$1" repo="${image_tag%%:*}"

  log_info "  -> Pulling ${image_tag} (to read manifest/digest)…"
  if ! "${CONTAINER_RUNTIME}" pull "${image_tag}" &>/dev/null; then
    log_error "     pull failed for ${image_tag}"
    return 1
  fi

  # Collect all RepoDigests, pick the one whose repo matches (exactly or with default registry)
  local digests match
  if ! digests="$("${CONTAINER_RUNTIME}" image inspect "${image_tag}" \
      --format '{{join .RepoDigests "\n"}}' 2>/dev/null)"; then
    log_error "     inspect failed for ${image_tag}"
    return 1
  fi

  # Try exact repo match first, then fallback to first digest.
  match="$(printf '%s\n' "${digests}" | grep -E "^${repo}@" || true)"
  if [[ -z "${match}" ]]; then
    # Docker may normalize to docker.io/library/<name>
    if [[ "${repo}" != */* ]]; then
      match="$(printf '%s\n' "${digests}" | grep -E "^(docker\.io/)?library/${repo}@" || true)"
    fi
  fi
  match="${match:-$(printf '%s\n' "${digests}" | head -n1)}"

  local digest="${match##*@}"
  if [[ -z "${digest}" ]]; then
    log_error "     could not determine digest for ${image_tag}"
    return 1
  fi
  printf '%s\n' "${digest}"
}

main() {
  if [[ $# -gt 0 ]]; then usage; exit 0; fi
  [[ -f "${VERSIONS_FILE}" ]] || die "${E_MISSING_DEP:-3}" "File not found: ${VERSIONS_FILE}"
  detect_container_runtime

  cp -f "${VERSIONS_FILE}" "${VERSIONS_FILE}.bak"
  log_info "Backup created: ${VERSIONS_FILE}.bak"

  # Load once (we only read), before we start editing the file.
  # shellcheck source=/dev/null
  source "${VERSIONS_FILE}"

  # Collect prefixes robustly (ignore comments/whitespace)
  mapfile -t PREFIXES < <(awk '
    /^[[:space:]]*readonly[[:space:]]+[A-Z_]+_IMAGE_REPO=/{ 
      match($0,/readonly[[:space:]]+([A-Z_]+)_IMAGE_REPO=/,m); 
      if(m[1]!="") print m[1];
    }' "${VERSIONS_FILE}" | sort -u)

  if ((${#PREFIXES[@]}==0)); then
    die "${E_INVALID_INPUT:-2}" "No *_IMAGE_REPO entries found in ${VERSIONS_FILE}"
  fi

  for prefix in "${PREFIXES[@]}"; do
    log_info "Processing: ${prefix}"

    # Indirects from sourced env
    local repo_var="${prefix}_IMAGE_REPO"
    local ver_var="${prefix}_VERSION"
    local dig_var="${prefix}_IMAGE_DIGEST"
    local img_var="${prefix}_IMAGE"

    local repo="${!repo_var-}"
    local ver="${!ver_var-}"

    if [[ -z "${repo:-}" || -z "${ver:-}" ]]; then
      log_warn "  -> Skipping ${prefix}: missing ${repo_var} or ${ver_var}"
      continue
    fi

    local tag="${repo}:${ver}"
    local digest
    if ! digest="$(_get_digest_for_image "${tag}")"; then
      log_warn "  -> Skipping ${prefix}: digest resolution failed for ${tag}"
      continue
    fi
    log_success "  -> ${tag} -> ${digest}"

    # 1) Update/insert DIGEST line
    if grep -qE "^[[:space:]]*readonly[[:space:]]+${dig_var}=" "${VERSIONS_FILE}"; then
      _sed_inplace "s|^[[:space:]]*readonly[[:space:]]\\+${dig_var}=.*|readonly ${dig_var}=\"${digest}\"|" "${VERSIONS_FILE}"
    else
      # append after VERSION line
      _sed_inplace "/^[[:space:]]*readonly[[:space:]]\\+${ver_var}=.*/a\\
readonly ${dig_var}=\"${digest}\"
" "${VERSIONS_FILE}"
    fi

    # 2) Refresh the combined IMAGE line to repo@digest
    local new_image="${repo}@${digest}"
    if grep -qE "^[[:space:]]*readonly[[:space:]]+${img_var}=" "${VERSIONS_FILE}"; then
      _sed_inplace "s|^[[:space:]]*readonly[[:space:]]\\+${img_var}=.*|readonly ${img_var}=\"${new_image}\"|" "${VERSIONS_FILE}"
    else
      # If not present, add it right after DIGEST (or after VERSION if DIGEST also newly added)
      _sed_inplace "/^[[:space:]]*readonly[[:space:]]\\+${dig_var}=.*/a\\
readonly ${img_var}=\"${new_image}\"
" "${VERSIONS_FILE}"
    fi
  done

  # Clean sidecar backups from sed
  rm -f "${VERSIONS_FILE}.sibak" 2>/dev/null || true

  log_success "✅ ${VERSIONS_FILE} updated with resolved digests and IMAGE pins."
  log_info "Review and commit changes."
}

main "$@"
