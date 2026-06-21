#!/bin/bash

set -euo pipefail

# ============================================================================
# Disk Space Cleanup for Solar Assistant Pis
# ============================================================================
# Safely reclaims space: apt cache, old logs, stale backup artifacts,
# journald logs. Designed to be run manually or scheduled via cron.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "[ERROR] Environment file not found: $ENV_FILE" >&2
    exit 1
fi

source "$ENV_FILE"

CRITICAL_MB="${CRITICAL_MB:-300}"
WARNING_MB="${WARNING_MB:-1000}"

SCRIPT_DIR="${SCRIPT_DIR:-/opt/influxdb-backup-gcs}"
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-/var/lib/influxdb-backup/${SITE_NAME}}"
LOG_FILE="${LOG_FILE:-/var/log/influxdb-backup.log}"
MAX_LOG_MB="${MAX_LOG_MB:-20}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [cleanup] $1"; }

# ---------------------------------------------------------------------------
# State before
# ---------------------------------------------------------------------------

disk_free() { df -m "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }
disk_used() { du -sm "$1" 2>/dev/null | awk '{print $1}' || echo 0; }

FREE_BEFORE=$(disk_free /)
log "Disk state BEFORE cleanup:"
log "  Free:     ${FREE_BEFORE} MB"
log "  apt cache: $(disk_used /var/cache/apt) MB"
log "  journal:   $(disk_used /var/log/journal) MB"
log "  logs:      $(disk_used /var/log) MB"
log "  backups:   $(disk_used "$LOCAL_BACKUP_DIR") MB"

# ---------------------------------------------------------------------------
# Cleanup steps
# ---------------------------------------------------------------------------

log "Cleaning apt cache..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get clean 2>/dev/null || true
    apt-get autoclean -y 2>/dev/null || true
    log "  ✓ apt cache cleared"
fi

log "Vacuuming systemd journal..."
if command -v journalctl >/dev/null 2>&1 && [[ -d /var/log/journal ]]; then
    if journalctl --vacuum-size=20M 2>/dev/null; then
        log "  ✓ journal trimmed to ≤20MB"
    fi
fi

log "Truncating oversized log files..."
if [[ -f "$LOG_FILE" ]]; then
    LOG_SIZE_KB=$(du -sk "$LOG_FILE" 2>/dev/null | awk '{print $1}' || echo 0)
    LOG_SIZE_MB=$(( LOG_SIZE_KB / 1024 ))
    if (( LOG_SIZE_MB > MAX_LOG_MB )); then
        tail -n 1000 "$LOG_FILE" > "${LOG_FILE}.tmp"
        mv "${LOG_FILE}.tmp" "$LOG_FILE"
        log "  ✓ ${LOG_FILE} truncated (kept last 1000 lines)"
    else
        log "  (skipped - ${LOG_FILE} is ${LOG_SIZE_MB}MB, under ${MAX_LOG_MB}MB limit)"
    fi
fi

# Truncate any single log file over 50MB in /var/log (safety net)
find /var/log -type f -name "*.log" -size +50M -exec truncate -s 10M {} \; 2>/dev/null || true

log "Removing stale backup artifacts..."
# Remove backup staging dirs older than 2 days (not the current one)
PRUNED=0
for dir in "${LOCAL_BACKUP_DIR}"/[0-9]* "${LOCAL_BACKUP_DIR}"/backup-*; do
    [ -d "$dir" ] || continue
    if [ "$(find "$dir" -mtime +2 2>/dev/null)" ]; then
        rm -rf "$dir"
        PRUNED=$((PRUNED + 1))
    fi
done
log "  ✓ Removed ${PRUNED} stale backup dir(s)"

# Remove orphaned temp files older than 7 days
find /tmp -type f -mtime +7 -user root -delete 2>/dev/null || true
find /var/tmp -type f -mtime +7 -user root -delete 2>/dev/null || true
log "  ✓ Old /tmp files removed"

# Remove downloaded but unpacked .deb files left by apt
find /var/cache/apt/archives -type f -name "*.deb" -mtime +1 -delete 2>/dev/null || true

# ---------------------------------------------------------------------------
# State after
# ---------------------------------------------------------------------------

FREE_AFTER=$(disk_free /)
RECLAIMED=$(( FREE_AFTER - FREE_BEFORE ))

log ""
log "Disk state AFTER cleanup:"
log "  Free:      ${FREE_AFTER} MB"
log "  Reclaimed: ${RECLAIMED} MB"

if (( FREE_AFTER < CRITICAL_MB )); then
    log "⚠  WARNING: Still below critical threshold (${CRITICAL_MB}MB)!"
    log "   Manual intervention needed. Large unexpected consumers:"
    du -sh /var/lib /var/cache /var/log /opt 2>/dev/null | sort -rh | head -5
    exit 1
elif (( FREE_AFTER < WARNING_MB )); then
    log "⚠  Note: Below warning threshold (${WARNING_MB}MB). Will retry daily."
else
    log "✓ Disk space healthy"
fi

exit 0
