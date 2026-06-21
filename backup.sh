#!/bin/bash

set -euo pipefail

# ============================================================================
# InfluxDB Backup to GCS — Shard-Based Sync (rclone)
# ============================================================================
# Only uploads changed/new shard files. Frozen shards are never re-uploaded.
# The active shard is overwritten daily; rclone's --update flag skips unchanged
# files automatically.
# ============================================================================

SCRIPT_VERSION="3.0.1"
GITHUB_RAW_URL="https://raw.githubusercontent.com/solarexpertscr/influxdb-backup-gcs/main/backup.sh"

# Set PATH explicitly for cron compatibility
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Rclone config path (setup.sh writes to /etc/rclone.conf)
export RCLONE_CONFIG="/etc/rclone.conf"

# ============================================================================
# Helpers
# ============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

# ============================================================================
# Self-Update Functionality
# ============================================================================

check_for_update() {
    local temp_script
    temp_script=$(mktemp)

    if curl -fsSL "$GITHUB_RAW_URL" -o "$temp_script" 2>/dev/null; then
        local remote_version
        remote_version=$(grep -oP 'SCRIPT_VERSION="\K[^"]+' "$temp_script" 2>/dev/null || echo "unknown")

        if [[ "$remote_version" != "unknown" ]]; then
            echo "$remote_version"
            rm -f "$temp_script"
            return 0
        fi
        rm -f "$temp_script"
    fi
    return 1
}

do_update() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local backup_script="$script_dir/backup.sh"
    local temp_script
    temp_script=$(mktemp)

    log "Checking for updates..."

    if ! curl -fsSL "$GITHUB_RAW_URL" -o "$temp_script"; then
        log_error "Failed to download latest version"
        rm -f "$temp_script"
        return 1
    fi

    local remote_version
    remote_version=$(grep -oP 'SCRIPT_VERSION="\K[^"]+' "$temp_script" 2>/dev/null || echo "unknown")

    if [[ "$remote_version" == "unknown" ]]; then
        log_error "Downloaded script has no version tag"
        rm -f "$temp_script"
        return 1
    fi

    if [[ "$remote_version" == "$SCRIPT_VERSION" ]]; then
        log "Already at latest version: $SCRIPT_VERSION"
        rm -f "$temp_script"
        return 0
    fi

    log "New version available: $remote_version (current: $SCRIPT_VERSION)"

    if ! bash -n "$temp_script"; then
        log_error "Downloaded script has syntax errors - aborting update"
        rm -f "$temp_script"
        return 1
    fi

    log "Syntax check passed"

    local backup_file="$backup_script.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$backup_script" "$backup_file"
    log "Created backup: $(basename "$backup_file")"

    if ! cp "$temp_script" "$backup_script"; then
        log_error "Failed to install new version - attempting rollback"
        cp "$backup_file" "$backup_script" || log_error "Rollback failed!"
        rm -f "$temp_script"
        return 1
    fi

    chmod +x "$backup_script"
    rm -f "$temp_script"

    log "✓ Updated to version $remote_version"
    log "Previous version saved as: $(basename "$backup_file")"
    return 0
}

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# Handle --update and --auto-update flags
# ============================================================================

case "${1:-}" in
    --update)
        do_update
        exit $?
        ;;
    --auto-update)
        log "Running auto-update (non-interactive)..."
        if do_update; then
            log "✓ Auto-update complete"
        else
            log "Auto-update failed or skipped"
        fi
        exit 0
        ;;
    --check-update)
        REMOTE_VER=$(check_for_update 2>/dev/null || echo "")
        if [[ -n "$REMOTE_VER" && "$REMOTE_VER" != "$SCRIPT_VERSION" ]]; then
            log "New version available: $REMOTE_VER (current: $SCRIPT_VERSION)"
            log "Run: $0 --update to install"
            exit 1
        else
            log "Up to date: $SCRIPT_VERSION"
            exit 0
        fi
        ;;
esac

# ============================================================================
# Load Environment
# ============================================================================

ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    log_error "Environment file not found: $ENV_FILE"
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

if [[ -z "${SITE_NAME:-}" ]]; then
    log_error "SITE_NAME not set in $ENV_FILE"
    exit 1
fi

# Support both legacy RCLONE_REMOTE and new RCLONE_REMOTE_NAME
if [[ -n "${RCLONE_REMOTE_NAME:-}" ]]; then
    RCLONE_REMOTE="${RCLONE_REMOTE_NAME}"
elif [[ -z "${RCLONE_REMOTE:-}" ]]; then
    RCLONE_REMOTE="gcs"
fi

# Ensure RCLONE_REMOTE ends with colon
if [[ "$RCLONE_REMOTE" != *: ]]; then
    RCLONE_REMOTE="${RCLONE_REMOTE}:"
fi

# Set defaults
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-/var/lib/influxdb-backup/${SITE_NAME}}"
REQUIRED_MB="${REQUIRED_MB:-1000}"

# GCS destination: each shard file is uploaded individually so rclone can
# skip unchanged (frozen) shards and only re-upload the active shard.
RCLONE_DEST="${RCLONE_REMOTE}${SITE_NAME}/influxdb/"

# ============================================================================
# Main Backup Logic
# ============================================================================

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# Ensure directories exist
mkdir -p "$LOCAL_BACKUP_DIR"

log "=========================================="
log "InfluxDB Shard-Based Backup v${SCRIPT_VERSION}"
log "Site: ${SITE_NAME}"
log "=========================================="

# ---------------------------------------------------------------------------
# Pre-flight: disk space
# ---------------------------------------------------------------------------

AVAILABLE_SPACE=$(df -m "$LOCAL_BACKUP_DIR" | awk 'NR==2 {print $4}')
if [[ "$AVAILABLE_SPACE" -lt "$REQUIRED_MB" ]]; then
    log_error "Insufficient disk space: ${AVAILABLE_SPACE}MB available (need ${REQUIRED_MB}MB)"
    exit 1
fi
log "✓ Disk space check passed: ${AVAILABLE_SPACE}MB available"

# Clean up previous backup artifacts (keep only current run's output)
CURRENT_BACKUP_PATH="${LOCAL_BACKUP_DIR}/backup-${TIMESTAMP}"

# ---------------------------------------------------------------------------
# Create portable InfluxDB backup (shards + manifest)
# ---------------------------------------------------------------------------

log "Creating InfluxDB portable backup: $(basename "$CURRENT_BACKUP_PATH")"

if influxd backup \
    -portable \
    "$CURRENT_BACKUP_PATH" \
    >> /var/log/influxdb-backup.log 2>&1; then

    log "✓ InfluxDB backup created successfully"
else
    log_error "InfluxDB backup failed"
    rm -rf "$CURRENT_BACKUP_PATH"
    exit 1
fi

# ---------------------------------------------------------------------------
# Count shard files for summary
# ---------------------------------------------------------------------------

SHARD_COUNT=$(find "$CURRENT_BACKUP_PATH" -type f ! -name "manifest" | wc -l)
BACKUP_SIZE=$(du -sm "$CURRENT_BACKUP_PATH" 2>/dev/null | awk '{print $1}')
log "Shard files: ${SHARD_COUNT}  |  Local size: ${BACKUP_SIZE}MB"

# ---------------------------------------------------------------------------
# Sync shard files to GCS
#
# `rclone copy --update`:
#   - Uploads new/frozen shards once (skipped on subsequent runs)
#   - Re-uploads the active shard daily (it changes size each run)
#   - No tar needed — individual files, no full-database upload
#
# The manifest is always re-synced to ensure it matches current state.
# ---------------------------------------------------------------------------

log "Syncing shards to GCS: ${RCLONE_DEST}"
log "  (--update: only changed/new shards are transferred)"

UPLOAD_START=$(date +%s)

if rclone copy "$CURRENT_BACKUP_PATH" "${RCLONE_DEST}" --update --transfers=4; then
    UPLOAD_END=$(date +%s)
    log "✓ Shard sync completed in $(( UPLOAD_END - UPLOAD_START ))s"
else
    log_error "Shard sync to GCS failed"
    log_error "Local backup preserved at: $CURRENT_BACKUP_PATH"
    exit 1
fi

# ---------------------------------------------------------------------------
# Verify: confirm manifest is present on GCS
# ---------------------------------------------------------------------------

log "Verifying sync..."

VERIFIED=0
for f in $(find "$CURRENT_BACKUP_PATH" -type f ! -name "manifest"); do
    REL_PATH="${f#${CURRENT_BACKUP_PATH}/}"
    if rclone size "${RCLONE_DEST}${REL_PATH}" > /dev/null 2>&1; then
        VERIFIED=$(( VERIFIED + 1 ))
    fi
done

if [[ "$VERIFIED" -eq "$SHARD_COUNT" ]]; then
    log "✓ All ${SHARD_COUNT} shard files verified on GCS"
else
    log_error "Verification mismatch: ${VERIFIED}/${SHARD_COUNT} shard files confirmed"
    log_error "Local backup preserved at: $CURRENT_BACKUP_PATH"
    exit 1
fi

# ---------------------------------------------------------------------------
# Cleanup: remove local backup directory (keep a tiny footprint)
# ---------------------------------------------------------------------------

rm -rf "$CURRENT_BACKUP_PATH"
log "✓ Local backup directory removed"

# ---------------------------------------------------------------------------
# Prune: keep only the 2 most recent local backup dirs (safety net)
# ---------------------------------------------------------------------------

find "$LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "backup-*" \
    | sort -r | tail -n +3 \
    | xargs rm -rf 2>/dev/null || true

REMOTE_PRUNED=$(find "$LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "backup-*" | wc -l)
log "Local backup dirs retained: ${REMOTE_PRUNED}"

# ---------------------------------------------------------------------------
# Self-update check (non-blocking, end of run)
# ---------------------------------------------------------------------------

REMOTE_VER=$(check_for_update 2>/dev/null || echo "")
if [[ -n "$REMOTE_VER" && "$REMOTE_VER" != "$SCRIPT_VERSION" ]]; then
    log "ℹ New version available: $REMOTE_VER (current: $SCRIPT_VERSION)"
    log "  Run: $0 --update or wait for weekly auto-update cron job"
fi

log "=========================================="
log "✓ Backup completed successfully"
log "=========================================="

exit 0
