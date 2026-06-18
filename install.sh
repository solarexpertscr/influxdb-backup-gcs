#!/bin/bash

set -e

REPO="solarexpertscr/influxdb-backup-gcs"
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

# Validate service account key FIRST
KEY_PATH="/etc/solar-assistant/gcs-key.json"
KEY_DIR=$(dirname "${KEY_PATH}")

if [ ! -f "${KEY_PATH}" ]; then
    error "Service account key not found at ${KEY_PATH}
Please place your GCP service account JSON key there before running this installer."
fi

# Enforce strict permissions: 0600, owned by root
PERMS=$(stat -c %a "${KEY_PATH}" 2>/dev/null || stat -f %Lp "${KEY_PATH}")
OWNER=$(stat -c %U "${KEY_PATH}" 2>/dev/null || stat -f %Su "${KEY_PATH}")

if [ "${PERMS}" != "600" ] || [ "${OWNER}" != "root" ]; then
    log "Fixing permissive key file permissions..."
    chmod 600 "${KEY_PATH}"
    chown root:root "${KEY_PATH}" 2>/dev/null || true
fi

log "Service account key validated at: ${KEY_PATH}"

# Create script directory
mkdir -p "${SCRIPT_DIR}"
cd "${SCRIPT_DIR}"

# Download scripts from GitHub
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

log "Downloading rclone backup script..."
curl -fsSL "${BASE_URL}/backup.sh" -o backup.sh

log "Downloading rclone setup script..."
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

# Rclone remote name (configured in setup.sh)
RCLONE_REMOTE="gcs"

# Service account key file path (JSON format)
GOOGLE_APPLICATION_CREDENTIALS="/etc/solar-assistant/gcs-key.json"
EOF

log "Created .env with SITE_NAME=${SITE_NAME}"

# Make scripts executable
chmod +x backup.sh setup.sh

log "Running rclone setup..."
./setup.sh

log "Installation complete (rclone version)"
log "Backup script: ${SCRIPT_DIR}/backup.sh"
log "Setup script:  ${SCRIPT_DIR}/setup.sh"
log "Config:        ${SCRIPT_DIR}/.env"
