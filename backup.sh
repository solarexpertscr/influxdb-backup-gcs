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

# Export GCS credentials
export GOOGLE_APPLICATION_CREDENTIALS

# Derived values
GCS_BUCKET="gs://${SITE_NAME}"
TIMESTAMP=$(date +%Y%m%d%H%M%S)
BACKUP_NAME="${BACKUP_PREFIX}_${SITE_NAME}_${TIMESTAMP}"
LOCAL_BACKUP_PATH="${LOCAL_BACKUP_DIR}/${BACKUP_NAME}"

# Create log file if it doesn't exist (for cron runs)
LOG_FILE="/var/log/influxdb-backup.log"
if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE" 2>/dev/null || true
fi

# Create temporary local backup directory
mkdir -p "${LOCAL_BACKUP_DIR}"

echo "[$(date)] Starting InfluxDB backup for ${SITE_NAME}..."

# Activate service account (ensures auth is fresh)
if [ -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
    gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
fi

# Execute InfluxDB backup to local temp directory
influxd backup -portable "${LOCAL_BACKUP_PATH}"

# Check if backup was successful
if [ ! -d "${LOCAL_BACKUP_PATH}" ]; then
    echo "[$(date)] ERROR: Backup failed. Aborting upload."
    rm -rf "${LOCAL_BACKUP_DIR}"
    exit 1
fi

echo "[$(date)] Backup created successfully. Uploading to GCS..."

# Compress backup to a single archive
cd "${LOCAL_BACKUP_DIR}"
tar -czf "${BACKUP_NAME}.tar.gz" "${BACKUP_NAME}"

# Upload to GCS
gsutil cp "${LOCAL_BACKUP_DIR}/${BACKUP_NAME}.tar.gz" "${GCS_BUCKET}/${BACKUP_NAME}.tar.gz"

echo "[$(date)] Backup uploaded to ${GCS_BUCKET}/${BACKUP_NAME}.tar.gz"

# Cleanup local temporary files
rm -rf "${LOCAL_BACKUP_DIR}"
echo "[$(date)] Local temporary files cleaned up"

echo "[$(date)] Backup completed successfully for ${SITE_NAME}"
