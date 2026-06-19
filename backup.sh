#!/bin/bash

set -euo pipefail

# Set PATH explicitly for cron compatibility
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Load environment
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "[$(date)] ERROR: Environment file not found: $ENV_FILE"
    exit 1
fi
source "$ENV_FILE"

# Use shared rclone config (set during setup.sh)
export RCLONE_CONFIG="/etc/rclone.conf"

# Derived values
GCS_BUCKET="gs://${SITE_NAME}"
RCLONE_DEST="${RCLONE_REMOTE}:${SITE_NAME}"
TIMESTAMP=$(date +%Y%m%d%H%M%S)
BACKUP_NAME="${BACKUP_PREFIX}_${SITE_NAME}_${TIMESTAMP}"
LOCAL_BACKUP_PATH="${LOCAL_BACKUP_DIR}/${BACKUP_NAME}"

# Create log file if it doesn't exist (for cron runs)
LOG_FILE="/var/log/influxdb-backup.log"
if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE" 2>/dev/null || true
fi

# Check available disk space before starting
REQUIRED_MB=500
mkdir -p "${LOCAL_BACKUP_DIR}"
AVAILABLE_MB=$(df -m "${LOCAL_BACKUP_DIR}" | awk 'NR==2 {print $4}')
if [[ "$AVAILABLE_MB" -lt "$REQUIRED_MB" ]]; then
    echo "[$(date)] ERROR: Insufficient disk space. Need ${REQUIRED_MB}MB, have ${AVAILABLE_MB}MB available in ${LOCAL_BACKUP_DIR}"
    exit 1
fi
echo "[$(date)] Disk space check passed: ${AVAILABLE_MB}MB available"

echo "[$(date)] Starting InfluxDB backup for ${SITE_NAME}..."

# Execute InfluxDB backup to local temp directory
influxd backup -portable "${LOCAL_BACKUP_PATH}" 2>&1 | tee -a "$LOG_FILE"

# Check if backup was successful
if [ ! -d "${LOCAL_BACKUP_PATH}" ]; then
    echo "[$(date)] ERROR: Backup creation failed. Local files preserved in ${LOCAL_BACKUP_DIR}"
    exit 1
fi

echo "[$(date)] Backup created successfully at ${LOCAL_BACKUP_PATH}"

# Clean orphaned old backups (from previous failed runs) BEFORE tar/upload
# Keep only the current BACKUP_NAME directory
ORPHAN_COUNT=0
for old_backup in "${LOCAL_BACKUP_DIR}"/*/; do
    [ -d "$old_backup" ] || continue  # skip if no subdirectories
    old_name="$(basename "$old_backup")"
    if [[ "$old_name" != "$BACKUP_NAME" ]]; then
        echo "[$(date)] Removing orphaned backup from previous run: $old_name"
        rm -rf "$old_backup"
        ((ORPHAN_COUNT++)) || true
    fi
done
if [[ "$ORPHAN_COUNT" -gt 0 ]]; then
    echo "[$(date)] Cleaned up $ORPHAN_COUNT orphaned backup(s)"
fi

echo "[$(date)] Compressing backup..."
cd "${LOCAL_BACKUP_DIR}"
tar -czf "${BACKUP_NAME}.tar.gz" "${BACKUP_NAME}"

# Upload to GCS via rclone
echo "[$(date)] Uploading to GCS..."
rclone copy "${LOCAL_BACKUP_DIR}/${BACKUP_NAME}.tar.gz" "${RCLONE_DEST}/${BACKUP_NAME}.tar.gz" 2>&1 | tee -a "$LOG_FILE"

# Verify upload by checking if file exists on remote
if ! rclone ls "${RCLONE_DEST}" --include="${BACKUP_NAME}.tar.gz" | grep -q "${BACKUP_NAME}.tar.gz"; then
    echo "[$(date)] ERROR: Upload verification failed. Local backup preserved at ${LOCAL_BACKUP_DIR}"
    exit 1
fi
echo "[$(date)] Upload verified: ${GCS_BUCKET}/${BACKUP_NAME}.tar.gz"

# Cleanup local temporary files after successful upload
rm -rf "${LOCAL_BACKUP_DIR}"
echo "[$(date)] Local temporary files cleaned up"

echo "[$(date)] Backup completed successfully for ${SITE_NAME}"
