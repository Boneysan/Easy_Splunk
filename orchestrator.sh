#!/usr/bin/env bash
# ==============================================================================
# orchestrator.sh
# Main entrypoint: parse config, validate host, detect runtime, generate compose,
# and bring the stack up with retries + health wait.
#
# Dependencies:
#   lib/core.sh, lib/error-handling.sh, versions.env, lib/versions.sh,
#   lib/validation.sh, lib/runtime-detection.sh, lib/compose-generator.sh,
#   parse-args.sh
# ==============================================================================

# --- Strict Mode & Setup --------------------------------------------------------
set -eEuo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# --- Source Dependencies (ordered) ---------------------------------------------
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"

# versions: keep env data separate from helpers
# shellcheck source=versions.env
source "${SCRIPT_DIR}/versions.env"
# shellcheck source=lib/versions.sh
source "${SCRIPT_DIR}/lib/versions.sh"
verify_versions_env || die "${E_INVALID_INPUT}" "versions.env contains invalid values"

# shellcheck source=lib/validation.sh
source "${SCRIPT_DIR}/lib/validation.sh"
# shellcheck source=lib/runtime-detection.sh
source "${SCRIPT_DIR}/lib/runtime-detection.sh"
# shellcheck source=lib/compose-generator.sh
source "${SCRIPT_DIR}/lib/compose-generator.sh"
# shellcheck source=parse-args.sh
source "${SCRIPT_DIR}/parse-args.sh"

# --- Defaults / Tunables --------------------------------------------------------
: "${WORKDIR:=${PWD}}"
: "${COMPOSE_FILE:=${WORKDIR}/docker-compose.yml}"
: "${HEALTH_WAIT_SECONDS:=20}"       # simple post-up settle time
: "${STARTUP_DEADLINE:=180}"         # seconds; total budget for compose up retries
: "${RETRIES:=5}"                    # attempts inside with_retry
: "${RETRY_BASE_DELAY:=2}"           # seconds
: "${RETRY_MAX_DELAY:=20}"           # seconds

# Ensure workdir exists; register cleanup for any temp artifacts
mkdir -p "${WORKDIR}"

# --- Functions -----------------------------------------------------------------
_preflight() {
  log_info "🔎 Running preflight checks..."
  enforce_system_resources 4096 2
  validate_vm_max_map_count 262144 || log_warn "Consider: sysctl -w vm.max_map_count=262144"

  # Port availability (app only; extend as needed)
  if ! validate_port_free "${APP_PORT}" ; then
    die "${E_INVALID_INPUT}" "Port ${APP_PORT} is in use. Choose a different --port."
  fi
}

_generate_compose() {
  log_info "🧩 Generating compose to ${COMPOSE_FILE}"
  generate_compose_file "${COMPOSE_FILE}"
}

_start_stack() {
  log_info "🚀 Starting stack (compose up -d)..."
  # Support monitoring via profiles; no regen needed
  local env_profiles=()
  if is_true "${ENABLE_MONITORING}"; then
    env_profiles=(env "COMPOSE_PROFILES=monitoring")
  fi

  # Run with deadline + retry (compose up can be flaky on cold systems)
  deadline_retry "${STARTUP_DEADLINE}" -- \
    --retries "${RETRIES}" --base-delay "${RETRY_BASE_DELAY}" --max-delay "${RETRY_MAX_DELAY}" -- \
    "${env_profiles[@]}" bash -c \
    "$(printf '%q ' compose -f "${COMPOSE_FILE}" up -d --remove-orphans)"

  log_info "⏳ Waiting ${HEALTH_WAIT_SECONDS}s for services to settle..."
  sleep "${HEALTH_WAIT_SECONDS}"

  log_info "📋 Current container status:"
  compose -f "${COMPOSE_FILE}" ps || true
}

_main() {
  log_info "🚀 Starting Cluster Orchestrator..."

  # 1) Parse CLI/config; persist normalized config beside compose for traceability
  local effective_cfg="${WORKDIR}/config.effective"
  parse_arguments --write-effective "${effective_cfg}" "$@"

  # 2) Preflight validation
  _preflight

  # 3) Detect container runtime + compose implementation
  detect_container_runtime
  runtime_summary

  # 4) Generate compose atomically
  _generate_compose

  # 5) Bring the stack up resiliently
  _start_stack

  log_success "✅ Orchestration complete. The stack should be up."
  log_info    "View logs: compose -f '${COMPOSE_FILE}' logs -f"
  log_info    "Stop stack: compose -f '${COMPOSE_FILE}' down"
}

# --- Entry ----------------------------------------------------------------------
_main "$@"
