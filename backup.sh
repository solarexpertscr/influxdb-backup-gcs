#!/bin/bash
set -euo pipefail

SCRIPT_VERSION="4.1.2"
GITHUB_REPO="solarexpertscr/solar-assistant-scripts"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export RCLONE_CONFIG="/etc/rclone.conf"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "[$(date)] ERROR: Environment file not found: $ENV_FILE"
    exit 1
fi
source "$ENV_FILE"

DEPLOY_KEY_FILE="${SCRIPT_DIR}/deploy_key"

RCLONE_REMOTE_NAME="${RCLONE_REMOTE_NAME:-gcs}"
RCLONE_DEST="${RCLONE_REMOTE_NAME}:${SITE_NAME}/influxdb/"
TIMESTAMP=$(date +%Y%m%d%H%M%S)
LOCAL_BACKUP_PATH="${LOCAL_BACKUP_DIR}/${TIMESTAMP}"

LOCK_FILE="/var/lock/influxdb-backup-historical.lock"
FIRST_RUN_MARKER="${LOCAL_BACKUP_DIR}/.first_run_complete"

LOG_FILE="/var/log/influxdb-backup.log"
if [[ ! -f "$LOG_FILE" ]]; then
    touch "$LOG_FILE" 2>/dev/null || true
fi

log() { echo "[$(date)] $1" | tee -a "$LOG_FILE"; }

check_for_update() {
    local temp_dir; temp_dir=$(mktemp -d)
    if git ls-remote "git@github.com:${GITHUB_REPO}.git" refs/heads/main >/dev/null 2>&1 && \
       git clone --depth 1 "git@github.com:${GITHUB_REPO}.git" "$temp_dir" >/dev/null 2>&1; then
        local remote_version; remote_version=$(grep '^SCRIPT_VERSION=' "$temp_dir/backup.sh" | head -1 | sed 's/SCRIPT_VERSION=\(.*\)/\1/' | sed 's/"//g')
        rm -rf "$temp_dir"
        echo "$remote_version"
        return 0
    fi
    rm -rf "$temp_dir"
    return 1
}

do_update() {
    local temp_dir; temp_dir=$(mktemp -d)
    log "Checking for updates via SSH deploy key..."
    if ! git clone --depth 1 "git@github.com:${GITHUB_REPO}.git" "$temp_dir" >/dev/null 2>&1; then
        log "ERROR: Failed to clone repository via SSH"
        rm -rf "$temp_dir"
        return 1
    fi

    local remote_version; remote_version=$(grep '^SCRIPT_VERSION=' "$temp_dir/backup.sh" | head -1 | sed 's/SCRIPT_VERSION=\(.*\)/\1/' | sed 's/"//g')
    if [[ -z "$remote_version" ]]; then
        log "ERROR: No version tag found in remote backup.sh"
        rm -rf "$temp_dir"
        return 1
    fi

    if [[ "$remote_version" == "$SCRIPT_VERSION" ]]; then
        log "Up to date: $SCRIPT_VERSION"
        rm -rf "$temp_dir"
        return 0
    fi

    log "New version available: $remote_version (current: $SCRIPT_VERSION)"

    if ! bash -n "$temp_dir/backup.sh"; then
        log "ERROR: Remote backup.sh has syntax errors"
        rm -rf "$temp_dir"
        return 1
    fi

    local backup_file="${SCRIPT_DIR}/backup.sh.bak.$(date +%Y%m%d_%H%M%S)"
    cp "${SCRIPT_DIR}/backup.sh" "$backup_file"
    log "Backup: $(basename "$backup_file")"

    if ! cp "$temp_dir/backup.sh" "${SCRIPT_DIR}/backup.sh"; then
        log "ERROR: Failed to install update"
        cp "$backup_file" "${SCRIPT_DIR}/backup.sh" 2>/dev/null || true
        rm -rf "$temp_dir"
        return 1
    fi

    chmod +x "${SCRIPT_DIR}/backup.sh"
    rm -rf "$temp_dir"
    log "✓ Updated to $remote_version"
}

count_gcs_shards() {
    local shard_count
    shard_count=$(rclone lsjson "${RCLONE_DEST}" --files-only --max-depth 1 2>/dev/null | \
        python3 -c "
import json,sys
data=json.load(sys.stdin)
names=[f['Name'] for f in data]
count = sum(1 for n in names if n.isdigit() and len(n) == 5)
print(count)
" 2>/dev/null || echo "0")
    echo "$shard_count"
}

run_historical_upload() {
    local latest_backup="$1"
    log "=========================================="
    log "HISTORICAL UPLOAD MODE"
    log "=========================================="

    local total_shards; total_shards=$(find "$latest_backup" -type f ! -name "manifest" | wc -l)
    log "Local backup: $(basename "$latest_backup") with $total_shards shard files"

    local gcs_shard_names; gcs_shard_names=$(rclone lsjson "${RCLONE_DEST}" --files-only --max-depth 1 2>/dev/null | \
        python3 -c "
import json,sys
data=json.load(sys.stdin)
names = [f['Name'] for f in data if f['Name'].isdigit() and len(f['Name']) == 5]
print(' '.join(names))
" 2>/dev/null || echo "")

    local to_upload=()
    while IFS= read -r shard_file; do
        local shard_name; shard_name=$(basename "$shard_file")
        if ! echo " $gcs_shard_names " | grep -q " $shard_name "; then
            to_upload+=("$shard_file")
        fi
    done < <(find "$latest_backup" -type f ! -name "manifest")

    log "Need to upload: ${#to_upload[@]} shard files"

    if [[ ${#to_upload[@]} -eq 0 ]]; then
        return 0
    fi

    log "Uploading ${#to_upload[@]} missing shard files..."
    local SYNC_TMPDIR; SYNC_TMPDIR=$(mktemp -d)
    for f in "${to_upload[@]}"; do
        cp "$f" "${SYNC_TMPDIR}/"
    done

    if ! rclone copy "$SYNC_TMPDIR" "${RCLONE_DEST}" --update --transfers=4 >> "$LOG_FILE" 2>&1; then
        log "ERROR: Historical sync failed"
        rm -rf "$SYNC_TMPDIR"
        return 1
    fi
    rm -rf "$SYNC_TMPDIR"
    log "✓ Historical upload completed"
    return 0
}

cleanup_old_gcs_format() {
    log "Checking for old-format GCS files to clean up..."
    local old_files
    old_files=$(rclone lsjson "${RCLONE_DEST}" --files-only --max-depth 1 2>/dev/null | \
        python3 -c "
import json,sys
data=json.load(sys.stdin)
names=[f['Name'] for f in data]
old = [n for n in names if '.tar.gz' in n or '.manifest' in n or '.meta' in n]
print(' '.join(old))
" 2>/dev/null || echo "")

    if [[ -n "$old_files" ]]; then
        local count; count=$(echo "$old_files" | wc -w)
        log "Found $count old-format files, deleting..."
        echo "$old_files" | tr ' ' '\n' | while IFS= read -r f; do
            [[ -n "$f" ]] && rclone deletefile "${RCLONE_DEST}${f}" 2>/dev/null && log "  Deleted: $f"
        done
        log "✓ Old-format cleanup complete ($count files removed)"
    else
        log "No old-format files found"
    fi
}

case "${1:-}" in
    --update) do_update; exit $? ;;
    --auto-update) if do_update; then log "✓ Auto-update done"; else log "Auto-update skipped"; fi; exit 0 ;;
    --check-update) REMOTE_VER=$(check_for_update 2>/dev/null || echo ""); if [[ -n "$REMOTE_VER" && "$REMOTE_VER" != "$SCRIPT_VERSION" ]]; then log "New: $REMOTE_VER"; exit 1; else log "Up to date: $SCRIPT_VERSION"; exit 0; fi ;;
    --status-only)
        mkdir -p "${LOCAL_BACKUP_DIR}"
        AVAILABLE_SPACE=$(df -m "${LOCAL_BACKUP_DIR}" | awk 'NR==2{print$4}')
        STATUS_FILE="${LOCAL_BACKUP_DIR}/status.json"
        printf '{"hostname":"%s","site":"%s","version":"%s","last_backup":"%s","free_mb":%s}\n' \
            "$(hostname -s 2>/dev/null||echo unknown)" "$SITE_NAME" "$SCRIPT_VERSION" \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$AVAILABLE_SPACE" > "$STATUS_FILE"
        if rclone copy "$STATUS_FILE" "${RCLONE_DEST}status.json" 2>/dev/null; then
            log "✓ Status uploaded - ${AVAILABLE_SPACE}MB free"
        else
            log "⚠ Status upload failed"
        fi
        exit 0
        ;;
    --upload-historical)
        latest=$(find "${LOCAL_BACKUP_DIR}" -maxdepth 1 -type d -name "[0-9]*" | sort -r | head -1)
        run_historical_upload "$latest"
        exit $? ;;
esac

if [[ -z "${INFLUXDB_BACKUP_NO_AUTOUPDATE:-}" ]]; then
    REMOTE_VER=$(check_for_update 2>/dev/null || echo "")
    if [[ -n "$REMOTE_VER" && "$REMOTE_VER" != "$SCRIPT_VERSION" ]]; then
        log "Auto-updating to $REMOTE_VER..."
        export INFLUXDB_BACKUP_NO_AUTOUPDATE=1
        if do_update; then exec bash "$0" "$@"; else log "Auto-update failed, continuing..."; fi
    fi
fi

mkdir -p "${LOCAL_BACKUP_DIR}"
REQUIRED_MB="${REQUIRED_MB:-1000}"
AVAILABLE_SPACE=$(df -m "${LOCAL_BACKUP_DIR}" | awk 'NR==2{print$4}')
if (( AVAILABLE_SPACE < REQUIRED_MB )); then
    log "⚠ Low disk: ${AVAILABLE_SPACE}MB free, need ${REQUIRED_MB}MB"
    if bash "${SCRIPT_DIR}/cleanup.sh" 2>&1 | while IFS= read -r line; do log "[cleanup] $line"; done; then
        AVAILABLE_SPACE=$(df -m "${LOCAL_BACKUP_DIR}" | awk 'NR==2{print$4}')
        if (( AVAILABLE_SPACE < REQUIRED_MB )); then log "ERROR: Still low"; exit 1; fi
        log "✓ Cleanup complete"
    else log "ERROR: Cleanup failed"; exit 1; fi
fi
log "✓ Disk OK: ${AVAILABLE_SPACE}MB"

log "=========================================="
log "InfluxDB Backup v${SCRIPT_VERSION}"
log "Site: ${SITE_NAME}"
log "=========================================="

log "Creating backup: $(basename "$LOCAL_BACKUP_PATH")"
if ! influxd backup -portable "$LOCAL_BACKUP_PATH" >> "$LOG_FILE" 2>&1; then
    log "ERROR: InfluxDB backup failed"; rm -rf "$LOCAL_BACKUP_PATH"; exit 1
fi
log "✓ Backup created successfully"

SHARD_COUNT=$(find "$LOCAL_BACKUP_PATH" -type f ! -name "manifest" | wc -l)
BACKUP_SIZE=$(du -sm "$LOCAL_BACKUP_PATH" 2>/dev/null | awk '{print $1}')
log "Shard files: ${SHARD_COUNT}  |  Size: ${BACKUP_SIZE}MB"

# FIRST-RUN DETECTION - AFTER backup is created
if [[ ! -f "$FIRST_RUN_MARKER" ]]; then
    GCS_SHARDS=$(count_gcs_shards)
    log "First run check: GCS has $GCS_SHARDS shard files, local backup has $SHARD_COUNT"

    if (( GCS_SHARDS < SHARD_COUNT )); then
        log "⚠ First run detected - GCS missing shards, running historical upload"
        if run_historical_upload "$LOCAL_BACKUP_PATH"; then
            log "✓ Historical upload successful"
        else
            log "⚠ Historical upload failed/skipped"
        fi
    else
        log "First run: GCS has all shards"
    fi
    touch "$FIRST_RUN_MARKER"
fi

log "Identifying shards to upload (2 newest)..."

mapfile -t ALL_SHARDS < <(find "$LOCAL_BACKUP_PATH" -type f ! -name "manifest" -printf '%T@ %p\n' | sort -rn | awk '{print $2}')
UPLOAD_COUNT=${#ALL_SHARDS[@]}

TO_UPLOAD=()
for (( i=0; i<UPLOAD_COUNT && i<2; i++ )); do
    TO_UPLOAD+=("${ALL_SHARDS[$i]}")
done

log "Uploading ${#TO_UPLOAD[@]} of ${SHARD_COUNT} shard files..."

UPLOAD_TOTAL=${#TO_UPLOAD[@]}

UPLOAD_START=$(date +%s)
SYNC_TMPDIR=$(mktemp -d)
for f in "${TO_UPLOAD[@]}"; do
    cp "$f" "${SYNC_TMPDIR}/"
done

if ! rclone copy "$SYNC_TMPDIR" "${RCLONE_DEST}" --update --transfers=4 >> "$LOG_FILE" 2>&1; then
    log "ERROR: Sync to GCS failed"; rm -rf "$SYNC_TMPDIR"; exit 1
fi
rm -rf "$SYNC_TMPDIR"

UPLOAD_END=$(date +%s)
log "✓ Sync completed in $(( UPLOAD_END - UPLOAD_START ))s"

log "Verifying..."
VERIFIED=0
for f in "${TO_UPLOAD[@]}"; do
    REL_PATH="${f#${LOCAL_BACKUP_PATH}/}"
    rclone size "${RCLONE_DEST}${REL_PATH}" > /dev/null 2>&1 && ((VERIFIED++)) || true
done

if [[ "$VERIFIED" -eq "$UPLOAD_TOTAL" ]]; then
    log "✓ All ${UPLOAD_TOTAL} files verified"
else
    log "ERROR: Verification mismatch ${VERIFIED}/${UPLOAD_TOTAL}"; exit 1
fi

rm -rf "$LOCAL_BACKUP_PATH"
log "✓ Cleaned up"

find "${LOCAL_BACKUP_DIR}" -maxdepth 1 -type d -name "[0-9]*" | sort -r | tail -n +3 | xargs rm -rf 2>/dev/null || true

REMOTE_VER=$(check_for_update 2>/dev/null || echo "")
if [[ -n "$REMOTE_VER" && "$REMOTE_VER" != "$SCRIPT_VERSION" ]]; then
    log "ℹ New version available: $REMOTE_VER"
fi

STATUS_FILE="${LOCAL_BACKUP_DIR}/status.json"
cat > "$STATUS_FILE" << EOF
{"hostname":"$(hostname -s 2>/dev/null||echo unknown)","site":"${SITE_NAME}","version":"${SCRIPT_VERSION}","last_backup":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","free_mb":${AVAILABLE_SPACE},"shard_count":${SHARD_COUNT},"backup_size_mb":${BACKUP_SIZE},"upload_duration_s":$(( UPLOAD_END - UPLOAD_START ))}
EOF
log "✓ Status written"

if rclone copy "$STATUS_FILE" "${RCLONE_DEST}status.json" 2>/dev/null; then
    log "✓ Status uploaded"
fi

log "=========================================="
log "✓ Backup completed successfully"
log "=========================================="
exit 0