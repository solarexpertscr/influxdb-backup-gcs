#!/bin/bash

set -e

# Load environment variables
if [ ! -f .env ]; then
    echo "Error: .env file not found. Please run install.sh first."
    exit 1
fi

source .env

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

# Install Google Cloud SDK if not present
if ! command -v gcloud &> /dev/null; then
    log "Installing Google Cloud SDK..."
    apt-get update -qq
    apt-get install -y apt-transport-https ca-certificates gnupg curl
    
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
    
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee /etc/apt/sources.list.d/google-cloud-sdk.list
    
    apt-get update -qq
    apt-get install -y google-cloud-cli
    
    log "Google Cloud SDK installed"
else
    log "Google Cloud SDK already installed"
fi

# Authenticate with service account
log "Authenticating with GCP..."
gcloud auth activate-service-account --key-file="$KEY_FILE"

# Set project
gcloud config set project "$PROJECT_NAME"
log "Project set to: $PROJECT_NAME"

# Check if bucket exists
if gsutil ls -p "$PROJECT_NAME" | grep -q "^gs://${SITE_NAME}/$"; then
    log "Bucket gs://$SITE_NAME already exists"
else
    # Create GCS bucket
    log "Creating GCS bucket: gs://$SITE_NAME"
    gsutil mb -p "$PROJECT_NAME" "gs://$SITE_NAME"
    
    # Apply lifecycle rules
    if [ -f "lifecycle.json" ]; then
        log "Applying lifecycle rules..."
        gsutil lifecycle set lifecycle.json "gs://$SITE_NAME"
    else
        log "Warning: lifecycle.json not found, skipping lifecycle configuration"
    fi
fi

# Install cron job
CRON_CMD="$LOCAL_BACKUP_DIR/backup.sh >> $LOCAL_BACKUP_DIR/backup.log 2>&1"
CRON_SCHEDULE="0 2 * * *"

# Remove existing cron job if present
(crontab -l 2>/dev/null | grep -v "$CRON_CMD") | crontab -

# Add new cron job
(crontab -l 2>/dev/null; echo "$CRON_SCHEDULE $CRON_CMD") | crontab -

log "Cron job installed: $CRON_SCHEDULE"

# Make backup script executable
chmod +x "$LOCAL_BACKUP_DIR/backup.sh" 2>/dev/null || true

log "Setup complete!"
log "Backup will run daily at 2:00 AM"
log "Backup location: gs://$SITE_NAME"
log "Logs: $LOCAL_BACKUP_DIR/backup.log"
log "Test backup: bash $LOCAL_BACKUP_DIR/backup.sh"
