#!/bin/bash

set -euo pipefail

# ============================================================================
# Bootstrap Script — Deploy Key Setup for Solar Assistant Backup
# ============================================================================
# This script generates an SSH deploy key locally, displays the public key,
# and validates that it's been added to GitHub before exiting.
# 
# The private repo (solarexpertscr/solar-assistant-scripts) handles all
# actual backup installation and configuration.
# ============================================================================

INSTALL_DIR="/opt/influxdb-backup-gcs"
GITHUB_PRIVATE_REPO="solarexpertscr/solar-assistant-scripts"
DEPLOY_KEY_FILE="${INSTALL_DIR}/deploy_key"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
prompt() { echo -en "${CYAN}$1${NC} "; }

# ---------------------------------------------------------------------------
# Determine SITE_NAME
# ---------------------------------------------------------------------------

if [[ $# -gt 0 ]]; then
    SITE_NAME="$1"
    log "Using site name from argument: ${SITE_NAME}"
else
    log_error "No site name provided"
    log_error "Usage: bash install.sh <sitename>"
fi

# ---------------------------------------------------------------------------
# Pre-checks
# ---------------------------------------------------------------------------

if ! command -v ssh-keygen &> /dev/null; then
    log_error "ssh-keygen is required but not installed"
fi

if ! command -v git &> /dev/null; then
    log "git not found - installing..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq git
        log "✓ git installed"
    else
        log_error "git is required but not installed. Install git first, then re-run."
    fi
fi

# ---------------------------------------------------------------------------
# Create install directory
# ---------------------------------------------------------------------------

sudo mkdir -p "$INSTALL_DIR"
sudo chown "$(id -u):$(id -g)" "$INSTALL_DIR" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Main loop: generate key, validate, retry if needed
# ---------------------------------------------------------------------------

while true; do
    log ""
    log "========================================="
    log "Step 1: Generating SSH deploy key"
    log "========================================="
    
    # Remove existing key if present
    if [[ -f "$DEPLOY_KEY_FILE" ]]; then
        log "Removing existing deploy key..."
        sudo rm -f "$DEPLOY_KEY_FILE" "${DEPLOY_KEY_FILE}.pub"
    fi
    
    # Generate new key pair
    sudo ssh-keygen -t ed25519 -f "$DEPLOY_KEY_FILE" -N "" -C "solar-assistant-${SITE_NAME}@deploy" >/dev/null 2>&1
    sudo chmod 600 "$DEPLOY_KEY_FILE"
    sudo chown root:root "$DEPLOY_KEY_FILE" "${DEPLOY_KEY_FILE}.pub"
    
    log "✓ Deploy key generated"
    
    log ""
    log "========================================="
    log "Step 2: Add public key to GitHub"
    log "========================================="
    log ""
    log "Go to: https://github.com/${GITHUB_PRIVATE_REPO}/settings/keys"
    log "Click: 'Add deploy key'"
    log ""
    log "Title: solar-assistant-${SITE_NAME}"
    log "Key:   (copy the public key below)"
    log "Allow write access: LEAVE UNCHECKED"
    log ""
    log "Public key:"
    echo ""
    sudo cat "${DEPLOY_KEY_FILE}.pub"
    echo ""
    log ""
    log "========================================="
    
    # Ask user to confirm
    prompt "Have you added this public key to GitHub? [y/N]: "
    read -r response
    
    if [[ "$response" != "y" && "$response" != "Y" ]]; then
        log "OK, let's try again with a new key..."
        continue
    fi
    
    # ---------------------------------------------------------------------------
    # Step 3: Test SSH connection
    # ---------------------------------------------------------------------------
    
    log ""
    log "========================================="
    log "Step 3: Testing SSH connection to GitHub"
    log "========================================="
    
    # Configure SSH to use the deploy key
    SSH_CONFIG_DIR="${HOME}/.ssh"
    mkdir -p "$SSH_CONFIG_DIR"
    chmod 700 "$SSH_CONFIG_DIR"
    
    SSH_CONFIG_FILE="${SSH_CONFIG_DIR}/config"
    
    # Remove existing github.com entry if present
    if grep -q "github.com" "$SSH_CONFIG_FILE" 2>/dev/null; then
        log "Updating existing SSH config..."
        # Create temp file without github.com block
        awk '
            /^# Solar Assistant deploy key/ { skip=1 }
            /^Host github.com/ { skip=1 }
            /^    HostName github.com/ { skip=1 }
            /^    User git/ { skip=1 }
            /^    IdentityFile/ { skip=1 }
            /^    IdentitiesOnly yes/ { skip=1; next }
            /^$/ && skip { skip=0; next }
            !skip { print }
        ' "$SSH_CONFIG_FILE" > "${SSH_CONFIG_FILE}.tmp"
        mv "${SSH_CONFIG_FILE}.tmp" "$SSH_CONFIG_FILE"
    fi
    
    # Add new github.com entry
    cat >> "$SSH_CONFIG_FILE" <<EOF

# Solar Assistant deploy key
Host github.com
    HostName github.com
    User git
    IdentityFile ${DEPLOY_KEY_FILE}
    IdentitiesOnly yes
EOF
    chmod 600 "$SSH_CONFIG_FILE"
    
    # Test SSH connection
    log "Testing SSH connection..."
    if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
        log "✓ SSH connection successful!"
        log ""
        log "========================================="
        log "Setup complete!"
        log "========================================="
        log ""
        log "The deploy key is configured and working."
        log "The private repo will handle the rest of the installation."
        log ""
        log "Next step: Run the private repo's install script:"
        log "  sudo bash /opt/influxdb-backup-gcs/install-private.sh"
        log ""
        log "(Or wait for the private repo to auto-install via cron)"
        log ""
        exit 0
    else
        warn "SSH connection failed!"
        warn ""
        warn "The deploy key may not be added to GitHub yet, or there's a configuration issue."
        warn ""
        warn "Let's try again with a new key..."
        log ""
        sleep 2
    fi
done
