#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# Global trap for useful diagnostics
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:$LINENO exited with $rc" >&2; exit $rc' ERR

# Script to rotate logs and clean up old log files
# This implements log rotation for the logs/ directory

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Log Rotation and Cleanup ==="

# Configuration
LOG_DIR="${SCRIPT_DIR}/logs"
MAX_LOG_AGE_DAYS=7
MAX_LOG_COUNT=50

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Function to rotate logs by age
rotate_logs_by_age() {
    local log_dir="$1"
    local max_age="$2"

    echo "Rotating logs older than ${max_age} days..."

    # Find and remove old log files
    find "$log_dir" -name "*.log" -type f -mtime "+$max_age" -print -delete | while read -r file; do
        echo "🗑️  Removed old log: $(basename "$file")"
    done
}

# Function to rotate logs by count (keep only newest N files)
rotate_logs_by_count() {
    local log_dir="$1"
    local max_count="$2"

    echo "Keeping only the ${max_count} most recent log files..."

    # Get list of log files sorted by modification time (newest first)
    mapfile -t log_files < <(find "$log_dir" -name "*.log" -type f -printf '%T@ %p\n' | sort -nr | head -n "$max_count" | cut -d' ' -f2-)

    # Get all log files
    mapfile -t all_logs < <(find "$log_dir" -name "*.log" -type f)

    # Remove files not in the keep list
    for log_file in "${all_logs[@]}"; do
        local keep_file=false
        for keep in "${log_files[@]}"; do
            if [[ "$log_file" == "$keep" ]]; then
                keep_file=true
                break
            fi
        done

        if [[ "$keep_file" == "false" ]]; then
            rm -f "$log_file"
            echo "🗑️  Removed excess log: $(basename "$log_file")"
        fi
    done
}

# Function to compress old logs
compress_old_logs() {
    local log_dir="$1"
    local compress_age=3

    echo "Compressing logs older than ${compress_age} days..."

    find "$log_dir" -name "*.log" -type f -mtime "+$compress_age" ! -name "*.gz" -print0 | while IFS= read -r -d '' file; do
        if [[ ! -f "${file}.gz" ]]; then
            gzip "$file"
            echo "📦 Compressed log: $(basename "$file").gz"
        fi
    done
}

# Main rotation logic
main() {
    echo "Log directory: $LOG_DIR"

    # Count current logs
    local log_count
    log_count=$(find "$LOG_DIR" -name "*.log" -o -name "*.log.gz" | wc -l)
    echo "Current log files: $log_count"

    # Rotate by age
    rotate_logs_by_age "$LOG_DIR" "$MAX_LOG_AGE_DAYS"

    # Compress old logs
    compress_old_logs "$LOG_DIR"

    # Rotate by count (after compression)
    rotate_logs_by_count "$LOG_DIR" "$MAX_LOG_COUNT"

    # Final count
    local final_count
    final_count=$(find "$LOG_DIR" -name "*.log" -o -name "*.log.gz" | wc -l)
    echo "Final log files: $final_count"

    echo "✅ Log rotation complete"
}

# Run main function
main "$@"
