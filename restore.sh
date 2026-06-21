#!/bin/bash

set -euo pipefail

SCRIPT_VERSION="3.0.2"
GITHUB_RAW_URL="https://raw.githubusercontent.com/solarexpertscr/influxdb-backup-gcs/main/restore.sh"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export RCLONE_CONFIG="/etc/rclone.conf"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "[$(date)] ERROR: Environment file not found: $ENV_FILE"
    exit 1
fi
source "$ENV_FILE"

# Derived values
GCS_BUCKET="gs://${SITE_NAME}"
RCLONE_DEST="${RCLONE_REMOTE}:${SITE_NAME}/influxdb/"
TIMESTAMP=$(date +%Y%m%d%H%M%S)
RESTORE_PATH="${LOCAL_BACKUP_DIR}/restore_${TIMESTAMP}"

LOG_FILE="/var/log/influxdb-backup.log"

log() {
    echo "[$(date)] $1"
}

###############################################################################
# Self-update
###############################################################################

check_for_update() {
    local temp_script
    temp_script=$(mktemp)
    if curl -fsSL "$GITHUB_RAW_URL" -o "$temp_script" 2>/dev/null; then
        local remote_version
        remote_version=$(grep '^SCRIPT_VERSION=' "$temp_script" | head -1 | sed 's/.*"\(.*\)".*/\1/')
        rm -f "$temp_script"
        echo "$remote_version"
        return 0
    fi
    rm -f "$temp_script"
    return 1
}

do_update() {
    local temp_script
    temp_script=$(mktemp)

    log "Checking for updates..."

    if ! curl -fsSL "$GITHUB_RAW_URL" -o "$temp_script"; then
        log "ERROR: Failed to download latest version"
        rm -f "$temp_script"
        return 1
    fi

    local remote_version
    remote_version=$(grep '^SCRIPT_VERSION=' "$temp_script" | head -1 | sed 's/.*"\(.*\)".*/\1/')

    if [[ -z "$remote_version" ]]; then
        log "ERROR: Downloaded script has no version tag"
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
        log "ERROR: Downloaded script has syntax errors - aborting update"
        rm -f "$temp_script"
        return 1
    fi
    log "Syntax check passed"

    local backup_file="${SCRIPT_DIR}/restore.sh.bak.$(date +%Y%m%d_%H%M%S)"
    cp "${SCRIPT_DIR}/restore.sh" "$backup_file"
    log "Created backup: $(basename "$backup_file")"

    if ! cp "$temp_script" "${SCRIPT_DIR}/restore.sh"; then
        log "ERROR: Failed to install new version - attempting rollback"
        cp "$backup_file" "${SCRIPT_DIR}/restore.sh" 2>/dev/null || log "ERROR: Rollback failed!"
        rm -f "$temp_script"
        return 1
    fi

    chmod +x "${SCRIPT_DIR}/restore.sh"
    rm -f "$temp_script"

    log "✓ Updated to version $remote_version"
    log "Previous version saved as: $(basename "$backup_file")"
    return 0
}

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

###############################################################################
# Download all shards from GCS
###############################################################################

log "=========================================="
log "InfluxDB Shard-Based Restore v${SCRIPT_VERSION}"
log "Site: ${SITE_NAME}"
log "=========================================="

mkdir -p "${RESTORE_PATH}"

log "Downloading all shards from ${RCLONE_DEST}..."

if ! rclone sync "${RCLONE_DEST}" "${RESTORE_PATH}" --transfers=4; then
    log "ERROR: Failed to download from GCS"
    rm -rf "${RESTORE_PATH}"
    exit 1
fi

SHARD_COUNT=$(find "${RESTORE_PATH}" -type f ! -name "manifest" | wc -l)
log "Downloaded ${SHARD_COUNT} shard files"

###############################################################################
# Restore to InfluxDB
###############################################################################

log "Restoring to InfluxDB..."

if ! influxd restore -portable "${RESTORE_PATH}" >> "$LOG_FILE" 2>&1; then
    log "ERROR: InfluxDB restore failed"
    log "Restored data preserved at: ${RESTORE_PATH}"
    exit 1
fi

log "✓ InfluxDB restore completed successfully"

###############################################################################
# Cleanup
###############################################################################

rm -rf "${RESTORE_PATH}"
log "✓ Temporary restore directory removed"

log "=========================================="
log "✓ Restore completed successfully"
log "=========================================="
exit 0
