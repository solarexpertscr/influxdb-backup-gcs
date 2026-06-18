#!/bin/bash

set -e

REPO="solarexpertscr/workspace"
BRANCH="main"
SCRIPT_DIR="/opt/influxdb-backup-gcs"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Get site name from argument or prompt
SITE_NAME="${1:-}"
if [ -z "$SITE_NAME" ]; then
    read -rp "Enter site name (for bucket naming): " SITE_NAME
fi

if [ -z "$SITE_NAME" ]; then
    error "Site name is required"
fi

log "Installing InfluxDB backup for site: ${SITE_NAME}"

# Create script directory
mkdir -p "${SCRIPT_DIR}"
cd "${SCRIPT_DIR}"

# Download scripts from GitHub
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/scripts/influxdb-backup-gcs"

log "Downloading backup script..."
curl -fsSL "${BASE_URL}/backup.sh" -o backup.sh

log "Downloading setup script..."
curl -fsSL "${BASE_URL}/setup.sh" -o setup.sh

log "Downloading lifecycle config..."
curl -fsSL "${BASE_URL}/lifecycle.json" -o lifecycle.json

# Create .env from template
cat > .env <<EOF
# Site identifier - used as GCS bucket name
SITE_NAME="${SITE_NAME}"

# Google Cloud Project name
PROJECT_NAME="solar-assistant-backups"

# Backup prefix (used in filenames)
BACKUP_PREFIX="influxdb_backup"

# Retention in days (must match lifecycle rule)
RETENTION_DAYS=3

# Local temp directory
LOCAL_BACKUP_DIR="/tmp/influxdb_backup"

# Service account key file path (JSON format)
GOOGLE_APPLICATION_CREDENTIALS="/etc/solar-assistant/gcs-key.json"
EOF

log "Created .env with SITE_NAME=${SITE_NAME}"

# Make scripts executable
chmod +x backup.sh setup.sh

# Prompt for service account key
KEY_PATH="/etc/solar-assistant/gcs-key.json"
KEY_DIR=$(dirname "${KEY_PATH}")

log "Service account key required at: ${KEY_PATH}"
mkdir -p "${KEY_DIR}"

log "Service account key required at: ${KEY_PATH}"
mkdir -p "${KEY_DIR}"

log "Paste the service account JSON key content below (Ctrl+D to finish):"
cat > "${KEY_PATH}"
if [ ! -s "${KEY_PATH}" ]; then
    rm -f "${KEY_PATH}"
    error "No valid content was pasted"
fi
chmod 600 "${KEY_PATH}"
log "Service account key saved to ${KEY_PATH}"

log "Running setup..."
./setup.sh

log "Installation complete"
log "Backup script: ${SCRIPT_DIR}/backup.sh"
log "Setup script:  ${SCRIPT_DIR}/setup.sh"
log "Config:        ${SCRIPT_DIR}/.env"
