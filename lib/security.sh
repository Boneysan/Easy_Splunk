#!/usr/bin/env bash
# ==============================================================================
# lib/security.sh
# Security utilities: strong secrets, safe secret files, curl auth wrapper,
# TLS certificates, and Splunk-specific security configurations.
#
# Dependencies: lib/core.sh (log_*, die, have_cmd, register_cleanup, umask_strict, is_true)
#               lib/error-handling.sh (atomic_write, atomic_write_file)
#
# Notes:
# - Provides safe fallbacks for is_true and error codes if core didn’t define them.
# - Never logs secret values. Paths and filenames only.
# ==============================================================================

# ---- Dependency guard ----------------------------------------------------------
if ! command -v atomic_write >/dev/null 2>&1 || ! command -v log_info >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh and lib/error-handling.sh must be sourced before lib/security.sh" >&2
  exit 1
fi

# ---- Fallbacks / Error codes ---------------------------------------------------
# Minimal is_true fallback if core didn’t define it
if ! command -v is_true >/dev/null 2>&1; then
  is_true() {
    case "${1:-}" in
      1|true|TRUE|yes|y|on|On|ON) return 0 ;;
      *) return 1 ;;
    esac
  }
fi

# Error code defaults if not provided by core
: "${E_GENERAL:=1}"
: "${E_INVALID_INPUT:=2}"
: "${E_MISSING_DEP:=3}"

# ---- Defaults / Tunables -------------------------------------------------------
: "${CERT_DEFAULT_DAYS:=3650}"            # ~10 years for internal certs
: "${CERT_REISSUE_BEFORE_DAYS:=30}"       # reissue if expiring within N days
: "${CERT_DEFAULT_ALG:=ed25519}"          # ed25519 preferred; fallback to rsa
: "${CURL_SECRET_PATH:=/run/secrets/curl_auth}"  # curl -K config file
: "${NETRC_PATH:=${HOME}/.netrc}"         # user-level fallback
: "${TLS_DIR:=secrets/tls}"                # default TLS dir (caller can override)
: "${SPLUNK_SECRETS_DIR:=secrets/splunk}" # Splunk-specific secrets
: "${MIN_PASSWORD_LENGTH:=12}"            # Minimum password length
: "${ENABLE_PASSWORD_COMPLEXITY:=true}"   # Enforce password complexity

# Default to strict umask for all file writes; prefer core’s helper if present
if command -v umask_strict >/dev/null 2>&1; then
  umask_strict
else
  umask 077
fi

# ==============================================================================
# Enhanced Secret generation / persistence
# ==============================================================================

# generate_random_password [length] [complexity]
# Outputs a URL-safe, high-entropy password with optional complexity requirements.
generate_random_password() {
  local length="${1:-32}"
  local complexity="${2:-${ENABLE_PASSWORD_COMPLEXITY}}"

  if [[ "${length}" -lt "${MIN_PASSWORD_LENGTH}" ]]; then
    log_warn "Password length ${length} is below minimum ${MIN_PASSWORD_LENGTH}; using minimum"
    length="${MIN_PASSWORD_LENGTH}"
  fi

  local password
  if have_cmd openssl; then
    if is_true "${complexity}"; then
      # Guaranteed classes
      local L="abcdefghijklmnopqrstuvwxyz"
      local U="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
      local D="0123456789"
      local S='@#%+=:,.!-?'
      local ALL="${L}${U}${D}${S}"

      password=""
      password+="${L:$((RANDOM % ${#L})):1}"
      password+="${U:$((RANDOM % ${#U})):1}"
      password+="${D:$((RANDOM % ${#D})):1}"
      password+="${S:$((RANDOM % ${#S})):1}"

      while [[ ${#password} -lt ${length} ]]; do
        password+="${ALL:$((RANDOM % ${#ALL})):1}"
      done

      # Shuffle using openssl for better randomness if available
      password="$(printf '%s' "${password}" | fold -w1 | shuf | tr -d '\n')"
    else
      password="$(openssl rand -base64 $((length * 2)) 2>/dev/null \
        | tr -dc 'A-Za-z0-9_@#%+=:,.!-?' \
        | head -c "${length}")"
    fi
  else
    password="$(tr -dc 'A-Za-z0-9_@#%+=:,.!-?' < /dev/urandom | head -c "${length}")"
  fi

  printf '%s\n' "${password}"
}

# validate_password_strength <password>
# Returns 0 if password meets strength requirements
validate_password_strength() {
  local password="${1:-}"
  local length=${#password}

  if [[ "${length}" -lt "${MIN_PASSWORD_LENGTH}" ]]; then
    log_error "Password too short: ${length} < ${MIN_PASSWORD_LENGTH}"
    return 1
  fi

  if is_true "${ENABLE_PASSWORD_COMPLEXITY}"; then
    local has_lower=0 has_upper=0 has_digit=0 has_special=0
    [[ "${password}" =~ [a-z] ]] && has_lower=1
    [[ "${password}" =~ [A-Z] ]] && has_upper=1
    [[ "${password}" =~ [0-9] ]] && has_digit=1
    [[ "${password}" =~ [@#%+=:,.!\?-] ]] && has_special=1
    local score=$((has_lower + has_upper + has_digit + has_special))
    if [[ "${score}" -lt 3 ]]; then
      log_error "Password lacks complexity: must contain at least 3 of {lower,upper,digit,special}"
      return 1
    fi
  fi

  log_debug "Password validation passed"
  return 0
}

# write_secret_file <path> <content> [description]
# Writes content atomically with 0600 perms and optional audit logging.
write_secret_file() {
  local path="${1:?secret path required}"
  local content="${2-}"
  local description="${3:-secret}"
  local dir
  dir="$(dirname -- "${path}")"

  mkdir -p -- "${dir}"
  umask 077
  printf '%s' "${content}" | atomic_write "${path}" "600"
  log_info "Secure ${description} written: $(basename "${path}") (0600)"
  log_debug "Secret file location: ${path}"
}

# generate_splunk_secret [length]
# Generates a Splunk-compatible secret key (alphanumeric only).
generate_splunk_secret() {
  local length="${1:-64}"
  if have_cmd openssl; then
    openssl rand -base64 $((length * 2)) 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "${length}"
  else
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${length}"
  fi
  echo
}

# harden_file_permissions <path> [mode] [description]
# Sets secure perms on an existing file with audit logging.
harden_file_permissions() {
  local file="${1:?file required}"
  local mode="${2:-600}"
  local description="${3:-file}"

  if [[ ! -f "${file}" ]]; then
    log_warn "Cannot set permissions; ${description} not found: ${file}"
    return 1
  fi

  chmod "${mode}" "${file}"
  log_info "Secured ${description}: $(basename "${file}") -> ${mode}"
}

# ensure_dir_secure <dir> [mode] [description]
# Ensures directory exists with restrictive perms and audit logging.
ensure_dir_secure() {
  local dir="${1:?dir required}"
  local mode="${2:-700}"
  local description="${3:-directory}"

  if [[ ! -d "${dir}" ]]; then
    mkdir -p -- "${dir}"
    log_debug "Created secure ${description}: ${dir}"
  fi
  chmod "${mode}" "${dir}" 2>/dev/null || true
  log_debug "Secured ${description}: ${dir} -> ${mode}"
}

# rotate_secret_file <path> [backup_count]
# Rotates secret files with backup retention (path.N where N=1..backup_count)
rotate_secret_file() {
  local path="${1:?path required}"
  local backup_count="${2:-3}"

  [[ "${backup_count}" -gt 0 ]] || { log_warn "backup_count must be > 0"; return 1; }
  [[ -f "${path}" ]] || { log_debug "No existing secret to rotate: ${path}"; return 0; }

  # Remove oldest if it would exceed cap
  if [[ -f "${path}.${backup_count}" ]]; then
    rm -f -- "${path}.${backup_count}" || true
  fi

  # Shift existing backwards
  local i
  for (( i=backup_count-1; i>=1; i-- )); do
    if [[ -f "${path}.${i}" ]]; then
      mv -f -- "${path}.${i}" "${path}.$((i+1))"
    fi
  done

  # Create new .1
  cp -f -- "${path}" "${path}.1"
  log_debug "Rotated secret file: $(basename "${path}") -> $(basename "${path}.1")"
}

# ==============================================================================
# Curl auth helpers (no plaintext creds in ps)
# ==============================================================================

# make_curl_config <username> <password> [verify] [additional_options]
# Creates a curl config snippet with enhanced security options.
make_curl_config() {
  local user="${1:?user required}"
  local pass="${2:?pass required}"
  local verify="${3:-secure}"
  local additional="${4:-}"

  cat <<EOF
user = "${user}:${pass}"
max-time = 30
connect-timeout = 10
show-error
silent
fail
location
$( [[ "${verify}" == "insecure" ]] && echo "insecure" )
${additional}
EOF
}

# write_curl_secret_config <username> <password> [verify] [path]
# Convenience: writes a -K compatible file at CURL_SECRET_PATH (or path).
write_curl_secret_config() {
  local user="${1:?user required}"
  local pass="${2:?password required}"
  local verify="${3:-secure}"
  local path="${4:-${CURL_SECRET_PATH}}"
  ensure_dir_secure "$(dirname -- "${path}")" 700 "curl secret dir"
  umask 077
  make_curl_config "${user}" "${pass}" "${verify}" \
    | atomic_write "${path}" "600"
  log_info "curl -K auth config written: ${path} (0600)"
}

# create_netrc <machine> <login> <password> [path]
# Writes a minimal ~/.netrc with enhanced security and validation.
create_netrc() {
  local machine="${1:?machine required}"
  local login="${2:?login required}"
  local pass="${3:?password required}"
  local path="${4:-${NETRC_PATH}}"

  if ! validate_password_strength "${pass}"; then
    log_warn "Weak password detected for netrc entry"
  fi

  umask 077
  local tmp_file="${path}.tmp.$$"
  cat > "${tmp_file}" <<EOF
machine ${machine}
  login ${login}
  password ${pass}
EOF
  atomic_write_file "${tmp_file}" "${path}" "600"
  log_info "Netrc authentication configured: $(basename "${path}") (0600)"
}

# curl_auth <url> [curl args...]
# Uses -K ${CURL_SECRET_PATH} if present; else --netrc-file ${NETRC_PATH}.
# Never passes credentials on the command line.
curl_auth() {
  local url="${1:?url required}"; shift || true
  local auth_method=""

  if [[ -f "${CURL_SECRET_PATH}" ]]; then
    auth_method="curl -K"
    curl -sS -K "${CURL_SECRET_PATH}" "${url}" "$@"
  elif [[ -f "${NETRC_PATH}" ]]; then
    auth_method="netrc"
    curl -sS --netrc-file "${NETRC_PATH}" "${url}" "$@"
  else
    log_error "No authentication configured. Expected ${CURL_SECRET_PATH} or ${NETRC_PATH}"
    return "${E_INVALID_INPUT}"
  fi

  local rc=$?
  if [[ ${rc} -eq 0 ]]; then
    log_debug "Authenticated request successful (${auth_method})"
  else
    log_error "Authenticated request failed (${auth_method}) with exit code ${rc}"
  fi
  return ${rc}
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

# get_cert_info <cert_file>
# Prints certificate information (subject, issuer, validity dates)
get_cert_info() {
  local cert="${1:?cert required}"
  if [[ ! -r "${cert}" ]]; then
    log_error "Certificate file not readable: ${cert}"
    return 1
  fi
  log_info "Certificate Information: $(basename "${cert}")"
  openssl x509 -in "${cert}" -noout -subject -issuer -dates 2>/dev/null || {
    log_error "Failed to read certificate information"
    return 1
  }
}

# cert_expires_within <cert_file> <days>
# Returns 0 if cert expires within N days (or file missing/unreadable); 1 otherwise.
cert_expires_within() {
  local cert="${1:?cert required}" days="${2:?days required}"

  [[ -r "${cert}" ]] || { log_debug "Certificate missing/unreadable: ${cert}"; return 0; }

  local end epoch_now epoch_end
  end="$(openssl x509 -enddate -noout -in "${cert}" 2>/dev/null | sed 's/notAfter=//')" || {
    log_warn "Cannot read certificate expiry date: ${cert}"
    return 0
  }

  epoch_now="$(date +%s)"
  if epoch_end="$(date -d "${end}" +%s 2>/dev/null)"; then
    : # GNU date
  elif epoch_end="$(date -j -f "%b %d %T %Y %Z" "${end}" +%s 2>/dev/null)"; then
    : # BSD date (macOS)
  else
    log_warn "Cannot parse certificate date format: ${end}"
    return 0
  fi

  local diff_days=$(( (epoch_end - epoch_now) / 86400 ))
  if (( diff_days <= days )); then
    log_warn "Certificate expires in ${diff_days} days: $(basename "${cert}")"
    return 0
  fi
  log_debug "Certificate valid for ${diff_days} more days: $(basename "${cert}")"
  return 1
}

# generate_ca_cert <ca_key> <ca_cert> [cn] [days]
# Generates a Certificate Authority for internal use
generate_ca_cert() {
  local ca_key="${1:?CA key file required}"
  local ca_cert="${2:?CA cert file required}"
  local cn="${3:-Internal CA}"
  local days="${4:-${CERT_DEFAULT_DAYS}}"

  ensure_dir_secure "$(dirname -- "${ca_key}")" 700 "CA directory"
  ensure_dir_secure "$(dirname -- "${ca_cert}")" 755 "CA cert directory"

  # Skip if CA exists and is valid
  if [[ -f "${ca_key}" && -f "${ca_cert}" ]] && ! cert_expires_within "${ca_cert}" "${CERT_REISSUE_BEFORE_DAYS}"; then
    log_info "CA certificate exists and is valid"
    return 0
  fi

  have_cmd openssl || die "${E_MISSING_DEP}" "OpenSSL required for CA generation"
  log_info "Generating Certificate Authority: ${cn}"

  local tmp_key tmp_cert config
  tmp_key="$(mktemp "${ca_key}.tmp.XXXXXX")"
  tmp_cert="$(mktemp "${ca_cert}.tmp.XXXXXX")"
  config="$(mktemp "${TLS_DIR}/ca-config-XXXXXX.cnf")"
  register_cleanup "rm -f '${tmp_key}' '${tmp_cert}' '${config}'"

  cat > "${config}" <<EOF
[req]
distinguished_name = dn
x509_extensions = ca_ext
prompt = no

[dn]
CN = ${cn}
O = Internal
OU = Certificate Authority

[ca_ext]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF

  if [[ "${CERT_DEFAULT_ALG}" == "ed25519" ]] && _openssl_supports_ed25519; then
    if ! openssl req -x509 -new -newkey ed25519 -nodes \
         -keyout "${tmp_key}" -out "${tmp_cert}" \
         -days "${days}" -config "${config}" >/dev/null 2>&1; then
      log_warn "Ed25519 CA generation failed, using RSA"
      openssl genrsa -out "${tmp_key}" 4096 >/dev/null 2>&1
      openssl req -x509 -new -key "${tmp_key}" \
        -out "${tmp_cert}" -days "${days}" -config "${config}" >/dev/null 2>&1
    fi
  else
    openssl genrsa -out "${tmp_key}" 4096 >/dev/null 2>&1
    openssl req -x509 -new -key "${tmp_key}" \
      -out "${tmp_cert}" -days "${days}" -config "${config}" >/dev/null 2>&1
  fi

  chmod 600 "${tmp_key}"
  chmod 644 "${tmp_cert}"
  atomic_write_file "${tmp_key}" "${ca_key}" "600"
  atomic_write_file "${tmp_cert}" "${ca_cert}" "644"
  log_success "Certificate Authority generated: $(basename "${ca_cert}")"
}

# generate_self_signed_cert <cn> <key_file> <cert_file> [san_csv] [days] [alg]
# Enhanced with better SAN handling and validation.
generate_self_signed_cert() {
  local cn="${1:?common name required}"
  local key="${2:?key file required}"
  local crt="${3:?cert file required}"
  local san_csv="${4:-}"
  local days="${5:-${CERT_DEFAULT_DAYS}}"
  local alg="${6:-${CERT_DEFAULT_ALG}}"

  ensure_dir_secure "$(dirname -- "${key}")" 700 "certificate directory"
  ensure_dir_secure "$(dirname -- "${crt}")" 755 "certificate directory"

  # Enhanced default SANs (Splunk-friendly)
  if [[ -z "${san_csv}" ]]; then
    local default_sans="${cn},localhost,127.0.0.1,::1"
    if [[ "${cn}" =~ splunk ]]; then
      default_sans+=",splunk,*.splunk.local"
    fi
    san_csv="${default_sans}"
  fi

  # Skip if fresh enough
  if [[ -f "${key}" && -f "${crt}" ]] && ! cert_expires_within "${crt}" "${CERT_REISSUE_BEFORE_DAYS}"; then
    log_info "TLS certificate valid: $(basename "${crt}")"
    return 0
  fi

  have_cmd openssl || die "${E_MISSING_DEP}" "OpenSSL is required to generate certificates"

  log_info "Generating self-signed TLS certificate:"
  log_info "  CN: ${cn}"
  log_info "  SANs: ${san_csv}"
  log_info "  Algorithm: ${alg}"
  log_info "  Validity: ${days} days"

  local cfg tmp_key tmp_crt
  ensure_dir_secure "${TLS_DIR}"
  cfg="$(mktemp "${TLS_DIR}/openssl-XXXXXX.cnf")"
  tmp_key="$(mktemp "${key}.tmp.XXXXXX")"
  tmp_crt="$(mktemp "${crt}.tmp.XXXXXX")"
  register_cleanup "rm -f '${cfg}' '${tmp_key}' '${tmp_crt}'"

  # Build SAN entries with improved parsing
  local IFS=','; local -a sans=(${san_csv}); IFS=$' \t\n'
  {
    echo "[req]"
    echo "distinguished_name = dn"
    echo "x509_extensions = v3_req"
    echo "prompt = no"
    echo "[dn]"
    echo "CN = ${cn}"
    echo "O = Splunk Deployment"
    echo "OU = Container Services"
    echo "[v3_req]"
    echo "basicConstraints = CA:FALSE"
    echo "keyUsage = nonRepudiation, digitalSignature, keyEncipherment"
    echo "extendedKeyUsage = serverAuth, clientAuth"
    echo "subjectAltName = @alt_names"
    echo "[alt_names]"
    local dns_count=1 ip_count=1 s
    for s in "${sans[@]}"; do
      s="$(echo "${s}" | xargs)"  # Trim whitespace
      if [[ "${s}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "IP.${ip_count} = ${s}"; ((ip_count++))
      elif [[ "${s}" == "::1" || "${s}" =~ : ]]; then
        echo "IP.${ip_count} = ${s}"; ((ip_count++))
      else
        echo "DNS.${dns_count} = ${s}"; ((dns_count++))
      fi
    done
  } > "${cfg}"

  # Generate with preferred algorithm
  if [[ "${alg}" == "ed25519" ]] && _openssl_supports_ed25519; then
    if ! openssl req -x509 -new -newkey ed25519 -nodes \
         -keyout "${tmp_key}" -out "${tmp_crt}" \
         -days "${days}" -config "${cfg}" >/dev/null 2>&1; then
      log_warn "Ed25519 generation failed, falling back to RSA"
      alg="rsa"
    fi
  fi

  if [[ "${alg}" == "rsa" ]]; then
    openssl genrsa -out "${tmp_key}" 4096 >/dev/null 2>&1
    openssl req -x509 -new -key "${tmp_key}" \
      -out "${tmp_crt}" -days "${days}" -config "${cfg}" >/dev/null 2>&1
  fi

  # Validate generated certificate
  if ! openssl x509 -in "${tmp_crt}" -noout -text >/dev/null 2>&1; then
    die "${E_GENERAL}" "Generated certificate is invalid"
  fi

  chmod 600 "${tmp_key}" 2>/dev/null || true
  chmod 644 "${tmp_crt}" 2>/dev/null || true
  atomic_write_file "${tmp_key}" "${key}" "600"
  atomic_write_file "${tmp_crt}" "${crt}" "644"

  log_success "TLS certificate generated: $(basename "${crt}")"
  get_cert_info "${crt}"
}

# ==============================================================================
# Splunk-specific security functions
# ==============================================================================

# setup_splunk_secrets <splunk_password> <splunk_secret> [secrets_dir]
# Sets up Splunk authentication secrets with proper security
setup_splunk_secrets() {
  local password="${1:?Splunk password required}"
  local secret="${2:?Splunk secret required}"
  local secrets_dir="${3:-${SPLUNK_SECRETS_DIR}}"

  log_info "Setting up Splunk security configuration..."

  if ! validate_password_strength "${password}"; then
    die "${E_INVALID_INPUT}" "Splunk password does not meet security requirements"
  fi

  ensure_dir_secure "${secrets_dir}" 700 "Splunk secrets directory"

  write_secret_file "${secrets_dir}/admin_password" "${password}" "Splunk admin password"
  write_secret_file "${secrets_dir}/secret_key"     "${secret}"   "Splunk secret key"

  # Create server key for inter-node communication if needed
  if [[ ! -f "${secrets_dir}/server_key" ]]; then
    local server_secret
    server_secret="$(generate_splunk_secret 64)"
    write_secret_file "${secrets_dir}/server_key" "${server_secret}" "Splunk server key"
  fi

  log_success "Splunk secrets configured securely"
}

# generate_splunk_ssl_cert <splunk_hostname> [cert_dir]
# Generates SSL certificates for Splunk with appropriate SANs
generate_splunk_ssl_cert() {
  local hostname="${1:?Splunk hostname required}"
  local cert_dir="${2:-${TLS_DIR}/splunk}"

  ensure_dir_secure "${cert_dir}" 755 "Splunk TLS directory"

  local key_file="${cert_dir}/${hostname}.key"
  local cert_file="${cert_dir}/${hostname}.crt"

  # Splunk-specific SANs
  local splunk_sans="${hostname},${hostname}.local,localhost,127.0.0.1"
  if [[ "${hostname}" =~ ^splunk-(.+)$ ]]; then
    local service_name="${BASH_REMATCH[1]}"
    splunk_sans+=",${service_name},${service_name}.splunk.local"
  fi

  generate_self_signed_cert "${hostname}" "${key_file}" "${cert_file}" "${splunk_sans}"

  # Combined PEM bundle some Splunk components prefer
  local pem_file="${cert_dir}/${hostname}.pem"
  cat "${cert_file}" "${key_file}" > "${pem_file}"
  chmod 600 "${pem_file}"

  log_info "Splunk SSL certificate bundle: $(basename "${pem_file}")"
}

# ==============================================================================
# Security validation and audit functions
# ==============================================================================

# audit_security_configuration [output_file]
# Performs security audit and optionally writes report
audit_security_configuration() {
  local output_file="${1:-}"
  local audit_results=()

  log_info "Performing security configuration audit..."

  # Check private key permissions under TLS_DIR
  local insecure_files=()
  if [[ -d "${TLS_DIR}" ]]; then
    while IFS= read -r -d '' file; do
      local perms
      perms="$(stat -c "%a" "${file}" 2>/dev/null || stat -f "%Lp" "${file}" 2>/dev/null || echo "")"
      if [[ -n "${perms}" && "${perms}" != "600" ]]; then
        insecure_files+=("${file} (${perms})")
      fi
    done < <(find "${TLS_DIR}" -type f -name "*.key" -print0 2>/dev/null)
  fi

  if [[ ${#insecure_files[@]} -gt 0 ]]; then
    audit_results+=("FAIL: Insecure private key permissions: ${insecure_files[*]}")
  else
    audit_results+=("PASS: Private key permissions secure")
  fi

  # Check certificate expiry under TLS_DIR
  local expiring_certs=()
  if [[ -d "${TLS_DIR}" ]]; then
    while IFS= read -r -d '' cert; do
      if cert_expires_within "${cert}" 30; then
        expiring_certs+=("$(basename "${cert}")")
      fi
    done < <(find "${TLS_DIR}" -type f -name "*.crt" -print0 2>/dev/null)
  fi

  if [[ ${#expiring_certs[@]} -gt 0 ]]; then
    audit_results+=("WARN: Certificates expiring soon: ${expiring_certs[*]}")
  else
    audit_results+=("PASS: No certificates expiring within 30 days")
  fi

  # Check for weak Splunk password from env (if present; value not logged)
  if [[ -n "${SPLUNK_PASSWORD:-}" ]]; then
    if validate_password_strength "${SPLUNK_PASSWORD}"; then
      audit_results+=("PASS: Splunk password (env) meets complexity requirements")
    else
      audit_results+=("FAIL: Splunk password (env) does not meet complexity requirements")
    fi
  fi

  # Report results
  local line
  for line in "${audit_results[@]}"; do
    case "${line}" in
      FAIL:*) log_error "${line}" ;;
      WARN:*) log_warn  "${line}" ;;
      *)      log_success "${line}" ;;
    esac
  done

  # Optional report file
  if [[ -n "${output_file}" ]]; then
    {
      echo "# Security Audit Report - $(date)"
      echo "# Generated by lib/security.sh"
      echo
      for line in "${audit_results[@]}"; do
        echo "${line}"
      done
    } > "${output_file}"
    log_info "Security audit report written: ${output_file}"
  fi

  # Non-zero if any FAIL
  for line in "${audit_results[@]}"; do
    [[ "${line}" == FAIL:* ]] && return 1
  done
  return 0
}

# ==============================================================================
# End of lib/security.sh
# ==============================================================================

# Export key functions for subshell usage
export -f generate_random_password validate_password_strength write_secret_file \
          generate_splunk_secret harden_file_permissions ensure_dir_secure \
          rotate_secret_file make_curl_config write_curl_secret_config \
          create_netrc curl_auth get_cert_info cert_expires_within \
          generate_ca_cert generate_self_signed_cert setup_splunk_secrets \
          generate_splunk_ssl_cert audit_security_configuration
