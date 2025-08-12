#!/usr/bin/env bash
#
# ==============================================================================
# lib/error-handling.sh
# ------------------------------------------------------------------------------
# ⭐⭐⭐⭐⭐
#
# Provides robust error handling, recovery, and cleanup mechanisms.
# This library is essential for creating reliable and resilient operations.
#
# Features:
#   - A command retry function with exponential backoff.
#   - A signal-based cleanup handler to ensure atomic operations.
#   - State management functions for progress tracking and recovery.
#
# Dependencies: lib/core.sh
# Required by:  All operations
#
# ==============================================================================

# --- Source Dependencies ---
# Must have core.sh for logging (log_warn, log_error) and error codes.
# This assumes core.sh is in the same directory or sourced by the calling script.
if [[ -z "${COLOR_RESET:-}" ]]; then # Check if core.sh has been sourced
    # In a real scenario, the main script would source this. For safety, we can try:
    # source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
    echo "FATAL: lib/core.sh must be sourced before lib/error-handling.sh" >&2
    exit 1
fi

# --- Atomic Operations and Cleanup ---
# This mechanism uses a trap to ensure that registered cleanup tasks are
# executed when the script exits, for any reason (success, error, or interrupt).

# Global array to hold functions or commands to execute on exit.
declare -a CLEANUP_TASKS

# The main cleanup handler function. It's executed by the trap.
# It iterates through cleanup tasks in reverse order (LIFO).
run_cleanup_handler() {
    log_debug "Running cleanup handler..."
    for ((i=${#CLEANUP_TASKS[@]}-1; i>=0; i--)); do
        local task="${CLEANUP_TASKS[i]}"
        log_debug "Executing cleanup task: ${task}"
        # Use eval to correctly execute commands with arguments
        eval "${task}" || log_warn "Cleanup task failed: ${task}"
    done
}

# Set the trap. This line registers the 'run_cleanup_handler' function to be
# called automatically when the script receives an EXIT, INT, or TERM signal.
trap run_cleanup_handler EXIT INT TERM

# Adds a command or function to the cleanup stack.
# Usage: add_cleanup_task "rm -f /tmp/my_temp_file"
add_cleanup_task() {
    local task="$1"
    CLEANUP_TASKS+=("$task")
    log_debug "Added cleanup task: ${task}"
}


# --- Retry Mechanism with Exponential Backoff ---

# Retries a command a specified number of times with an increasing delay.
# Usage: retry_command <max_retries> <initial_delay_sec> <command_with_args>
# Example: retry_command 5 2 "curl -fS http://example.com"
retry_command() {
    local max_retries="$1"
    local delay="$2"
    local cmd=("${@:3}") # The command and its arguments

    # Use default values if not provided
    : "${max_retries:=3}"
    : "${delay:=2}"

    for i in $(seq 1 "$max_retries"); do
        # Execute the command, suppressing its output on failure
        if "${cmd[@]}"; then
            log_debug "Command succeeded: ${cmd[*]}"
            return 0 # Success
        fi

        # If it's the last attempt, break the loop to fail
        if [[ "$i" -eq "$max_retries" ]]; then
            break
        fi

        log_warn "Command failed: '${cmd[*]}'. Retrying in ${delay}s... (Attempt ${i}/${max_retries})"
        sleep "$delay"
        delay=$((delay * 2)) # Exponential backoff
    done

    log_error "Command failed after ${max_retries} attempts: '${cmd[*]}'"
    return "$E_GENERAL" # Use a generic error code from core.sh
}


# --- Progress Tracking and Recovery ---
# These functions use state files to track the progress of multi-step operations.
# This allows a script to be resumed or recovered if it fails midway.

# The directory where state files will be stored.
readonly STATE_DIR="/tmp/app-progress-state"
mkdir -p "$STATE_DIR"

# Marks the beginning of an operation by creating a state file.
# Usage: begin_operation "generate-certificates"
begin_operation() {
    local op_name="$1"
    local state_file="${STATE_DIR}/${op_name}.state"
    log_debug "Beginning operation '${op_name}'. Creating state file: ${state_file}"
    touch "${state_file}"
    # Register the completion of this operation as a cleanup task.
    # If the script fails, the state file will remain, indicating an incomplete op.
    add_cleanup_task "complete_operation '${op_name}'"
}

# Marks an operation as complete by removing its state file.
# This is usually called automatically by the cleanup handler.
# Usage: complete_operation "generate-certificates"
complete_operation() {
    local op_name="$1"
    local state_file="${STATE_DIR}/${op_name}.state"
    if [[ -f "$state_file" ]]; then
        log_debug "Completing operation '${op_name}'. Removing state file."
        rm -f "${state_file}"
    fi
}

# Checks if an operation failed to complete in a previous run.
# Returns 0 (true) if the operation is incomplete, 1 (false) otherwise.
# Usage: if did_operation_fail "generate-certificates"; then ...
did_operation_fail() {
    local op_name="$1"
    local state_file="${STATE_DIR}/${op_name}.state"
    [[ -f "$state_file" ]]
}