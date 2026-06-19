#!/bin/bash

set -euo pipefail

# ============================================================================
# InfluxDB Backup to GCS with Auto-Update Support
# ============================================================================

SCRIPT_VERSION="2.0.0"
GITHUB_RAW_URL="https://raw.githubusercontent.com/solarexpertscr/influxdb-backup-gcs/main/backup.sh"

# Set PATH explicitly for cron compatibility
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Helper functions
log() {
    echo "[$(date)] $1"
}

log_error() {
    echo "[$(date)] ERROR: $1" >&2
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
        rm -f "$temp_script"
        
        if [[ "$remote_version" == "unknown" ]]; then
            return 1
        fi
        
        echo "$remote_version"
        return 0
    else
        rm -f "$temp_script"
        return 1
    fi
}

do_update() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local backup_script="$script_dir/backup.sh"
    local temp_script
    temp_script=$(mktemp)
    
    log "Checking for updates..."
    
    # Download latest version
    if ! curl -fsSL "$GITHUB_RAW_URL" -o "$temp_script"; then
        log_error "Failed to download latest version"
        rm -f "$temp_script"
        return 1
    fi
    
    # Extract remote version
    local remote_version
    remote_version=$(grep -oP 'SCRIPT_VERSION="\K[^"]+' "$temp_script" 2>/dev/null || echo "unknown")
    
    if [[ "$remote_version" == "unknown" ]]; then
        log_error "Downloaded script has no version tag"
        rm -f "$temp_script"
        return 1
    fi
    
    # Check if update is needed
    if [[ "$remote_version" == "$SCRIPT_VERSION" ]]; then
        log "Already at latest version: $SCRIPT_VERSION"
        rm -f "$temp_script"
        return 0
    fi
    
    log "New version available: $remote_version (current: $SCRIPT_VERSION)"
    
    # Syntax check the downloaded script
    if ! bash -n "$temp_script"; then
        log_error "Downloaded script has syntax errors - aborting update"
        rm -f "$temp_script"
        return 1
    fi
    
    log "Syntax check passed"
    
    # Create backup of current version
    local backup_file="$backup_script.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$backup_script" "$backup_file"
    log "Created backup: $(basename "$backup_file")"
    
    # Atomic swap
    if ! cp "$temp_script" "$backup_script"; then
        log_error "Failed to install new version - attempting rollback"
        cp "$backup_file" "$backup_script" || log_error "Rollback failed!"
        rm -f "$temp_script"
        return 1
    fi
    
    # Preserve executable permission
    chmod +x "$backup_script"
    rm -f "$temp_script"
    
    log "✓ Updated to version $remote_version"
    log "Previous version saved as: $(basename "$backup_file")"
    log "To rollback manually: cp $backup_file $backup_script"
    
    return 0
}

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# Handle --update and --auto-update flags (exit before backup logic)
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
# Main Backup Logic
# ============================================================================

ENV_FILE="${SCRIPT_DIR}/.env"

# Load environment variables
if [ ! -f "$ENV_FILE" ]; then
    log_error "Environment file not found: $ENV_FILE"
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

# Validate required configuration
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
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-/tmp/influxdb-backup-${SITE_NAME}}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
REQUIRED_MB="${REQUIRED_MB:-1000}"

# Derived values
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_NAME="${SITE_NAME}_${TIMESTAMP}"
LOCAL_BACKUP_PATH="${LOCAL_BACKUP_DIR}/${BACKUP_NAME}"
RCLONE_DEST="${RCLONE_REMOTE}${SITE_NAME}/backups/"

# Ensure directories exist
mkdir -p "$LOCAL_BACKUP_DIR"

log "=========================================="
log "InfluxDB Backup Script v${SCRIPT_VERSION}"
log "Site: ${SITE_NAME}"
log "=========================================="

# Pre-flight checks
# 1. Check local backup size (orphaned backups from failed runs)
LOCAL_BACKUP_SIZE=$(du -sm "$LOCAL_BACKUP_DIR" 2>/dev/null | awk '{print $1}' || echo 0)
if [[ "$LOCAL_BACKUP_SIZE" -gt "$REQUIRED_MB" ]]; then
    log "⚠ Local backup directory is ${LOCAL_BACKUP_SIZE}MB (limit: ${REQUIRED_MB}MB)"
    log "This suggests previous uploads failed. Cleaning up old backups..."
    
    # Remove old backups but keep the most recent one
    find "$LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "${SITE_NAME}_*" -mtime +1 | sort -r | tail -n +2 | xargs rm -rf 2>/dev/null || true
    
    NEW_SIZE=$(du -sm "$LOCAL_BACKUP_DIR" 2>/dev/null | awk '{print $1}' || echo 0)
    log "Cleaned up. Local backup size: ${NEW_SIZE}MB"
fi

# 2. Check available disk space
AVAILABLE_SPACE=$(df -m "$LOCAL_BACKUP_DIR" | awk 'NR==2 {print $4}')
if [[ "$AVAILABLE_SPACE" -lt "$REQUIRED_MB" ]]; then
    log_error "Insufficient disk space: ${AVAILABLE_SPACE}MB available (need ${REQUIRED_MB}MB)"
    exit 1
fi
log "✓ Disk space check passed: ${AVAILABLE_SPACE}MB available"

# Create InfluxDB backup
log "Creating InfluxDB backup: $BACKUP_NAME"

if influxd backup \
    -portable \
    "$LOCAL_BACKUP_PATH" \
    >> /var/log/influxdb-backup.log 2>&1; then
    
    log "✓ InfluxDB backup created successfully"
else
    log_error "InfluxDB backup failed"
    rm -rf "$LOCAL_BACKUP_PATH"
    exit 1
fi

# Compress backup
ARCHIVE_PATH="/tmp/${BACKUP_NAME}.tar.gz"
log "Compressing backup to ${ARCHIVE_PATH}..."

if tar -czf "$ARCHIVE_PATH" -C "$LOCAL_BACKUP_DIR" "$(basename "$LOCAL_BACKUP_PATH")"; then
    log "✓ Backup compressed"
    ARCHIVE_SIZE=$(du -h "$ARCHIVE_PATH" | awk '{print $1}')
    log "Archive size: ${ARCHIVE_SIZE}"
    
    # Remove uncompressed backup directory immediately after compression
    rm -rf "$LOCAL_BACKUP_PATH"
    log "✓ Uncompressed backup removed"
else
    log_error "Compression failed"
    exit 1
fi

# Upload to GCS
log "Uploading to GCS: ${RCLONE_DEST}${BACKUP_NAME}.tar.gz"

if rclone copyto "$ARCHIVE_PATH" "${RCLONE_DEST}${BACKUP_NAME}.tar.gz"; then
    log "✓ Upload completed"
else
    log_error "Upload failed - archive preserved at $ARCHIVE_PATH"
    exit 1
fi

# Verify upload
log "Verifying upload..."

if rclone lsf "${RCLONE_DEST}${BACKUP_NAME}.tar.gz" > /dev/null 2>&1; then
    log "✓ Upload verified"
else
    log_error "Upload verification failed - archive preserved at $ARCHIVE_PATH"
    exit 1
fi

# Remove local archive after successful verification
rm -f "$ARCHIVE_PATH"
log "✓ Local archive removed"

# Check for script updates (non-blocking, end of run)
REMOTE_VER=$(check_for_update 2>/dev/null || echo "")
if [[ -n "$REMOTE_VER" && "$REMOTE_VER" != "$SCRIPT_VERSION" ]]; then
    log "ℹ New version available: $REMOTE_VER (current: $SCRIPT_VERSION)"
    log "  Run: $0 --update or wait for weekly auto-update cron job"
fi

log "✓ Backup completed successfully"
log "=========================================="

exit 0
