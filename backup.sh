#!/bin/bash
set -euo pipefail

SCRIPT_VERSION="4.0.0"
GITHUB_RAW_URL="https://raw.githubusercontent.com/solarexpertscr/workspace/main/influxdb-backup-gcs/backup.sh"
GITHUB_PAT_FILE="${SCRIPT_DIR}/.github-pat"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export RCLONE_CONFIG="/etc/rclone.conf"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "[$(date)] ERROR: Environment file not found: $ENV_FILE"
    exit 1
fi
source "$ENV_FILE"

# Load GitHub PAT for authenticated requests to the private workspace repo.
# The PAT is downloaded by install.sh from GCS and stored in .github-pat
# (chmod 600). It is a fine-grained PAT with read-only access to the
# solarexpertscr/workspace repo. The PAT is never hardcoded in the script.
GITHUB_PAT=""
if [ -f "$GITHUB_PAT_FILE" ]; then
    GITHUB_PAT=$(cat "$GITHUB_PAT_FILE" 2>/dev/null)
fi

GCS_BUCKET="gs://${SITE_NAME}"
RCLONE_REMOTE_NAME="${RCLONE_REMOTE_NAME:-gcs}"
RCLONE_DEST="${RCLONE_REMOTE_NAME}:${SITE_NAME}/influxdb/"
TIMESTAMP=$(date +%Y%m%d%H%M%S)
LOCAL_BACKUP_PATH="${LOCAL_BACKUP_DIR}/${TIMESTAMP}"

# Lock file prevents concurrent historical uploads
LOCK_FILE="/var/lock/influxdb-backup-historical.lock"
# Marker file: persists the "first run complete" state
FIRST_RUN_MARKER="${LOCAL_BACKUP_DIR}/.first_run_complete"

LOG_FILE="/var/log/influxdb-backup.log"
if [[ ! -f "$LOG_FILE" ]]; then
    touch "$LOG_FILE" 2>/dev/null || true
fi

log() { echo "[$(date)] $1" | tee -a "$LOG_FILE"; }

check_for_update() {
    local temp_script; temp_script=$(mktemp)
    if curl -fsSL -H "Authorization: token ${GITHUB_PAT}" "$GITHUB_RAW_URL" -o "$temp_script" 2>/dev/null; then
        local remote_version; remote_version=$(grep '^SCRIPT_VERSION=' "$temp_script" | head -1 | sed 's/.*"\(.*\)".*/\1/')
        rm -f "$temp_script"; echo "$remote_version"; return 0
    fi; rm -f "$temp_script"; return 1
}

do_update() {
    local temp_script; temp_script=$(mktemp); log "Checking for updates..."
    if ! curl -fsSL -H "Authorization: token ${GITHUB_PAT}" "$GITHUB_RAW_URL" -o "$temp_script"; then log "ERROR: Failed to download"; rm -f "$temp_script"; return 1; fi
    local remote_version; remote_version=$(grep '^SCRIPT_VERSION=' "$temp_script" | head -1 | sed 's/.*"\(.*\)".*/\1/')
    if [[ -z "$remote_version" ]]; then log "ERROR: No version tag"; rm -f "$temp_script"; return 1; fi
    if [[ "$remote_version" == "$SCRIPT_VERSION" ]]; then log "Up to date: $SCRIPT_VERSION"; rm -f "$temp_script"; return 0; fi
    log "New version: $remote_version (current: $SCRIPT_VERSION)"
    if ! bash -n "$temp_script"; then log "ERROR: Syntax errors"; rm -f "$temp_script"; return 1; fi
    local backup_file="${SCRIPT_DIR}/backup.sh.bak.$(date +%Y%m%d_%H%M%S)"
    cp "${SCRIPT_DIR}/backup.sh" "$backup_file"; log "Backup: $(basename "$backup_file")"
    if ! cp "$temp_script" "${SCRIPT_DIR}/backup.sh"; then log "ERROR: Failed install"; cp "$backup_file" "${SCRIPT_DIR}/backup.sh" 2>/dev/null || true; return 1; fi
    chmod +x "${SCRIPT_DIR}/backup.sh"; rm -f "$temp_script"; log "✓ Updated to $remote_version"
}

# Count shard tar.gz files in GCS (s*.tar.gz format, NOT old date-prefixed ones)
count_gcs_shards() {
    local shard_count
    shard_count=$(rclone lsjson "${RCLONE_DEST}" --files-only --max-depth 1 2>/dev/null | \
        python3 -c "
import json,sys
data=json.load(sys.stdin)
names=[f['Name'] for f in data]
# New format: s1.tar.gz, s2.tar.gz, ... s103.tar.gz (no 'T', no date prefix)
count = sum(1 for n in names if n.startswith('s') and n.endswith('.tar.gz') and 'T' not in n and n[1:-7].isdigit())
print(count)
" 2>/dev/null || echo "0")
    echo "$shard_count"
}

# Count local shard tar.gz files in most recent backup dir
count_local_shards() {
    local latest_backup
    latest_backup=$(find "${LOCAL_BACKUP_DIR}" -maxdepth 1 -type d -name "[0-9]*" | sort -r | head -1)
    if [[ -z "$latest_backup" ]]; then
        echo "0"
        return
    fi
    find "$latest_backup" -type f -name "s*.tar.gz" | wc -l
}

# Cleanup old-format files from GCS
# Old format: 20260701T020003Z.s1.tar.gz (has 'T' in name from old script)
# New format: s1.tar.gz (no date prefix, no 'T')
# Also cleans up bare numeric shard files (00001, 00002, etc.) from even older format
cleanup_old_gcs_format() {
    log "Checking for old-format GCS files to clean up..."
    local old_files
    old_files=$(rclone lsjson "${RCLONE_DEST}" --files-only --max-depth 1 2>/dev/null | \
        python3 -c "
import json,sys
data=json.load(sys.stdin)
names=[f['Name'] for f in data]
old = []
for n in names:
    # Old dated tar.gz format (e.g. 20260701T020003Z.s1.tar.gz)
    if n.endswith('.tar.gz') and 'T' in n:
        old.append(n)
    # Ancient bare numeric shard format (00001, 00002, etc.)
    elif n.isdigit() and len(n) == 5:
        old.append(n)
    # Old bare manifest
    elif n == 'manifest':
        old.append(n)
print(' '.join(old))
" 2>/dev/null || echo "")

    if [[ -n "$old_files" ]]; then
        local count
        count=$(echo "$old_files" | wc -w)
        log "Found $count old-format files, deleting..."
        echo "$old_files" | tr ' ' '\n' | while IFS= read -r f; do
            [[ -n "$f" ]] && rclone deletefile "${RCLONE_DEST}${f}" 2>/dev/null && log "  Deleted: $f"
        done
        log "✓ Old-format cleanup complete ($count files removed)"
    else
        log "No old-format files found"
    fi
}

# Run first-run / recovery: upload all shard archives from latest local backup
run_historical_upload() {
    # Lock check
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_age
        lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0) ))
        if (( lock_age < 3600 )); then
            log "Historical upload already in progress (lock age: ${lock_age}s), skipping"
            return 1
        else
            log "Stale lock found (${lock_age}s old), removing"
            rm -f "$LOCK_FILE"
        fi
    fi

    # Acquire lock
    trap "rm -f '$LOCK_FILE'" EXIT
    echo "$$ $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCK_FILE"

    log "=========================================="
    log "HISTORICAL UPLOAD MODE"
    log "=========================================="

    # Find most recent backup directory
    local latest_backup
    latest_backup=$(find "${LOCAL_BACKUP_DIR}" -maxdepth 1 -type d -name "[0-9]*" | sort -r | head -1)

    if [[ -z "$latest_backup" || ! -d "$latest_backup" ]]; then
        log "ERROR: No local backup directory found in ${LOCAL_BACKUP_DIR}"
        rm -f "$LOCK_FILE"
        return 1
    fi

    local total_shards
    total_shards=$(find "$latest_backup" -type f -name "s*.tar.gz" | wc -l)
    log "Local backup: $(basename "$latest_backup") with $total_shards shard archives"

    # Get list of shard archives already in GCS (egress check!)
    local gcs_shard_names
    gcs_shard_names=$(rclone lsjson "${RCLONE_DEST}" --files-only --max-depth 1 2>/dev/null | \
        python3 -c "
import json,sys
data=json.load(sys.stdin)
names = [f['Name'] for f in data if f['Name'].startswith('s') and f['Name'].endswith('.tar.gz') and 'T' not in f['Name']]
print(' '.join(names))
" 2>/dev/null || echo "")

    # Build list of shard archives to upload (skip ones already in GCS)
    local to_upload=()
    local skipped=0
    while IFS= read -r shard_file; do
        local shard_name
        shard_name=$(basename "$shard_file")
        if echo " $gcs_shard_names " | grep -q " $shard_name "; then
            ((skipped++)) || true
        else
            to_upload+=("$shard_file")
        fi
    done < <(find "$latest_backup" -type f -name "s*.tar.gz")

    log "Already in GCS: $skipped | Need to upload: ${#to_upload[@]}"

    if [[ ${#to_upload[@]} -eq 0 ]]; then
        log "All shard archives already in GCS - no upload needed"
        # Still cleanup old format
        cleanup_old_gcs_format
        touch "$FIRST_RUN_MARKER"
        rm -f "$LOCK_FILE"
        return 0
    fi

    # Upload only missing shard archives
    log "Uploading ${#to_upload[@]} missing shard archives..."
    local SYNC_TMPDIR
    SYNC_TMPDIR=$(mktemp -d)
    for f in "${to_upload[@]}"; do
        cp "$f" "${SYNC_TMPDIR}/"
    done

    local UPLOAD_START UPLOAD_END
    UPLOAD_START=$(date +%s)
    if ! rclone copy "$SYNC_TMPDIR" "${RCLONE_DEST}" --update --transfers=4 --no-check-dest >> "$LOG_FILE" 2>&1; then
        log "ERROR: Historical sync failed"
        rm -rf "$SYNC_TMPDIR"
        rm -f "$LOCK_FILE"
        return 1
    fi
    rm -rf "$SYNC_TMPDIR"
    UPLOAD_END=$(date +%s)
    log "✓ Historical upload completed in $(( UPLOAD_END - UPLOAD_START ))s"

    # Cleanup old-format files
    cleanup_old_gcs_format

    # Mark first run complete
    touch "$FIRST_RUN_MARKER"
    log "✓ Historical upload finished, marker set"

    rm -f "$LOCK_FILE"
    return 0
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
    --upload-historical) run_historical_upload; exit $? ;;
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

# ============================================================================
# FIRST RUN DETECTION
# If first_run marker doesn't exist OR GCS shard count < local shard count,
# run historical upload before normal backup to ensure no data is lost
# ============================================================================
if [[ ! -f "$FIRST_RUN_MARKER" ]]; then
    LOCAL_SHARDS=$(count_local_shards)
    GCS_SHARDS=$(count_gcs_shards)
    log "First run check: local=$LOCAL_SHARDS shard archives, gcs=$GCS_SHARDS shard archives"

    if (( GCS_SHARDS < LOCAL_SHARDS )); then
        log "⚠ First run detected - GCS missing shards, running historical upload"
        if run_historical_upload; then
            log "✓ Historical upload successful, continuing with normal backup"
        else
            log "⚠ Historical upload failed/skipped, continuing with normal backup"
        fi
    else
        log "First run: GCS has all shards, marking complete"
        touch "$FIRST_RUN_MARKER"
    fi
fi

log "=========================================="
log "InfluxDB Backup v${SCRIPT_VERSION}"
log "Site: ${SITE_NAME}"
log "=========================================="

log "Creating backup: $(basename "$LOCAL_BACKUP_PATH")"
if ! influxd backup -portable "$LOCAL_BACKUP_PATH" >> "$LOG_FILE" 2>&1; then
    log "ERROR: InfluxDB backup failed"; rm -rf "$LOCAL_BACKUP_PATH"; exit 1
fi
log "✓ Backup created successfully"

# Count tar.gz shard archives (s*.tar.gz format)
SHARD_COUNT=$(find "$LOCAL_BACKUP_PATH" -type f -name "s*.tar.gz" | wc -l)
BACKUP_SIZE=$(du -sm "$LOCAL_BACKUP_PATH" 2>/dev/null | awk '{print $1}')
log "Shard archives: ${SHARD_COUNT}  |  Size: ${BACKUP_SIZE}MB"

log "Identifying archives to upload (2 newest)..."

mapfile -t ALL_SHARDS < <(find "$LOCAL_BACKUP_PATH" -type f -name "s*.tar.gz" -printf '%T@ %p\n' | sort -rn | awk '{print $2}')
UPLOAD_COUNT=${#ALL_SHARDS[@]}

TO_UPLOAD=()
for (( i=0; i<UPLOAD_COUNT && i<2; i++ )); do
    TO_UPLOAD+=("${ALL_SHARDS[$i]}")
done

UPLOAD_MANIFEST=false

# Calculate upload total
if $UPLOAD_MANIFEST; then
    UPLOAD_TOTAL=$(( ${#TO_UPLOAD[@]} + 1 ))
else
    UPLOAD_TOTAL=${#TO_UPLOAD[@]}
fi
log "Archives to upload: ${#TO_UPLOAD[@]} of ${SHARD_COUNT} total"

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

# Cleanup old-format files from GCS after successful upload
cleanup_old_gcs_format

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
