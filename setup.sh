#!/bin/bash

set -e

# Load environment variables
if [ ! -f .env ]; then
    echo "Error: .env file not found. Please run install.sh first."
    exit 1
fi

source .env

SCRIPT_DIR="/opt/influxdb-backup-gcs"

log() {
    echo -e "\033[32m[INFO]\033[0m $1"
}

error() {
    echo -e "\033[31m[ERROR]\033[0m $1"
    exit 1
}

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Validate service account key exists
KEY_FILE="/etc/solar-assistant/gcs-key.json"

if [ ! -f "$KEY_FILE" ]; then
    error "Service account key not found at $KEY_FILE"
    error "Please place your GCP service account JSON key there before running this installer."
fi

log "Service account key found at: $KEY_FILE"

# Check and enforce strict permissions
PERMS=$(stat -c %a "$KEY_FILE")
OWNER=$(stat -c %U "$KEY_FILE")

if [ "$PERMS" != "600" ] || [ "$OWNER" != "root" ]; then
    log "Fixing permissive key file permissions..."
    chmod 600 "$KEY_FILE"
    chown root:root "$KEY_FILE" 2>/dev/null || sudo chown root:root "$KEY_FILE"
    log "Permissions set to 600, owner set to root"
fi

log "Service account key validated at: $KEY_FILE"

# Setup directories
mkdir -p "$LOCAL_BACKUP_DIR"

# Install rclone if not present (~50MB single binary, vs ~400MB for google-cloud-sdk)
if ! command -v rclone &> /dev/null; then
    log "Installing rclone..."
    curl https://rclone.org/install.sh | bash
    log "rclone installed ($(du -sh $(which rclone) | cut -f1))"
else
    log "rclone already installed"
fi

# Configure rclone remote with service account
log "Configuring rclone remote: ${RCLONE_REMOTE}"

# Remove existing remote if present (to avoid conflicts)
rclone config delete "${RCLONE_REMOTE}" 2>/dev/null || true

rclone config create "${RCLONE_REMOTE}" google \
    service_account_file "$KEY_FILE"

log "rclone remote '${RCLONE_REMOTE}' configured"

# Check if bucket exists and create if needed
log "Checking if bucket gs://${SITE_NAME} exists..."
if rclone lsd "${RCLONE_REMOTE}:${SITE_NAME}" &>/dev/null; then
    log "Bucket gs://${SITE_NAME} already exists"
else
    log "Creating GCS bucket: gs://${SITE_NAME}"
    rclone mkdir "${RCLONE_REMOTE}:${SITE_NAME}"
    
    if [ $? -eq 0 ]; then
        log "Bucket created successfully"
    else
        error "Failed to create bucket. Check your service account permissions."
    fi
fi

# Note about lifecycle rules (one-time setup)
log "NOTE: To set auto-deletion after ${RETENTION_DAYS} days, apply lifecycle.json via:"
log "  GCP Console → Storage → ${SITE_NAME} → Lifecycle → Add rule"
log "  Or: gsutil lifecycle set ${SCRIPT_DIR}/lifecycle.json gs://${SITE_NAME}"

# Install cron job (use SCRIPT_DIR, not LOCAL_BACKUP_DIR which is in /tmp)
CRON_CMD="${SCRIPT_DIR}/backup.sh >> /var/log/influxdb-backup.log 2>&1"
CRON_SCHEDULE="0 2 * * *"

# Remove existing cron job if present
(crontab -l 2>/dev/null | grep -v "$CRON_CMD") | crontab -

# Add new cron job
(crontab -l 2>/dev/null; echo "$CRON_SCHEDULE $CRON_CMD") | crontab -

log "Cron job installed: $CRON_SCHEDULE"

# Make backup script executable
chmod +x "$SCRIPT_DIR/backup.sh"

log ""
log "========================================="
log " Setup complete! (rclone version)"
log "========================================="
log " rclone:  ~50MB (was ~400MB gcloud SDK)"
log " Backup:  daily at 2:00 AM"
log " Bucket:  gs://$SITE_NAME"
log " Logs:    /var/log/influxdb-backup.log"
log " Test:    bash $SCRIPT_DIR/backup.sh"
log "========================================="
