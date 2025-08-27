#!/usr/bin/env bash
# lib/run-with-log.sh
# Lightweight helper to standardize log initialization and tee stdout/stderr to the
# log file created by lib/error-handling.sh. Intended to be sourced by entrypoint
# scripts before they invoke their top-level main() when executed directly.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Try to source error-handling (best-effort)
if [[ -f "${SCRIPT_DIR}/error-handling.sh" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/error-handling.sh" || true
fi

run_entrypoint() {
    local entry_fn="$1"; shift || true
    # Caller script name is the previous element in BASH_SOURCE
    local caller_script="${BASH_SOURCE[1]:-${0##*/}}"

    # Ensure logging is initialized (setup_standard_logging is provided by error-handling)
    if type setup_standard_logging >/dev/null 2>&1; then
        setup_standard_logging "${caller_script}"
    else
        # Fallback: create a minimal LOG_FILE path
        : "${LOG_DIR:=./logs}"
        mkdir -p "$LOG_DIR" 2>/dev/null || true
        LOG_FILE="${LOG_DIR}/run-$(date +%F_%H%M%S).log"
        export LOG_FILE LOG_DIR
    fi

    # Redirect stdout/stderr to both console and the LOG_FILE
    exec > >(tee -a "${LOG_FILE}") 2> >(tee -a "${LOG_FILE}" >&2)

    # Call the provided entry function in-process so functions/vars remain available
    if [[ -n "$entry_fn" && $(type -t "$entry_fn") == "function" ]]; then
        "$entry_fn" "$@"
    else
        # If caller passed a command instead of function, try executing it
        if [[ -n "$entry_fn" ]]; then
            eval "$entry_fn" "$@"
        else
            echo "No entrypoint provided to run_entrypoint" >&2
            return 2
        fi
    fi
}

export -f run_entrypoint
