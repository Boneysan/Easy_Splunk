#!/usr/bin/env bash
# resolve-digests.sh — pin tags in versions.env to immutable digests
#
# What this does
#  - Reads image repo + version pairs from versions.env (e.g., FOO_IMAGE_REPO + FOO_VERSION)
#  - Pulls <repo>:<version> with the detected container runtime (docker or podman)
#  - Resolves the image’s immutable digest (sha256:…)
#  - Updates/creates:
#       <PREFIX>_IMAGE_DIGEST="sha256:…"
#       <PREFIX>_IMAGE="<repo>@sha256:…"
#  - Creates versions.env.bak and sed sidecar backups
#
# Requirements
#  - lib/core.sh, lib/error-handling.sh, lib/runtime-detection.sh (in ./lib)
#  - Docker or Podman available to pull/inspect images
#
# Notes
#  - Handles registries with ports (e.g., registry:5000/ns/app:tag)
#  - If pull/inspect fails for a particular image, that image is skipped (others still processed)
#  - Idempotent: safe to re-run; it’ll refresh DIGEST/IMAGE lines
#

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# deps
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"
# shellcheck source=lib/runtime-detection.sh
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

# Portable in-place sed (GNU/BSD); takes a full sed script and a file
_sed_inplace() {
  # _sed_inplace "<script>" <file>
  local script="$1" file="$2"
  if sed --version >/dev/null 2>&1; then
    sed -i.sibak -e "${script}" "${file}"
  else
    sed -i .sibak -e "${script}" "${file}"
  fi
}

# Split an image reference "<name>:<tag>" safely, even with registry ports.
# Outputs two lines: <repo>  and  <tag>   (tag may be empty if not present)
_split_repo_tag() {
  local ref="$1"
  # If already pinned with @, treat everything before @ as repo, after @ as digest (tag empty)
  if [[ "$ref" == *"@"* ]]; then
    printf '%s\n' "${ref%%@*}"
    printf '%s\n' ""
    return 0
  fi
  # Determine if the last path segment contains ':' (that would be the tag separator)
  local after_slash="${ref##*/}"
  if [[ "$after_slash" == *":"* ]]; then
    printf '%s\n' "${ref%:*}"   # repo
    printf '%s\n' "${ref##*:}"  # tag
  else
    printf '%s\n' "${ref}"      # repo
    printf '%s\n' ""            # no tag
  fi
}

# Resolve digest for a given "<repo>:<tag>" (or "<repo>@<digest>" -> returns digest immediately)
# Prints "sha256:…" to stdout
_get_digest_for_image() {
  local image_ref="$1"

  # Fast-path: already a digest reference
  if [[ "$image_ref" == *"@"* ]]; then
    printf '%s\n' "${image_ref##*@}"
    return 0
  fi

  # Pull (ensure local manifest present)
  log_info "  -> Pulling ${image_ref} (to read manifest/digest)…"
  if ! "${CONTAINER_RUNTIME}" pull "${image_ref}" &>/dev/null; then
    log_error "     pull failed for ${image_ref}"
    return 1
  fi

  # Inspect RepoDigests (use template that works on docker & podman)
  local digests
  if ! digests="$("${CONTAINER_RUNTIME}" image inspect "${image_ref}" \
        --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null)"; then
    log_error "     inspect failed for ${image_ref}"
    return 1
  fi
  digests="$(printf '%s\n' "$digests" | sed '/^[[:space:]]*$/d')"

  if [[ -z "${digests}" ]]; then
    log_error "     no RepoDigests found for ${image_ref}"
    return 1
  fi

  # Try to pick the digest that matches our repo (normalize common docker.io/library case)
  local repo tag; read -r repo; read -r tag < <(_split_repo_tag "${image_ref}")
  local match
  # exact match
  match="$(printf '%s\n' "${digests}" | grep -E "^${repo}@" || true)"
  if [[ -z "${match}" ]]; then
    # docker.io/library normalization when repo has no slash (e.g., "nginx")
    if [[ "${repo}" != */* ]]; then
      match="$(printf '%s\n' "${digests}" | grep -E "^(docker\.io/)?library/${repo}@" || true)"
    fi
  fi
  # fallback: first digest
  match="${match:-$(printf '%s\n' "${digests}" | head -n1)}"

  local digest="${match##*@}"
  if [[ -z "${digest}" ]]; then
    log_error "     could not determine digest for ${image_ref}"
    return 1
  fi

  printf '%s\n' "${digest}"
}

main() {
  if [[ $# -gt 0 ]]; then usage; exit 0; fi
  [[ -f "${VERSIONS_FILE}" ]] || die "${E_MISSING_DEP:-3}" "File not found: ${VERSIONS_FILE}"

  detect_container_runtime
  log_info "Using container runtime: ${CONTAINER_RUNTIME}"

  # Safeguard backup
  cp -f "${VERSIONS_FILE}" "${VERSIONS_FILE}.bak"
  log_info "Backup created: ${VERSIONS_FILE}.bak"

  # Load for indirect variable expansion
  # shellcheck disable=SC1090
  source "${VERSIONS_FILE}"

  # Collect prefixes from readonly FOO_IMAGE_REPO=…
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

    local ref="${repo}:${ver}"
    local digest
    if ! digest="$(_get_digest_for_image "${ref}")"; then
      log_warn "  -> Skipping ${prefix}: digest resolution failed for ${ref}"
      continue
    fi
    log_success "  -> ${ref} -> ${digest}"

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
      # Add it right after DIGEST (or after VERSION if DIGEST also newly added)
      _sed_inplace "/^[[:space:]]*readonly[[:space:]]\\+${dig_var}=.*/a\\
readonly ${img_var}=\"${new_image}\"
" "${VERSIONS_FILE}"
    fi
  done

  # Clean sed sidecars
  rm -f "${VERSIONS_FILE}.sibak" 2>/dev/null || true

  log_success "✅ ${VERSIONS_FILE} updated with resolved digests and IMAGE pins."
  log_info "Review and commit changes."
}

main "$@"
