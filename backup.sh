#!/bin/bash

set -euo pipefail

SCRIPT_VERSION="3.3.0"
GITHUB_RAW_URL="https://raw.githubusercontent.com/solarexpertscr/influxdb-backup-gcs/main/backup.sh"

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
RCLONE_REMOTE_NAME="${RCLONE_REMOTE_NAME:-gcs}"
RCLONE_DEST="${RCLONE_REMOTE_NAME}:${SITE_NAME}/influxdb/"
TIMESTAMP=$(date +%Y%m%d%H%M%S)
LOCAL_BACKUP_PATH="${LOCAL_BACKUP_DIR}/${TIMESTAMP}"

LOG_FILE="/var/log/influxdb-backup.log"
if [[ ! -f "$LOG_FILE" ]]; then
    touch "$LOG_FILE" 2>/dev/null || true
fi

log() {
    echo "[$(date)] $1" | tee -a "$LOG_FILE"
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

    local backup_file="${SCRIPT_DIR}/backup.sh.bak.$(date +%Y%m%d_%H%M%S)"
    cp "${SCRIPT_DIR}/backup.sh" "$backup_file"
    log "Created backup: $(basename "$backup_file")"

    if ! cp "$temp_script" "${SCRIPT_DIR}/backup.sh"; then
        log "ERROR: Failed to install new version - attempting rollback"
        cp "$backup_file" "${SCRIPT_DIR}/backup.sh" 2>/dev/null || log "ERROR: Rollback failed!"
        rm -f "$temp_script"
        return 1
    fi

    chmod +x "${SCRIPT_DIR}/backup.sh"
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
    --status-only)
        mkdir -p "${LOCAL_BACKUP_DIR}"
        AVAILABLE_SPACE=$(df -m "${LOCAL_BACKUP_DIR}" | awk 'NR==2 {print $4}')
        STATUS_FILE="${LOCAL_BACKUP_DIR}/status.json"
        cat > "$STATUS_FILE" <<STATUSEOF
{
  "hostname": "$(hostname -s 2>/dev/null || echo unknown)",
  "site": "${SITE_NAME}",
  "version": "${SCRIPT_VERSION}",
  "last_backup": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "free_mb": ${AVAILABLE_SPACE}
}
STATUSEOF
        if rclone copy "$STATUS_FILE" "${RCLONE_DEST}status.json" 2>/dev/null; then
            log "✓ Status uploaded (hourly, ${AVAILABLE_SPACE}MB free)"
        else
            log "⚠ Status upload failed"
        fi
        exit 0
        ;;
esac

###############################################################################
# Pre-flight: self-update FIRST, so broken backup scripts can self-heal
###############################################################################

if [[ -z "${INFLUXDB_BACKUP_NO_AUTOUPDATE:-}" ]]; then
    # Only run auto-update when called as a normal backup (not from --update/--check-update)
    REMOTE_VER=$(check_for_update 2>/dev/null || echo "")
    if [[ -n "$REMOTE_VER" && "$REMOTE_VER" != "$SCRIPT_VERSION" ]]; then
        log "ℹ New version available: $REMOTE_VER (current: $SCRIPT_VERSION) — auto-updating before backup..."
        export INFLUXDB_BACKUP_NO_AUTOUPDATE=1
        if do_update; then
            log "✓ Update installed, re-running with new version..."
            exec bash "$0" "$@"
        else
            log "⚠ Auto-update failed, continuing with current version..."
            unset INFLUXDB_BACKUP_NO_AUTOUPDATE
        fi
    fi
fi

###############################################################################
# Pre-flight: disk space check + auto-cleanup
###############################################################################

mkdir -p "${LOCAL_BACKUP_DIR}"
REQUIRED_MB="${REQUIRED_MB:-1000}"
AVAILABLE_SPACE=$(df -m "${LOCAL_BACKUP_DIR}" | awk 'NR==2 {print $4}')

if (( AVAILABLE_SPACE < REQUIRED_MB )); then
    log "⚠ Low disk space: ${AVAILABLE_SPACE}MB available (need ${REQUIRED_MB}MB)"
    log "Running cleanup.sh to reclaim space..."
    if bash "${SCRIPT_DIR}/cleanup.sh" 2>&1 | while IFS= read -r line; do log "[cleanup] $line"; done; then
        AVAILABLE_SPACE=$(df -m "${LOCAL_BACKUP_DIR}" | awk 'NR==2 {print $4}')
        log "Post-cleanup: ${AVAILABLE_SPACE}MB free"
        if (( AVAILABLE_SPACE < REQUIRED_MB )); then
            log "ERROR: Still insufficient after cleanup: ${AVAILABLE_SPACE}MB (need ${REQUIRED_MB}MB)"
            exit 1
        fi
        log "✓ Cleanup reclaimed enough space"
    else
        log "ERROR: cleanup.sh failed"
        exit 1
    fi
fi
log "✓ Disk space OK: ${AVAILABLE_SPACE}MB available"

###############################################################################
# InfluxDB portable backup (shards + manifest)
###############################################################################

log "=========================================="
log "InfluxDB Shard-Based Backup v${SCRIPT_VERSION}"
log "Site: ${SITE_NAME}"
log "=========================================="

log "Creating InfluxDB portable backup: $(basename "$LOCAL_BACKUP_PATH")"

if ! influxd backup -portable "$LOCAL_BACKUP_PATH" >> "$LOG_FILE" 2>&1; then
    log "ERROR: InfluxDB backup failed"
    rm -rf "$LOCAL_BACKUP_PATH"
    exit 1
fi

log "✓ InfluxDB backup created successfully"

SHARD_COUNT=$(find "$LOCAL_BACKUP_PATH" -type f ! -name "manifest" | wc -l)
BACKUP_SIZE=$(du -sm "$LOCAL_BACKUP_PATH" 2>/dev/null | awk '{print $1}')
log "Shard files: ${SHARD_COUNT}  |  Local size: ${BACKUP_SIZE}MB"

###############################################################################
# Sync ONLY the 2 most recent shards + manifest to GCS
# Older shards are frozen and already on GCS — no need to re-upload.
###############################################################################

log "Identifying shards to upload (2 newest by mtime)..."

# Collect all shard files (exclude manifest), sorted newest first
mapfile -t ALL_SHARDS < <(find "$LOCAL_BACKUP_PATH" -type f ! -name "manifest" -printf '%T@ %p\n' | sort -rn | awk '{print $2}')
UPLOAD_COUNT=${#ALL_SHARDS[@]}

# Pick the 2 newest
TO_UPLOAD=()
for (( i=0; i<UPLOAD_COUNT && i<2; i++ )); do
    TO_UPLOAD+=("${ALL_SHARDS[$i]}")
done

# Include manifest if it exists
MANIFEST_FILE="${LOCAL_BACKUP_PATH}/manifest"
UPLOAD_MANIFEST=false
if [[ -f "$MANIFEST_FILE" ]]; then
    UPLOAD_MANIFEST=true
fi

UPLOAD_TOTAL=$(( ${#TO_UPLOAD[@]} + ($UPLOAD_MANIFEST && 1 || 0) ))
log "Shards to upload: ${#TO_UPLOAD[@]} of ${SHARD_COUNT} total (+ manifest: ${UPLOAD_MANIFEST})"
for f in "${TO_UPLOAD[@]}"; do
    log "  → $(basename "$f")  ($(du -sh "$f" | awk '{print $1}'))"
done

UPLOAD_START=$(date +%s)

SYNC_TMPDIR=$(mktemp -d)
# Copy only the selected files into a staging dir
for f in "${TO_UPLOAD[@]}"; do
    cp "$f" "${SYNC_TMPDIR}/"
done
if $UPLOAD_MANIFEST; then
    cp "$MANIFEST_FILE" "${SYNC_TMPDIR}/"
fi

if ! rclone copy "$SYNC_TMPDIR" "${RCLONE_DEST}" --update --transfers=4 >> "$LOG_FILE" 2>&1; then
    log "ERROR: Shard sync to GCS failed"
    rm -rf "$SYNC_TMPDIR"
    log "Local backup preserved at: $LOCAL_BACKUP_PATH"
    exit 1
fi
rm -rf "$SYNC_TMPDIR"

UPLOAD_END=$(date +%s)
log "✓ Shard sync completed in $(( UPLOAD_END - UPLOAD_START ))s (${#TO_UPLOAD[@]} shards + manifest)"

###############################################################################
# Verify upload (only the files we uploaded)
###############################################################################

log "Verifying uploaded files..."

VERIFIED=0
for f in "${TO_UPLOAD[@]}"; do
    REL_PATH="${f#${LOCAL_BACKUP_PATH}/}"
    if rclone size "${RCLONE_DEST}${REL_PATH}" > /dev/null 2>&1; then
        VERIFIED=$(( VERIFIED + 1 ))
    else
        log "⚠ Verification failed for: $REL_PATH"
    fi
done
if $UPLOAD_MANIFEST; then
    if rclone size "${RCLONE_DEST}manifest" > /dev/null 2>&1; then
        VERIFIED=$(( VERIFIED + 1 ))
    else
        log "⚠ Verification failed for: manifest"
    fi
fi

if [[ "$VERIFIED" -eq "$UPLOAD_TOTAL" ]]; then
    log "✓ All ${UPLOAD_TOTAL} uploaded files verified on GCS"
else
    log "ERROR: Verification mismatch: ${VERIFIED}/${UPLOAD_TOTAL} files confirmed"
    log "Local backup preserved at: $LOCAL_BACKUP_PATH"
    exit 1
fi

###############################################################################
# Cleanup
###############################################################################

rm -rf "$LOCAL_BACKUP_PATH"
log "✓ Local backup directory removed"

# Keep only the 2 most recent local backup dirs as a safety net
find "${LOCAL_BACKUP_DIR}" -maxdepth 1 -type d -name "[0-9]*" \
    | sort -r | tail -n +3 \
    | xargs rm -rf 2>/dev/null || true

###############################################################################
# Self-update check (end of run, non-blocking)
###############################################################################

REMOTE_VER=$(check_for_update 2>/dev/null || echo "")
if [[ -n "$REMOTE_VER" && "$REMOTE_VER" != "$SCRIPT_VERSION" ]]; then
    log "ℹ New version available: $REMOTE_VER (current: $SCRIPT_VERSION)"
    log "  Run: $0 --update or wait for weekly auto-update cron job"
fi

###############################################################################
# Write status.json (uploaded on next rclone sync)
###############################################################################

STATUS_FILE="${LOCAL_BACKUP_DIR}/status.json"
cat > "$STATUS_FILE" <<EOF
{
  "hostname": "$(hostname -s 2>/dev/null || echo unknown)",
  "site": "${SITE_NAME}",
  "version": "${SCRIPT_VERSION}",
  "last_backup": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "free_mb": ${AVAILABLE_SPACE},
  "shard_count": ${SHARD_COUNT},
  "backup_size_mb": ${BACKUP_SIZE},
  "upload_duration_s": $(( UPLOAD_END - UPLOAD_START ))
}
EOF
log "✓ Status written to ${STATUS_FILE}"

# Upload status.json + any lingering stale files to GCS
if rclone copy "$STATUS_FILE" "${RCLONE_DEST}status.json" 2>/dev/null; then
    log "✓ Status uploaded to GCS"
fi

log "=========================================="
log "✓ Backup completed successfully"
log "=========================================="
exit 0
