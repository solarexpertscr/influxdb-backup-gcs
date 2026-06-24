#!/bin/bash

set -euo pipefail

# ============================================================================
# Install Script — InfluxDB Shard-Based Backup to GCS
# ============================================================================
# Downloads backup.sh, restore.sh, setup.sh, lifecycle.json from GitHub,
# creates .env, then runs setup.sh to configure rclone and cron.
# ============================================================================

INSTALL_DIR="/opt/influxdb-backup-gcs"
GITHUB_RAW_URL="https://raw.githubusercontent.com/solarexpertscr/influxdb-backup-gcs/main"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ---------------------------------------------------------------------------
# Determine SITE_NAME
# ---------------------------------------------------------------------------

if [[ $# -gt 0 ]]; then
    SITE_NAME="$1"
    log "Using site name from argument: ${SITE_NAME}"
elif [[ -f "${INSTALL_DIR}/.env" ]]; then
    SITE_NAME=$(grep "^SITE_NAME=" "${INSTALL_DIR}/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "")
    if [[ -z "${SITE_NAME}" ]]; then
        log_error "No site name provided and no valid .env found"
        log_error "Usage: bash install.sh <sitename>"
    fi
else
    log_error "No site name provided"
    log_error "Usage: bash install.sh <sitename>"
fi

# ---------------------------------------------------------------------------
# Pre-checks
# ---------------------------------------------------------------------------

if ! command -v curl &> /dev/null; then
    log_error "curl is required but not installed. Install curl first, then re-run."
fi

# ---------------------------------------------------------------------------
# Create install directory
# ---------------------------------------------------------------------------

sudo mkdir -p "$INSTALL_DIR"
sudo chown "$(id -u):$(id -g)" "$INSTALL_DIR" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Download scripts (backup.sh, restore.sh, setup.sh, lifecycle.json)
# ---------------------------------------------------------------------------

download() {
    local filename="$1"
    log "Downloading ${filename}..."
    if curl -fsSL "${GITHUB_RAW_URL}/${filename}" -o "${INSTALL_DIR}/${filename}"; then
        chmod +x "${INSTALL_DIR}/${filename}"
        log "✓ ${filename} downloaded"
    else
        log_error "Failed to download ${filename}"
    fi
}

download "backup.sh"
download "restore.sh"
download "setup.sh"

curl -fsSL "${GITHUB_RAW_URL}/cleanup.sh" -o "${INSTALL_DIR}/cleanup.sh" 2>/dev/null && \
    chmod +x "${INSTALL_DIR}/cleanup.sh" && \
    log "✓ cleanup.sh downloaded" || \
    log "⚠ Warning: cleanup.sh download failed (not critical)"

log "Downloading lifecycle.json..."
if curl -fsSL "${GITHUB_RAW_URL}/lifecycle.json" -o "${INSTALL_DIR}/lifecycle.json"; then
    log "✓ lifecycle.json downloaded"
else
    warn "Failed to download lifecycle.json (lifecycle rule will need manual setup)"
fi

# ---------------------------------------------------------------------------
# .env configuration
# ---------------------------------------------------------------------------

ENV_FILE="${INSTALL_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    log ".env configuration file not found - creating new one..."

    cat > "$ENV_FILE" <<EOF
# ============================================================================
# InfluxDB Shard-Based Backup Configuration
# ============================================================================

# Site identifier (used as GCS bucket name and log prefix)
SITE_NAME="${SITE_NAME}"

# Rclone remote name (set up by setup.sh)
RCLONE_REMOTE_NAME="gcs"

# Local temp directory for backup staging
LOCAL_BACKUP_DIR="/var/lib/influxdb-backup/${SITE_NAME}"

# Minimum free disk space (MB) required before running backup
REQUIRED_MB=1000

# GCP service account key (used by setup.sh)
GOOGLE_APPLICATION_CREDENTIALS="/etc/solar-assistant/gcs-key.json"

# Log file
LOG_FILE="/var/log/influxdb-backup.log"
EOF

    log "✓ .env created"
    log "  SITE_NAME:              ${SITE_NAME}"
    log "  LOCAL_BACKUP_DIR:       /var/lib/influxdb-backup/${SITE_NAME}"
    log "  GOOGLE_APPLICATION_CREDENTIALS: /etc/solar-assistant/gcs-key.json"
else
    log ".env file found - preserving existing configuration"
    if [[ -f "$ENV_FILE" ]]; then
        source "$ENV_FILE" 2>/dev/null || true
        log "  SITE_NAME:      ${SITE_NAME:-not set}"
        log "  LOCAL_BACKUP_DIR: ${LOCAL_BACKUP_DIR:-not set}"
    fi
fi

chmod 600 "$ENV_FILE"

# ---------------------------------------------------------------------------
# Install Tailscale (if not already present)
# ---------------------------------------------------------------------------

if ! command -v tailscale &> /dev/null; then
    log "Installing Tailscale..."
    if sudo curl -fsSL https://tailscale.com/install.sh | sudo sh; then
        log "✓ Tailscale installed"
    else
        warn "Tailscale installation failed - install manually later if needed"
    fi
else
    log "Tailscale already installed: $(tailscale version | head -1)"
fi

# ---------------------------------------------------------------------------
# Run setup.sh (rclone config, bucket creation, lifecycle, cron)
# ---------------------------------------------------------------------------

log "Running rclone and system configuration..."
cd "$INSTALL_DIR"
if bash "${INSTALL_DIR}/setup.sh"; then
    log "✓ setup.sh completed"
else
    warn "setup.sh encountered issues - review output above and re-run manually:"
    warn "  sudo bash ${INSTALL_DIR}/setup.sh"
fi

# ---------------------------------------------------------------------------
# Test backup
# ---------------------------------------------------------------------------

log ""
log "Running initial backup test..."
if bash "${INSTALL_DIR}/backup.sh"; then
    log "✓ Initial backup test successful"
else
    warn "Initial backup test failed - check /var/log/influxdb-backup.log"
    warn "Run manually: bash ${INSTALL_DIR}/backup.sh"
fi

# ---------------------------------------------------------------------------
# Verify cron jobs are installed
# ---------------------------------------------------------------------------

log "Verifying cron jobs..."
CRON_CONTENT=$(crontab -l 2>/dev/null || echo "")
CRON_ENTRIES=0
if [[ -n "$CRON_CONTENT" ]]; then
    CRON_ENTRIES=$(echo "$CRON_CONTENT" | grep -c "${INSTALL_DIR}" || true)
fi
if [[ "${CRON_ENTRIES}" -ge 4 ]]; then
    log "✓ Cron jobs installed (${CRON_ENTRIES} entries)"
else
    warn "⚠ Cron jobs missing or incomplete (found ${CRON_ENTRIES}, expected 4)"
    warn "Re-run setup: sudo bash ${INSTALL_DIR}/setup.sh"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

log ""
log "========================================="
log " Installation complete"
log "========================================="
log " Install dir:  ${INSTALL_DIR}"
log " Config:       ${ENV_FILE}"
log " Backup:       ${INSTALL_DIR}/backup.sh"
log " Restore:      ${INSTALL_DIR}/restore.sh"
log " Schedule:     Daily at 2:00 AM"
log " Auto-update:  Sunday 3:00 AM"
log " Logs:         /var/log/influxdb-backup.log"
log "========================================="

exit 0
