#!/usr/bin/env bash
# ==============================================================================
# lib/security.sh
# Security utilities: strong secrets, safe secret files, curl auth wrapper,
# and self-signed TLS certificates (SANs, renewal, Ed25519→RSA fallback).
#
# Dependencies: lib/core.sh (log_*, die, umask_strict, have_cmd, register_cleanup)
#               lib/error-handling.sh (atomic_write, atomic_write_file)
# ==============================================================================

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1 || ! command -v atomic_write >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh and lib/error-handling.sh must be sourced before lib/security.sh" >&2
  exit 1
fi

# ---- Defaults / Tunables -------------------------------------------------------
: "${CERT_DEFAULT_DAYS:=3650}"          # ~10 years for internal certs
: "${CERT_REISSUE_BEFORE_DAYS:=30}"     # reissue if expiring within N days
: "${CERT_DEFAULT_ALG:=ed25519}"        # ed25519 preferred; fallback to rsa
: "${CURL_SECRET_PATH:=/run/secrets/curl_auth}"  # curl -K config file
: "${NETRC_PATH:=${HOME}/.netrc}"       # user-level fallback
: "${TLS_DIR:=secrets/tls}"              # default TLS dir (caller can override)

umask_strict

# ==============================================================================
# Secret generation / persistence
# ==============================================================================

# generate_random_password [length]
# Outputs a URL-safe, high-entropy password.
generate_random_password() {
  local length="${1:-32}"
  if have_cmd openssl; then
    # Over-generate then filter to target alphabet and cut to length.
    openssl rand -base64 $((length * 2)) 2>/dev/null \
      | tr -dc 'A-Za-z0-9_@#%+=:,.!-?' \
      | head -c "${length}"
  else
    tr -dc 'A-Za-z0-9_@#%+=:,.!-?' < /dev/urandom | head -c "${length}"
  fi
  echo
}

# write_secret_file <path> <content>
# Writes content atomically with 0600 perms.
write_secret_file() {
  local path="${1:?secret path required}"
  local content="${2-}"
  local dir; dir="$(dirname -- "${path}")"
  mkdir -p -- "${dir}"
  umask 077
  printf '%s' "${content}" | atomic_write "${path}" "600"
  log_debug "Secret written: ${path} (0600)"
}

# harden_file_permissions <path> [mode]
# Sets secure perms on an existing file; default 600.
harden_file_permissions() {
  local file="${1:?file required}" mode="${2:-600}"
  if [[ ! -f "${file}" ]]; then
    log_warn "Cannot set permissions; file not found: ${file}"
    return 1
  fi
  chmod "${mode}" "${file}"
  log_debug "Set permissions: ${file} -> ${mode}"
}

# ensure_dir_secure <dir> [mode]
# Ensures directory exists with restrictive perms.
ensure_dir_secure() {
  local dir="${1:?dir required}" mode="${2:-700}"
  mkdir -p -- "${dir}"
  chmod "${mode}" "${dir}" 2>/dev/null || true
}

# ==============================================================================
# Curl auth helpers (no plaintext in ps)
# ==============================================================================

# make_curl_config <username> <password> [verify]
# Creates a curl config snippet (not a netrc) suitable for -K usage.
# If verify=="insecure", adds "insecure" to permit self-signed TLS.
make_curl_config() {
  local user="${1:?user required}" pass="${2:?pass required}" verify="${3:-}"
  cat <<EOF
user = "${user}:${pass}"
max-time = 30
show-error
silent
${verify:+insecure}
EOF
}

# create_netrc <machine> <login> <password> [path]
# Writes a minimal ~/.netrc (or provided path) with strict perms.
create_netrc() {
  local machine="${1:?machine required}" login="${2:?login required}" pass="${3:?password required}"
  local path="${4:-${NETRC_PATH}}"
  umask 077
  cat > "${path}.tmp.$$" <<EOF
machine ${machine}
  login ${login}
  password ${pass}
EOF
  atomic_write_file "${path}.tmp.$$" "${path}" "600"
  log_debug "Netrc written: ${path} (0600)"
}

# curl_auth <url> [curl args...]
# Uses -K ${CURL_SECRET_PATH} if present; else --netrc-file ${NETRC_PATH}.
# Never passes credentials on the command line.
curl_auth() {
  local url="${1:?url required}"; shift || true
  if [[ -f "${CURL_SECRET_PATH}" ]]; then
    curl -sS -K "${CURL_SECRET_PATH}" "${url}" "$@"
    return $?
  elif [[ -f "${NETRC_PATH}" ]]; then
    curl -sS --netrc-file "${NETRC_PATH}" "${url}" "$@"
    return $?
  else
    log_error "No curl auth secret configured. Expected ${CURL_SECRET_PATH} or ${NETRC_PATH}."
    return "${E_INVALID_INPUT}"
  fi
}

# ==============================================================================
# TLS certificate management
# ==============================================================================

# _openssl_supports_ed25519 — returns 0 if OpenSSL can gen ed25519 keys.
_openssl_supports_ed25519() {
  have_cmd openssl || return 1
  openssl help 2>&1 | grep -qi 'ed25519' || \
  openssl list -public-key-algorithms 2>/dev/null | grep -qi 'ed25519'
}

# cert_expires_within <cert_file> <days>
# Returns 0 if cert expires within N days (or file missing/unreadable).
cert_expires_within() {
  local cert="${1:?cert required}" days="${2:?days required}"
  [[ -r "${cert}" ]] || return 0
  local end epoch_now epoch_end
  end="$(openssl x509 -enddate -noout -in "${cert}" 2>/dev/null | sed 's/notAfter=//')" || return 0
  epoch_now="$(date +%s)"
  epoch_end="$(date -d "${end}" +%s 2>/dev/null || true)"
  if [[ -z "${epoch_end}" ]]; then
    # macOS BSD date fallback
    epoch_end="$(date -j -f "%b %d %T %Y %Z" "${end}" +%s 2>/dev/null || echo 0)"
  fi
  [[ "${epoch_end}" -eq 0 ]] && return 0
  local diff_days=$(( (epoch_end - epoch_now) / 86400 ))
  (( diff_days <= days ))
}

# generate_self_signed_cert <cn> <key_file> <cert_file> [san_csv] [days] [alg]
# Idempotent: skips if valid and not near expiry; otherwise (re)issues.
# SAN list defaults to: CN,localhost,127.0.0.1,::1
generate_self_signed_cert() {
  local cn="${1:?common name required}"
  local key="${2:?key file required}"
  local crt="${3:?cert file required}"
  local san_csv="${4:-}"
  local days="${5:-${CERT_DEFAULT_DAYS}}"
  local alg="${6:-${CERT_DEFAULT_ALG}}"

  ensure_dir_secure "$(dirname -- "${key}")"
  ensure_dir_secure "$(dirname -- "${crt}")"

  # Default SANs
  if [[ -z "${san_csv}" ]]; then
    san_csv="${cn},localhost,127.0.0.1,::1"
  fi

  # Skip if fresh enough
  if [[ -f "${key}" && -f "${crt}" ]] && ! cert_expires_within "${crt}" "${CERT_REISSUE_BEFORE_DAYS}"; then
    log_info "TLS key/cert exist and are not near expiry. Skipping generation."
    return 0
  fi

  have_cmd openssl || die "${E_MISSING_DEP}" "OpenSSL is required to generate certificates."

  log_info "Generating self-signed TLS cert for CN='${cn}' (SANs: ${san_csv}; ${days} days; alg=${alg})"

  # Build a minimal OpenSSL config with SANs
  local cfg tmp_key tmp_crt
  cfg="$(mktemp "${TLS_DIR}/openssl-XXXXXX.cnf")"
  register_cleanup "rm -f '${cfg}'"
  ensure_dir_secure "${TLS_DIR}"

  # Build SAN entries
  local IFS=','; local -a sans=(${san_csv}); IFS=$' \t\n'
  {
    echo "[req]"
    echo "distinguished_name = dn"
    echo "x509_extensions = v3_req"
    echo "prompt = no"
    echo "[dn]"
    echo "CN = ${cn}"
    echo "[v3_req]"
    echo "subjectAltName = @alt_names"
    echo "[alt_names]"
    local i=1
    for s in "${sans[@]}"; do
      if [[ "${s}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "IP.${i} = ${s}"
      elif [[ "${s}" == "::1" || "${s}" =~ : ]]; then
        echo "IP.${i} = ${s}"
      else
        echo "DNS.${i} = ${s}"
      fi
      ((i++))
    done
  } > "${cfg}"

  tmp_key="$(mktemp "${key}.tmp.XXXXXX")"; register_cleanup "rm -f '${tmp_key}'"
  tmp_crt="$(mktemp "${crt}.tmp.XXXXXX")"; register_cleanup "rm -f '${tmp_crt}'"

  # Key + cert generation with preferred algorithm
  if [[ "${alg}" == "ed25519" ]] && _openssl_supports_ed25519; then
    # Single shot: newkey ed25519
    openssl req -x509 -new -newkey ed25519 -nodes \
      -keyout "${tmp_key}" -out "${tmp_crt}" \
      -days "${days}" -config "${cfg}" >/dev/null 2>&1 || {
        log_warn "Ed25519 generation failed; falling back to RSA 4096."
        alg="rsa"
      }
  fi

  if [[ "${alg}" == "rsa" ]]; then
    # Generate RSA key, then self-sign
    openssl genrsa -out "${tmp_key}" 4096 >/dev/null 2>&1
    openssl req -x509 -new -key "${tmp_key}" \
      -out "${tmp_crt}" -days "${days}" -config "${cfg}" >/dev/null 2>&1
  fi

  # Secure perms and move into place atomically
  chmod 600 "${tmp_key}" 2>/dev/null || true
  chmod 644 "${tmp_crt}" 2>/dev/null || true
  atomic_write_file "${tmp_key}" "${key}" "600"
  atomic_write_file "${tmp_crt}" "${crt}" "644"

  log_success "TLS certificate and key generated: ${crt} , ${key}"
}

# ==============================================================================
# End of lib/security.sh
# ==============================================================================

# Export key functions if callers exec in subshells
export -f generate_random_password write_secret_file harden_file_permissions \
          ensure_dir_secure make_curl_config create_netrc curl_auth \
          cert_expires_within generate_self_signed_cert
