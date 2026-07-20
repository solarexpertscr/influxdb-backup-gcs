#!/bin/bash

set -euo pipefail

INSTALL_DIR="/opt/influxdb-backup-gcs"
GITHUB_PRIVATE_REPO="solarexpertscr/solar-assistant-scripts"
DEPLOY_KEY_FILE="${INSTALL_DIR}/deploy_key"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

if [[ $# -gt 0 ]]; then
    SITE_NAME="$1"
    SITE_NAME="${SITE_NAME#solar-assistant-}"
    log "Using site name: solar-assistant-${SITE_NAME}"
else
    log_error "No site name provided"
    log_error "Usage: bash install.sh <sitename>"
fi

if ! command -v ssh-keygen &> /dev/null; then
    log_error "ssh-keygen is required but not installed"
fi

mkdir -p "$INSTALL_DIR"

while true; do
    log ""
    log "========================================="
    log "Step 1: Generating SSH deploy key"
    log "========================================="
    
    # Generate new key pair
    ssh-keygen -t ed25519 -f "$DEPLOY_KEY_FILE" -N "" -C "solar-assistant-${SITE_NAME}@deploy" >/dev/null 2>&1
    chmod 600 "$DEPLOY_KEY_FILE"
    
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
    log "Fingerprint: $(ssh-keygen -lf "$DEPLOY_KEY_FILE" | awk '{print $2}')"
    log ""
    log "Public key:"
    echo ""
    cat "${DEPLOY_KEY_FILE}.pub"
    echo ""
    log ""
    log "========================================="
    
    read -e -p "${CYAN}Have you added this public key to GitHub? [y/N]: ${NC} " -r CONTINUE
    CONTINUE="${CONTINUE:-N}"
    echo ""
    
    if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
        log "OK, let's try again with a new key..."
        continue
    fi
    
    log ""
    log "========================================="
    log "Step 3: Testing SSH connection to GitHub"
    log "========================================="
    
    # Create SSH config in CURRENT user's home
    SSH_CONFIG_DIR="${HOME}/.ssh"
    mkdir -p "$SSH_CONFIG_DIR"
    chmod 700 "$SSH_CONFIG_DIR"
    
    SSH_CONFIG_FILE="${SSH_CONFIG_DIR}/config"
    
    cat >> "$SSH_CONFIG_FILE" <<EOF

# Solar Assistant deploy key
Host github.com
    HostName github.com
    User git
    IdentityFile ${DEPLOY_KEY_FILE}
    IdentitiesOnly yes
EOF
    chmod 600 "$SSH_CONFIG_FILE"
    
    log "SSH config written to ${SSH_CONFIG_FILE}"
    log "Testing SSH connection..."
    
    if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
        log "✓ SSH connection successful!"
        log ""
        log "========================================="
        log "Setup complete!"
        log "========================================="
        log ""
        log "The deploy key is configured and working."
        log ""
        log "Next step: Clone and run the private repo install:"
        log "  cd /tmp && git clone git@github.com:${GITHUB_PRIVATE_REPO}.git"
        log "  bash ${GITHUB_PRIVATE_REPO#*/}/install.sh ${SITE_NAME}"
        log ""
        exit 0
    else
        warn "SSH connection failed!"
        warn ""
        warn "The deploy key may not be added to GitHub yet."
        warn "Current key fingerprint: $(ssh-keygen -lf "$DEPLOY_KEY_FILE" | awk '{print $2}')"
        warn ""
        warn "Let's try again with a fresh key..."
        log ""
        sleep 2
    fi
done