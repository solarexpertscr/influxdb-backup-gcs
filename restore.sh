#!/bin/bash

set -euo pipefail

# ============================================================================
# Restore InfluxDB from GCS shard backup
# ============================================================================
# Pulls all shard files from GCS back into a local backup directory, then
# runs influxd restore. Frozen shards are pulled once; only the active shard
# (and any shards from the most recent backup window) need downloading.
#
# Usage:
#   bash restore.sh                    # restore to default target
#   bash restore.sh --dry-run          # show what would be restored, don't run influxd restore
#   bash restore.sh --restore-dir DIR  # pull shards to DIR, then restore
#   bash restore.sh --list             # list available backup snapshots on GCS
# ============================================================================

# Set PATH explicitly for cron/sudo compatibility
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    log_error "Environment file not found: $ENV_FILE"
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# ---------------------------------------------------------------------------
# Configuration resolution
# ---------------------------------------------------------------------------

# RCLONE_REMOTE: prefer RCLONE_REMOTE_NAME, fallback to RCLONE_REMOTE, default "gcs"
if [[ -n "${RCLONE_REMOTE_NAME:-}" ]]; then
    RCLONE_REMOTE="${RCLONE_REMOTE_NAME}"
elif [[ -z "${RCLONE_REMOTE:-}" ]]; then
    RCLONE_REMOTE="gcs"
fi
[[ "$RCLONE_REMOTE" != *: ]] && RCLONE_REMOTE="${RCLONE_REMOTE}:"

LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-/tmp/influxdb-backup-${SITE_NAME}}"
RESTORE_DIR="${LOCAL_BACKUP_DIR}/restore-$(date +%Y%m%d_%H%M%S)"
GCS_BACKUP_ROOT="${RCLONE_REMOTE}${SITE_NAME}/influxdb/"

DRY_RUN=false
CUSTOM_RESTORE_DIR=""
LIST_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --restore-dir)
            CUSTOM_RESTORE_DIR="$2"
            shift 2
            ;;
        --list)
            LIST_ONLY=true
            shift
            ;;
        -h|--help)
            sed -n '2,12p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

[[ -n "$CUSTOM_RESTORE_DIR" ]] && RESTORE_DIR="$CUSTOM_RESTORE_DIR"

# ---------------------------------------------------------------------------
# --list: show what's on GCS
# ---------------------------------------------------------------------------

if $LIST_ONLY; then
    log "Backup contents on ${GCS_BACKUP_ROOT}:"
    rclone lsf "$GCS_BACKUP_ROOT" --files-only | sort
    exit 0
fi

# ---------------------------------------------------------------------------
# Pull shards from GCS
# ---------------------------------------------------------------------------

log "=========================================="
log "InfluxDB Restore from GCS"
log "Site: ${SITE_NAME}"
log "Restore dir: ${RESTORE_DIR}"
log "=========================================="

mkdir -p "$RESTORE_DIR"

log "Pulling backed-up shards from GCS..."
if rclone copy "$GCS_BACKUP_ROOT" "$RESTORE_DIR" --transfers=4; then
    log "✓ Shard files synchronized"
else
    log_error "Failed to pull from GCS"
    rm -rf "$RESTORE_DIR"
    exit 1
fi

# Count what we pulled
SHARD_COUNT=$(find "$RESTORE_DIR" -type f ! -name "manifest" | wc -l)
TOTAL_SIZE=$(du -sm "$RESTORE_DIR" 2>/dev/null | awk '{print $1}')
log "Shard files available: ${SHARD_COUNT}  |  Size: ${TOTAL_SIZE}MB"

# ---------------------------------------------------------------------------
# Dry-run mode
# ---------------------------------------------------------------------------

if $DRY_RUN; then
    log "[DRY RUN] Would restore from: $RESTORE_DIR"
    log "[DRY RUN] File list:"
    find "$RESTORE_DIR" -type f | sort | sed 's/^/  /'
    log "[DRY RUN] Restore directory preserved at: $RESTORE_DIR"
    log "[DRY RUN] To actually restore, run: influxd restore -portable $RESTORE_DIR"
    exit 0
fi

# ---------------------------------------------------------------------------
# Run influxd restore
# ---------------------------------------------------------------------------

log "Running influxd restore (portable)..."
log "Target InfluxDB instance (default): $(influxd config show 2>/dev/null | grep -i 'http-bind' || echo 'localhost:8086')"

if influxd restore -portable "$RESTORE_DIR" >> /var/log/influxdb-backup.log 2>&1; then
    log "✓ Restore completed successfully"
else
    log_error "influxd restore failed — see /var/log/influxdb-backup.log"
    log_error "Restore directory preserved at: $RESTORE_DIR"
    exit 1
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

if [[ -z "$CUSTOM_RESTORE_DIR" ]]; then
    rm -rf "$RESTORE_DIR"
    log "✓ Temporary restore directory removed"
else
    log "Custom restore directory preserved at: $RESTORE_DIR"
fi

log "=========================================="
log "✓ Restore completed successfully"
log "=========================================="

exit 0
