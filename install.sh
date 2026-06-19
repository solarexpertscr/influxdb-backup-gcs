#!/bin/bash

set -euo pipefail

# ============================================================================
# Install Script for InfluxDB Backup to GCS
# ============================================================================
# This script downloads the backup.sh script, creates an .env configuration
# file if it doesn't exist, sets up cron jobs, and validates the installation.
# ============================================================================

INSTALL_DIR="/opt/influxdb-backup-gcs"
GITHUB_REPO="https://raw.githubusercontent.com/solarexpertscr/influxdb-backup-gcs/main"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ============================================================================
# Installation Main Logic
# ============================================================================

# Check for GitHub CLI or curl
if ! command -v curl &> /dev/null; then
    log_error "curl is required but not installed"
    exit 1
fi

# Determine SITE_NAME from argument or existing .env
if [[ $# -gt 0 ]]; then
    SITE_NAME="$1"
    log_info "Using site name from argument: ${SITE_NAME}"
elif [[ -f "${INSTALL_DIR}/.env" ]]; then
    # Read existing .env to get SITE_NAME
    SITE_NAME=$(grep "^SITE_NAME=" "${INSTALL_DIR}/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "")
    if [[ -n "$SITE_NAME" ]]; then
        log_info "Found existing .env, using SITE_NAME: ${SITE_NAME}"
    else
        log_error "No site name provided and existing .env is invalid"
        log_error "Usage: sudo bash install.sh [sitename]"
        exit 1
    fi
else
    log_error "No site name provided and no existing .env found"
    log_error "Usage: sudo bash install.sh [sitename]"
    exit 1
fi

log_info "Installing InfluxDB Backup to GCS..."
log_info "Site: ${SITE_NAME}"

# Create installation directory
sudo mkdir -p "$INSTALL_DIR"
sudo chown "$USER:$USER" "$INSTALL_DIR"

# ============================================================================
# Download backup.sh
# ============================================================================

log_info "Downloading backup.sh from GitHub..."
if curl -fsSL "${GITHUB_REPO}/backup.sh" -o "${INSTALL_DIR}/backup.sh"; then
    log_info "✓ backup.sh downloaded successfully"
else
    log_error "Failed to download backup.sh"
    exit 1
fi

chmod +x "${INSTALL_DIR}/backup.sh"

# Download setup.sh for rclone configuration
log_info "Downloading setup.sh from GitHub..."
if curl -fsSL "${GITHUB_REPO}/setup.sh" -o "${INSTALL_DIR}/setup.sh"; then
    log_info "✓ setup.sh downloaded successfully"
else
    log_error "Failed to download setup.sh"
    exit 1
fi

chmod +x "${INSTALL_DIR}/setup.sh"

# Download lifecycle configuration
log_info "Downloading lifecycle.json from GitHub..."
if curl -fsSL "${GITHUB_REPO}/lifecycle.json" -o "${INSTALL_DIR}/lifecycle.json"; then
    log_info "✓ lifecycle.json downloaded successfully"
else
    log_error "Failed to download lifecycle.json"
    exit 1
fi

# ============================================================================
# Configure .env file
# ============================================================================

ENV_FILE="${INSTALL_DIR}/.env"

# Check if .env file exists
if [[ ! -f "$ENV_FILE" ]]; then
    log_info ".env configuration file not found - creating new configuration..."
    
    # Get service name for bucket naming
    read -p "Enter your site/service name (e.g., solar-assistant, my-home): " SITE_NAME
    
    if [[ -z "$SITE_NAME" ]]; then
        log_error "Site name cannot be empty"
        exit 1
    fi
    
    # Create .env file
    cat > "$ENV_FILE" <<EOF
# ============================================================================
# InfluxDB Backup to GCS Configuration
# ============================================================================
# Site configuration (used for backup file naming only)
SITE_NAME="${SITE_NAME}"

# GCS bucket name (must match the actual Google Cloud Storage bucket)
GCS_BUCKET="${SITE_NAME}"

# Local temporary directory for backup files
LOCAL_BACKUP_DIR="/tmp/influxdb-backup-${SITE_NAME}"

# Required minimum disk space in MB for backup operations
REQUIRED_MB=1000

# Rclone remote configuration
# Note: This is set up by setup.sh. Default is "gcs"
RCLONE_REMOTE_NAME="gcs"

# Retention period in days (must match GCS bucket lifecycle policy)
RETENTION_DAYS=30

# Log file location
LOG_FILE="/var/log/influxdb-backup.log"
EOF
    
    log_info "✓ .env configuration file created"
    log_info "  SITE_NAME: ${SITE_NAME}"
    log_info "  GCS_BUCKET: ${SITE_NAME}"
    log_info "  LOCAL_BACKUP_DIR: /tmp/influxdb-backup-${SITE_NAME}"
    
else
    log_info ".env configuration file found - preserving existing configuration"
    
    # Source .env to get current values for display
    if [[ -f "$ENV_FILE" ]]; then
        source "$ENV_FILE" 2>/dev/null || true
        log_info "  Current SITE_NAME: ${SITE_NAME:-not set}"
        log_info "  Current GCS_BUCKET: ${GCS_BUCKET:-not set}"
        log_info "  Current LOCAL_BACKUP_DIR: ${LOCAL_BACKUP_DIR:-not set}"
    fi
    
    # Verify compatibility with new backup.sh
    # Check if RCLONE_REMOTE is set (old variable name)
    if grep -q "^RCLONE_REMOTE=" "$ENV_FILE" 2>/dev/null; then
        log_warn "Found old variable name 'RCLONE_REMOTE' - this is still supported"
        log_info "✓ .env file is compatible with this version"
    else
        log_info "✓ .env file uses current variable names"
    fi
fi

# Make .env file readable only by user
chmod 600 "$ENV_FILE"

# ============================================================================
# Set up cron jobs
# ============================================================================

log_info "Setting up cron jobs..."

# Create cron configuration
CRON_FILE="/tmp/influxdb-backup-cron.txt"

# Daily backup job (2 AM)
echo "0 2 * * * ${INSTALL_DIR}/backup.sh >> ${INSTALL_DIR}/backup.log 2>&1" > "$CRON_FILE"

# Weekly update job (Sunday 3 AM)
echo "0 3 * * 0 ${INSTALL_DIR}/backup.sh --auto-update >> ${INSTALL_DIR}/backup.log 2>&1" >> "$CRON_FILE"

# Install cron jobs
(crontab -l 2>/dev/null | grep -v "${INSTALL_DIR}/backup.sh"; cat "$CRON_FILE") | crontab -

# Clean up temporary file
rm "$CRON_FILE"

log_info "✓ Cron jobs configured:"
log_info "  - Daily backup: 2 AM (0 2 * * *)"
log_info "  - Weekly auto-update: Sunday 3 AM (0 3 * * 0)"

# ============================================================================
# Run setup.sh for rclone configuration
# ============================================================================

log_info "Setting up rclone configuration..."
if [[ -f "${INSTALL_DIR}/setup.sh" ]]; then
    cd "$INSTALL_DIR"
    if ./setup.sh; then
        log_info "✓ Rclone configuration completed"
    else
        log_warn "Rclone setup encountered issues - you may need to run setup.sh manually"
    fi
else
    log_warn "setup.sh not found - skipping rclone setup"
fi

# ============================================================================
# Final validation
# ============================================================================

log_info "Validating installation..."

# Check backup.sh exists and is executable
if [[ ! -x "${INSTALL_DIR}/backup.sh" ]]; then
    log_error "backup.sh is not executable"
    exit 1
fi

# Check .env exists
if [[ ! -f "$ENV_FILE" ]]; then
    log_error ".env file not found"
    exit 1
fi

# Check cron jobs are installed
if crontab -l 2>/dev/null | grep -q "${INSTALL_DIR}/backup.sh"; then
    log_info "✓ Cron jobs found in crontab"
else
    log_warn "Cron jobs not found - you may need to add them manually"
fi

# Display final configuration
log_info "Installation completed successfully!"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Installation path: ${INSTALL_DIR}"
log_info "Configuration file: ${ENV_FILE}"
log_info "Backup script: ${INSTALL_DIR}/backup.sh"
log_info "Manual backup command: ${INSTALL_DIR}/backup.sh"
log_info "Manual update check: ${INSTALL_DIR}/backup.sh --update"
log_info "Log file: /var/log/influxdb-backup.log"
log_info "Scheduled backup: Daily at 2 AM"
log_info "Auto-update: Every Sunday at 3 AM"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "To test the backup now, run:"
log_info "  ${INSTALL_DIR}/backup.sh"
log_info "To view logs:"
log_info "  tail -f /var/log/influxdb-backup.log"
log_info "To edit configuration:"
log_info "  nano ${ENV_FILE}"

exit 0
