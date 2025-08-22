#!/bin/bash
# ==============================================================================
# scripts/backup/scheduled_backup.sh
# Automated scheduled backup execution
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/../../lib/core.sh"
source "${SCRIPT_DIR}/../../lib/error-handling.sh"
source "${SCRIPT_DIR}/backup_utils.sh"

# Configuration
readonly BACKUP_SCHEDULE_CONFIG="${SCRIPT_DIR}/backup_schedule.conf"
readonly BACKUP_LOG_FILE="/var/log/splunk_backup.log"

setup_scheduled_backups() {
    log_info "Setting up scheduled backups..."
    
    # Create default schedule configuration
    create_default_schedule_config
    
    # Set up cron jobs
    setup_cron_jobs
    
    log_success "Scheduled backups configured"
}

create_default_schedule_config() {
    if [[ -f "${BACKUP_SCHEDULE_CONFIG}" ]]; then
        log_info "Backup schedule configuration already exists"
        return 0
    fi
    
    cat > "${BACKUP_SCHEDULE_CONFIG}" << 'EOF'
# Splunk Backup Schedule Configuration
# Format: SCHEDULE_TYPE:CRON_EXPRESSION:BACKUP_TYPE:RETENTION_DAYS

# Daily configuration backup at 2 AM
DAILY_CONFIG:0 2 * * *:config:7

# Weekly full backup on Sunday at 3 AM
WEEKLY_FULL:0 3 * * 0:full:30

# Monthly archive backup on 1st at 4 AM
MONTHLY_ARCHIVE:0 4 1 * *:full:90
EOF
    
    log_info "Created default backup schedule configuration"
}

setup_cron_jobs() {
    local cron_file="/tmp/splunk_backup_cron"
    
    # Read existing crontab
    crontab -l 2>/dev/null > "${cron_file}" || touch "${cron_file}"
    
    # Remove existing Splunk backup entries
    sed -i '/# Splunk Backup/d' "${cron_file}"
    sed -i '/scheduled_backup.sh/d' "${cron_file}"
    
    # Add new backup schedules
    echo "# Splunk Backup Schedules" >> "${cron_file}"
    
    while IFS=':' read -r schedule_name cron_expr backup_type retention_days; do
        # Skip comments and empty lines
        [[ "${schedule_name}" =~ ^#.*$ ]] && continue
        [[ -z "${schedule_name}" ]] && continue
        
        local cron_command="${SCRIPT_DIR}/scheduled_backup.sh run ${backup_type} ${retention_days}"
        echo "${cron_expr} ${cron_command} >> ${BACKUP_LOG_FILE} 2>&1" >> "${cron_file}"
        
        log_info "Scheduled ${schedule_name}: ${cron_expr} (${backup_type})"
    done < "${BACKUP_SCHEDULE_CONFIG}"
    
    # Install new crontab
    crontab "${cron_file}"
    rm -f "${cron_file}"
    
    log_success "Cron jobs configured"
}

run_scheduled_backup() {
    local backup_type="${1:-config}"
    local retention_days="${2:-30}"
    
    log_info "Running scheduled backup: type=${backup_type}, retention=${retention_days}"
    
    # Set custom retention for this backup
    export BACKUP_RETENTION_DAYS="${retention_days}"
    
    # Execute backup
    if "${SCRIPT_DIR}/backup_manager.sh" create "${backup_type}"; then
        log_success "Scheduled backup completed successfully"
        
        # Send notification on success
        send_backup_notification "SUCCESS" "Scheduled ${backup_type} backup completed"
    else
        log_error "Scheduled backup failed"
        
        # Send notification on failure
        send_backup_notification "FAILURE" "Scheduled ${backup_type} backup failed"
        exit 1
    fi
}

send_backup_notification() {
    local status="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Log notification
    echo "[${timestamp}] BACKUP_NOTIFICATION: ${status} - ${message}" >> "${BACKUP_LOG_FILE}"
    
    # Send email notification if configured
    if [[ -n "${BACKUP_NOTIFICATION_EMAIL:-}" ]]; then
        send_email_notification "${status}" "${message}"
    fi
    
    # Send Slack notification if configured
    if [[ -n "${BACKUP_SLACK_WEBHOOK:-}" ]]; then
        send_slack_notification "${status}" "${message}"
    fi
}

send_email_notification() {
    local status="$1"
    local message="$2"
    local subject="[Splunk Backup] ${status}: ${message}"
    local hostname
    hostname=$(hostname)
    
    # Create email body
    local email_body
    email_body=$(cat << EOF
Splunk Backup Notification

Status: ${status}
Message: ${message}
Hostname: ${hostname}
Timestamp: $(date '+%Y-%m-%d %H:%M:%S')

Recent backup log:
$(tail -10 "${BACKUP_LOG_FILE}" 2>/dev/null || echo "No log available")
EOF
)
    
    # Send email using mail command if available
    if command -v mail >/dev/null; then
        echo "${email_body}" | mail -s "${subject}" "${BACKUP_NOTIFICATION_EMAIL}"
        log_info "Email notification sent to ${BACKUP_NOTIFICATION_EMAIL}"
    else
        log_warning "Mail command not available for email notifications"
    fi
}

send_slack_notification() {
    local status="$1"
    local message="$2"
    local color="good"
    
    if [[ "${status}" == "FAILURE" ]]; then
        color="danger"
    fi
    
    local payload
    payload=$(cat << EOF
{
    "attachments": [
        {
            "color": "${color}",
            "title": "Splunk Backup Notification",
            "fields": [
                {
                    "title": "Status",
                    "value": "${status}",
                    "short": true
                },
                {
                    "title": "Message",
                    "value": "${message}",
                    "short": false
                },
                {
                    "title": "Hostname",
                    "value": "$(hostname)",
                    "short": true
                },
                {
                    "title": "Timestamp",
                    "value": "$(date '+%Y-%m-%d %H:%M:%S')",
                    "short": true
                }
            ]
        }
    ]
}
EOF
)
    
    # Send Slack notification
    if curl -X POST -H 'Content-type: application/json' \
            --data "${payload}" \
            "${BACKUP_SLACK_WEBHOOK}" >/dev/null 2>&1; then
        log_info "Slack notification sent"
    else
        log_warning "Failed to send Slack notification"
    fi
}

check_backup_health() {
    log_info "Checking backup system health..."
    
    local health_issues=0
    
    # Check backup directory
    if [[ ! -d "${BACKUP_BASE_DIR}" ]]; then
        log_error "Backup directory does not exist: ${BACKUP_BASE_DIR}"
        ((health_issues++))
    fi
    
    # Check disk space
    local available_space_mb
    available_space_mb=$(df "${BACKUP_BASE_DIR}" | awk 'NR==2 {print int($4/1024)}')
    
    if [[ ${available_space_mb} -lt 1024 ]]; then  # Less than 1GB
        log_error "Low disk space for backups: ${available_space_mb}MB available"
        ((health_issues++))
    fi
    
    # Check recent backups
    local recent_backups
    recent_backups=$(find "${BACKUP_BASE_DIR}" -name "*.tar.gz" -mtime -7 2>/dev/null | wc -l)
    
    if [[ ${recent_backups} -eq 0 ]]; then
        log_warning "No backups found in the last 7 days"
        ((health_issues++))
    fi
    
    # Check cron jobs
    if ! crontab -l 2>/dev/null | grep -q "scheduled_backup.sh"; then
        log_warning "No scheduled backup cron jobs found"
        ((health_issues++))
    fi
    
    if [[ ${health_issues} -eq 0 ]]; then
        log_success "Backup system health check passed"
        return 0
    else
        log_error "Backup system health check found ${health_issues} issue(s)"
        return 1
    fi
}

main() {
    local action="${1:-}"
    
    case "${action}" in
        "setup")
            setup_scheduled_backups
            ;;
        "run")
            local backup_type="${2:-config}"
            local retention_days="${3:-30}"
            run_scheduled_backup "${backup_type}" "${retention_days}"
            ;;
        "health")
            check_backup_health
            ;;
        "test-notification")
            local status="${2:-SUCCESS}"
            local message="${3:-Test notification}"
            send_backup_notification "${status}" "${message}"
            ;;
        *)
            cat << EOF
Usage: $0 {setup|run|health|test-notification}

Commands:
    setup                           Setup scheduled backups and cron jobs
    run <type> [retention]          Run a scheduled backup
    health                          Check backup system health
    test-notification [status] [msg] Test notification system

Examples:
    $0 setup
    $0 run full 30
    $0 health
    $0 test-notification SUCCESS "Test message"
EOF
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
