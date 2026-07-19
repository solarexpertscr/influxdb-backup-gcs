#!/bin/bash

set -euo pipefail

# ============================================================================
# Setup Script for InfluxDB Shard-Based Backup to GCS
# ============================================================================
# Configures rclone, creates the GCS bucket, and installs cron jobs.
# Called by install.sh or run standalone.
# ============================================================================

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error(){ echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

SCRIPT_DIR="/opt/influxdb-backup-gcs"

# Load environment variables if .env exists (created by install.sh)
if [ ! -f "${SCRIPT_DIR}/.env" ]; then
    # Fall back to local .env if running standalone
    if [ -f "./.env" ]; then
        SCRIPT_DIR="$(pwd)"
    else
        error ".env file not found. Run install.sh first, or provide a .env file."
    fi
fi

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/.env"

# ---------------------------------------------------------------------------
# Resolve RCLONE_REMOTE
# ---------------------------------------------------------------------------

if [[ -n "${RCLONE_REMOTE_NAME:-}" ]]; then
    RCLONE_REMOTE="${RCLONE_REMOTE_NAME}"
elif [[ -z "${RCLONE_REMOTE:-}" ]]; then
    RCLONE_REMOTE="gcs"
fi

# ---------------------------------------------------------------------------
# Validate service account key
# ---------------------------------------------------------------------------

KEY_FILE="${GOOGLE_APPLICATION_CREDENTIALS:-/etc/solar-assistant/gcs-key.json}"

if [ ! -f "$KEY_FILE" ]; then
    error "Service account key not found at $KEY_FILE"
fi

log "Service account key found at: $KEY_FILE"

# Enforce strict permissions
PERMS=$(stat -c %a "$KEY_FILE")
OWNER=$(stat -c %U "$KEY_FILE" 2>/dev/null || stat -f %Su "$KEY_FILE" 2>/dev/null)

if [ "$PERMS" != "600" ] || [ "$OWNER" != "root" ]; then
    log "Fixing permissive key file permissions..."
    chmod 600 "$KEY_FILE"
    chown root:root "$KEY_FILE" 2>/dev/null || sudo chown root:root "$KEY_FILE"
    log "Permissions set to 600, owner set to root"
fi

log "Service account key validated at: $KEY_FILE"

# ---------------------------------------------------------------------------
# Setup directories
# ---------------------------------------------------------------------------

mkdir -p "$LOCAL_BACKUP_DIR"

# ---------------------------------------------------------------------------
# Install rclone if not present (~20MB single binary)
# ---------------------------------------------------------------------------

if ! command -v rclone &> /dev/null; then
    log "Installing rclone..."
    if ! command -v unzip &> /dev/null; then
        log "Installing unzip (required by rclone installer)..."
        apt-get update -qq
        apt-get install -yqq unzip
    fi
    curl https://rclone.org/install.sh | bash
    log "rclone installed ($(du -sh "$(which rclone)" | awk '{print $1}'))"
else
    log "rclone already installed: $(rclone version | head -1 | awk '{print $2}')"
fi

# ---------------------------------------------------------------------------
# Configure rclone remote
# ---------------------------------------------------------------------------

export RCLONE_CONFIG="/etc/rclone.conf"

log "Configuring rclone remote: ${RCLONE_REMOTE}"

# Remove existing remote if present (avoid conflicts)
rclone config delete "${RCLONE_REMOTE}" 2>/dev/null || true

rclone config create "${RCLONE_REMOTE}" "google cloud storage" \
    service_account_file "$KEY_FILE" \
    bucket_policy_only "true"

log "rclone remote '${RCLONE_REMOTE}' configured"

# ---------------------------------------------------------------------------
# Create GCS bucket (if needed)
# ---------------------------------------------------------------------------

log "Checking if bucket gs://${SITE_NAME} exists..."
if rclone lsd "${RCLONE_REMOTE}:${SITE_NAME}" &>/dev/null; then
    log "Bucket gs://${SITE_NAME} already exists"
else
    log "Creating GCS bucket: gs://${SITE_NAME}"
    if rclone mkdir "${RCLONE_REMOTE}:${SITE_NAME}"; then
        log "Bucket created successfully"
    else
        error "Failed to create bucket. Verify service account permissions (storage.buckets.create)."
    fi
fi

# ---------------------------------------------------------------------------
# Install cron jobs
# ---------------------------------------------------------------------------

log "Setting up cron jobs..."

BACKUP_CMD="${SCRIPT_DIR}/backup.sh >> /var/log/influxdb-backup.log 2>&1"
AUTOUPDATE_CMD="${SCRIPT_DIR}/backup.sh --auto-update >> /var/log/influxdb-backup.log 2>&1"
CLEANUP_CMD="${SCRIPT_DIR}/cleanup.sh >> /var/log/influxdb-backup.log 2>&1"
STATUS_CMD="${SCRIPT_DIR}/backup.sh --status-only >> /var/log/influxdb-backup.log 2>&1"

# Remove any existing entries for this script
(crontab -l 2>/dev/null | grep -v "${SCRIPT_DIR}/backup.sh" | grep -v "${SCRIPT_DIR}/cleanup.sh") | crontab -

# Add new entries
crontab_line() {
    (crontab -l 2>/dev/null; echo "$1") | crontab -
}

# Daily backup: 2 AM
crontab_line "0 2 * * * ${BACKUP_CMD}"

# Weekly auto-update of backup script: Sunday 3 AM
crontab_line "0 3 * * 0 ${AUTOUPDATE_CMD}"

# Daily cleanup: 4 AM
crontab_line "0 4 * * * ${CLEANUP_CMD}"

# Hourly status upload
crontab_line "0 * * * * ${STATUS_CMD}"

log "✓ Cron jobs installed:"
log "  - Daily backup:       0 2 * * *"
log "  - Weekly auto-update: 0 3 * * 0"
log "  - Daily cleanup:      0 4 * * *"
log "  - Hourly status:      0 * * * *"

# ---------------------------------------------------------------------------
# Permissions
# ---------------------------------------------------------------------------

chmod +x "${SCRIPT_DIR}/backup.sh"
chmod +x "${SCRIPT_DIR}/restore.sh" 2>/dev/null || true

# rclone config stores a reference to the key path — readable allows root cron jobs
chmod 644 "${RCLONE_CONFIG}"

# ---------------------------------------------------------------------------
# Done
# ============================================================================

log ""
log "========================================="
log " Setup complete (shard-based backup)"
log "========================================="
log " rclone:  lightweight single-binary transport"
log " Strategy: upload changed shards only"
log "          frozen shards uploaded once, active shard updated daily"
log " Bucket:  gs://${SITE_NAME}"
log " Backup:  daily at 2:00 AM"
log " Logs:    /var/log/influxdb-backup.log"
log ""
log " Manual backup test:"
log "   bash ${SCRIPT_DIR}/backup.sh"
log " Restore from GCS:"
log "   bash ${SCRIPT_DIR}/restore.sh"
log " Dry-run restore:"
log "   bash ${SCRIPT_DIR}/restore.sh --dry-run"
log " List backups on GCS:"
log "   bash ${SCRIPT_DIR}/restore.sh --list"
log "========================================="
