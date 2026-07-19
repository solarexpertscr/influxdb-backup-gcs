#!/bin/bash

set -euo pipefail

# ============================================================================
# Install Script — InfluxDB Shard-Based Backup to GCS
# ============================================================================
# This is the PUBLIC bootstrap script. On first run it installs from the
# public repo. On subsequent runs, if a deploy key is present in GCS, it
# switches over to the private repo.
# ============================================================================

INSTALL_DIR="/opt/influxdb-backup-gcs"
GITHUB_PUBLIC_REPO="solarexpertscr/influxdb-backup-gcs"
GITHUB_PRIVATE_REPO="solarexpertscr/solar-assistant-scripts"
GITHUB_PUBLIC_RAW_URL="https://raw.githubusercontent.com/${GITHUB_PUBLIC_REPO}/main"
GITHUB_PRIVATE_RAW_URL="https://raw.githubusercontent.com/${GITHUB_PRIVATE_REPO}/main"
GITHUB_PUBLIC_SSH_URL="git@github.com:${GITHUB_PUBLIC_REPO}.git"
GITHUB_PRIVATE_SSH_URL="git@github.com:${GITHUB_PRIVATE_REPO}.git"
GITHUB_PAT_FILE="${INSTALL_DIR}/.github-pat"
DEPLOY_KEY_FILE="${INSTALL_DIR}/deploy_key"
MARKER_FILE="${INSTALL_DIR}/.private_repo_active"

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
# Detect if we should use the private repo
# ---------------------------------------------------------------------------

USE_PRIVATE_REPO=false
if [[ -f "$MARKER_FILE" ]]; then
    log "✓ Private repo already active (marker file present)"
    USE_PRIVATE_REPO=true
elif [[ -f "$DEPLOY_KEY_FILE" ]]; then
    log "Deploy key found at ${DEPLOY_KEY_FILE}, switching to private repo..."
    USE_PRIVATE_REPO=true
fi

# ---------------------------------------------------------------------------
# Try to download deploy key from GCS (for migration)
# ---------------------------------------------------------------------------

if [[ "$USE_PRIVATE_REPO" == false ]]; then
    log "Checking for deploy key in GCS: gs://${SITE_NAME}/deploy_key"
    if command -v rclone &> /dev/null; then
        if rclone copyto "gcs:${SITE_NAME}/deploy_key" "${DEPLOY_KEY_FILE}" 2>/dev/null; then
            chmod 600 "${DEPLOY_KEY_FILE}"
            log "✓ Deploy key found in GCS, switching to private repo"
            USE_PRIVATE_REPO=true
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Configure SSH for private repo if using deploy key
# ---------------------------------------------------------------------------

if [[ "$USE_PRIVATE_REPO" == true ]]; then
    if [[ ! -f "$DEPLOY_KEY_FILE" ]]; then
        log_error "Private repo mode requested but deploy key not found at ${DEPLOY_KEY_FILE}"
    fi

    SSH_CONFIG_DIR="${HOME}/.ssh"
    mkdir -p "$SSH_CONFIG_DIR"
    chmod 700 "$SSH_CONFIG_DIR"

    SSH_CONFIG_FILE="${SSH_CONFIG_DIR}/config"
    if ! grep -q "github.com" "$SSH_CONFIG_FILE" 2>/dev/null; then
        cat >> "$SSH_CONFIG_FILE" <<EOF

# Solar Assistant deploy key
Host github.com
    HostName github.com
    User git
    IdentityFile ${DEPLOY_KEY_FILE}
    IdentitiesOnly yes
EOF
        chmod 600 "$SSH_CONFIG_FILE"
        log "✓ SSH config updated for GitHub deploy key"
    fi

    # Mark private repo as active
    touch "$MARKER_FILE"

    # Remove old PAT file if present
    if [[ -f "$GITHUB_PAT_FILE" ]]; then
        rm -f "$GITHUB_PAT_FILE"
        log "✓ Removed old PAT file"
    fi
fi

# ---------------------------------------------------------------------------
# Download scripts
# ---------------------------------------------------------------------------

download_via_curl() {
    local filename="$1"
    local base_url="$2"
    local auth_header="${3:-}"

    log "Downloading ${filename}..."

    local curl_cmd="curl -fsSL"
    if [[ -n "$auth_header" ]]; then
        curl_cmd+=" -H \"Authorization: token ${auth_header}\""
    fi

    if eval "${curl_cmd} \"${base_url}/${filename}\" -o \"${INSTALL_DIR}/${filename}\""; then
        chmod +x "${INSTALL_DIR}/${filename}" 2>/dev/null || true
        log "✓ ${filename} downloaded"
    else
        log_error "Failed to download ${filename}"
    fi
}

download_via_git() {
    local repo_url="$1"

    log "Cloning repository: ${repo_url}"
    local TEMP_CLONE_DIR; TEMP_CLONE_DIR=$(mktemp -d)

    if git clone --depth 1 "$repo_url" "$TEMP_CLONE_DIR" 2>/dev/null; then
        log "✓ Repository cloned"

        # Copy scripts
        for f in backup.sh restore.sh setup.sh cleanup.sh lifecycle.json; do
            if [[ -f "${TEMP_CLONE_DIR}/${f}" ]]; then
                cp "${TEMP_CLONE_DIR}/${f}" "${INSTALL_DIR}/${f}"
                [[ "$f" == *.sh ]] && chmod +x "${INSTALL_DIR}/${f}"
                log "✓ ${f} installed"
            fi
        done

        rm -rf "$TEMP_CLONE_DIR"
    else
        log_error "Failed to clone ${repo_url}"
    fi
}

if [[ "$USE_PRIVATE_REPO" == true ]]; then
    # Private repo: use git clone with SSH deploy key
    log "=========================================="
    log "Using PRIVATE repo: ${GITHUB_PRIVATE_REPO}"
    log "=========================================="
    download_via_git "$GITHUB_PRIVATE_SSH_URL"
else
    # Public repo: use curl with PAT (legacy)
    log "=========================================="
    log "Using PUBLIC repo: ${GITHUB_PUBLIC_REPO}"
    log "=========================================="

    # Download GitHub PAT from GCS
    log "Downloading GitHub PAT from GCS..."
    if rclone copyto "gcs:${SITE_NAME}/backup/.github-pat" "${GITHUB_PAT_FILE}" 2>/dev/null; then
        chmod 600 "${GITHUB_PAT_FILE}"
        GITHUB_PAT=$(cat "${GITHUB_PAT_FILE}")
        log "✓ GitHub PAT downloaded"
    else
        log_error "Failed to download GitHub PAT from GCS"
        log_error "Ensure gs://${SITE_NAME}/backup/.github-pat exists"
    fi

    download_via_curl "backup.sh" "$GITHUB_PUBLIC_RAW_URL" "$GITHUB_PAT"
    download_via_curl "restore.sh" "$GITHUB_PUBLIC_RAW_URL" "$GITHUB_PAT"
    download_via_curl "setup.sh" "$GITHUB_PUBLIC_RAW_URL" "$GITHUB_PAT"

    if curl -fsSL -H "Authorization: token ${GITHUB_PAT}" "${GITHUB_PUBLIC_RAW_URL}/cleanup.sh" -o "${INSTALL_DIR}/cleanup.sh" 2>/dev/null; then
        chmod +x "${INSTALL_DIR}/cleanup.sh"
        log "✓ cleanup.sh downloaded"
    fi

    if curl -fsSL -H "Authorization: token ${GITHUB_PAT}" "${GITHUB_PUBLIC_RAW_URL}/lifecycle.json" -o "${INSTALL_DIR}/lifecycle.json" 2>/dev/null; then
        log "✓ lifecycle.json downloaded"
    fi
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
# Summary
# ---------------------------------------------------------------------------

log ""
log "========================================="
log " Installation complete"
if [[ "$USE_PRIVATE_REPO" == true ]]; then
log " Repo:         ${GITHUB_PRIVATE_REPO} (private)"
log " Deploy key:   ${DEPLOY_KEY_FILE}"
else
log " Repo:         ${GITHUB_PUBLIC_REPO} (public)"
log " PAT file:     ${GITHUB_PAT_FILE}"
fi
log " Install dir:  ${INSTALL_DIR}"
log " Config:       ${ENV_FILE}"
log " Backup:       ${INSTALL_DIR}/backup.sh"
log " Restore:      ${INSTALL_DIR}/restore.sh"
log " Schedule:     Daily at 2:00 AM"
log " Auto-update:  Sunday 3:00 AM"
log " Logs:         /var/log/influxdb-backup.log"
log "========================================="

exit 0