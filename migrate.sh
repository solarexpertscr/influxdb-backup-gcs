#!/bin/bash

# Migration script: gsutil → rclone for existing installations
# Run this on your Orange Pi to switch over and reclaim ~350MB disk space

set -e

SCRIPT_DIR="/opt/influxdb-backup-gcs"
REPO="solarexpertscr/influxdb-backup-gcs"
BRANCH="main"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo ""
echo "==========================================="
echo "  Migrate influxdb-backup-gcs: gsutil → rclone"
echo "==========================================="
echo ""

# 1. Verify old install exists
if [ ! -f "${SCRIPT_DIR}/.env" ]; then
    error "No existing installation found at ${SCRIPT_DIR}"
fi

log "Found existing installation at ${SCRIPT_DIR}"
source "${SCRIPT_DIR}/.env"
log "Site: ${SITE_NAME}"
log "Key: ${GOOGLE_APPLICATION_CREDENTIALS}"

# 2. Verify service account key still exists
if [ ! -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
    error "Service account key missing: $GOOGLE_APPLICATION_CREDENTIALS"
    error "Restore it before running this migration."
fi
log "Service account key found ✓"

# 3. Remove old cron job
log "Removing old cron job..."
OLD_CRON="$LOCAL_BACKUP_DIR/backup.sh"
(crontab -l 2>/dev/null | grep -v "$OLD_CRON" | grep -v "influxdb_backup") | crontab -
log "Old cron job removed ✓"

# 4. Remove old scripts
log "Removing old scripts..."
rm -f "${SCRIPT_DIR}/backup.sh" "${SCRIPT_DIR}/setup.sh" "${SCRIPT_DIR}/install.sh"
rm -f "${SCRIPT_DIR}/lifecycle.json" "${SCRIPT_DIR}/.env"
log "Old scripts removed ✓"

# 5. Download new scripts
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

log "Downloading new rclone-based scripts..."
curl -fsSL "${BASE_URL}/backup.sh" -o "${SCRIPT_DIR}/backup.sh"
curl -fsSL "${BASE_URL}/setup.sh" -o "${SCRIPT_DIR}/setup.sh"
curl -fsSL "${BASE_URL}/install.sh" -o "${SCRIPT_DIR}/install.sh"
curl -fsSL "${BASE_URL}/lifecycle.json" -o "${SCRIPT_DIR}/lifecycle.json"

chmod +x "${SCRIPT_DIR}/backup.sh" "${SCRIPT_DIR}/setup.sh"

# 6. Recreate .env with rclone remote name
log "Creating new .env..."
cat > "${SCRIPT_DIR}/.env" <<EOF
# Site identifier - used as GCS bucket name
SITE_NAME="${SITE_NAME}"

# Google Cloud Project name
PROJECT_NAME="${PROJECT_NAME:-solar-assistant-backups}"

# Backup prefix (used in filenames)
BACKUP_PREFIX="${BACKUP_PREFIX:-influxdb_backup}"

# Retention in days (must match lifecycle rule)
RETENTION_DAYS=${RETENTION_DAYS:-3}

# Local temp directory
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR}"

# Rclone remote name (configured in setup.sh)
RCLONE_REMOTE="gcs"

# Service account key file path (JSON format)
GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS}"
EOF

# 7. Run setup (installs rclone, configures remote, sets new cron)
log "Running setup (installs rclone + sets cron)..."
cd "${SCRIPT_DIR}"
bash setup.sh

# 8. Remove gcloud SDK to free space
echo ""
if command -v gcloud &>/dev/null; then
    warn "About to remove google-cloud-sdk to free ~350MB disk space."
    read -p "Continue? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Removing google-cloud-sdk..."
        apt-get remove --purge -y google-cloud-sdk 2>/dev/null || apt-get remove --purge -y google-cloud-cli 2>/dev/null || warn "Could not auto-remove. Manual removal:"
        warn "  apt-get remove --purge google-cloud-sdk && apt-get autoremove"
        apt-get autoremove -y 2>/dev/null
        log "gcloud removed ✓"
    else
        echo ""
        warn "Skipped. To remove later:"
        warn "  apt-get remove --purge google-cloud-sdk google-cloud-cli"
        warn "  apt-get autoremove"
    fi
else
    log "gcloud not found (already removed) ✓"
fi

# 9. Verify rclone works
echo ""
log "Verifying rclone connection..."
if rclone lsd "gcs:${SITE_NAME}" &>/dev/null; then
    log "rclone can see bucket gs://${SITE_NAME} ✓"
else
    warn "Could not verify bucket access. Test manually:"
    warn "  rclone lsd gcs:"
fi

# Done
echo ""
echo "==========================================="
echo "  Migration complete!"
echo "==========================================="
log "rclone binary:  $(du -sh $(which rclone) | cut -f1)"
log "Test backup:    bash ${SCRIPT_DIR}/backup.sh"
log "Check logs:     tail -f /var/log/influxdb-backup.log"
echo ""
