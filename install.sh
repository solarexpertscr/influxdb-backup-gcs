#!/bin/bash

set -euo pipefail

INSTALL_DIR="/opt/influxdb-backup-gcs"
GITHUB_PRIVATE_REPO="solarexpertscr/solar-assistant-scripts"
DEPLOY_KEY_FILE="${INSTALL_DIR}/deploy_key"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

if [[ $# -lt 1 ]]; then
    fail "Usage: sudo bash install.sh <sitename>"
fi

SITE_NAME="$1"
SITE_NAME="${SITE_NAME#solar-assistant-}"
log "Using site name: solar-assistant-${SITE_NAME}"

if [[ $EUID -ne 0 ]]; then
    fail "Please run with sudo so the script can write ${INSTALL_DIR}"
fi

command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen is required but not installed"
command -v ssh >/dev/null 2>&1 || fail "ssh is required but not installed"

mkdir -p "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR"

log ""
log "========================================="
log "Step 1: SSH deploy key"
log "========================================="

if [[ -f "$DEPLOY_KEY_FILE" ]]; then
    chmod 600 "$DEPLOY_KEY_FILE"
    if [[ ! -f "${DEPLOY_KEY_FILE}.pub" ]]; then
        log "Existing private key found; recreating missing public key from it"
        ssh-keygen -y -f "$DEPLOY_KEY_FILE" > "${DEPLOY_KEY_FILE}.pub"
    else
        log "Existing deploy key found, reusing it"
    fi
else
    rm -f "${DEPLOY_KEY_FILE}.pub"
    log "Generating new deploy key..."
    ssh-keygen -q -t ed25519 -f "$DEPLOY_KEY_FILE" -N "" -C "solar-assistant-${SITE_NAME}@deploy"
    log "✓ Deploy key generated"
fi

chmod 600 "$DEPLOY_KEY_FILE"
chmod 644 "${DEPLOY_KEY_FILE}.pub"

FINGERPRINT="$(ssh-keygen -lf "$DEPLOY_KEY_FILE" | awk '{print $2}')"

log ""
log "========================================="
log "Step 2: Add public key to GitHub"
log "========================================="
log ""
log "Go to: https://github.com/${GITHUB_PRIVATE_REPO}/settings/keys"
log "Click: 'Add deploy key'"
log ""
log "Title: solar-assistant-${SITE_NAME}"
log "Allow write access: LEAVE UNCHECKED"
log ""
log "FINGERPRINT: ${FINGERPRINT}"
log ""
log "Public key:"
echo ""
cat "${DEPLOY_KEY_FILE}.pub"
echo ""
log ""
log "IMPORTANT: GitHub must show the same fingerprint above."
log "========================================="

read -r -p "Have you added this exact public key to GitHub? [y/N]: " CONTINUE
CONTINUE="${CONTINUE:-N}"
echo ""

if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
    log "OK - re-run this script after adding the key. The current key was kept."
    exit 0
fi

log ""
log "========================================="
log "Step 3: Testing SSH connection to GitHub"
log "========================================="

SSH_CONFIG_DIR="/root/.ssh"
SSH_CONFIG_FILE="${SSH_CONFIG_DIR}/config"
mkdir -p "$SSH_CONFIG_DIR"
chmod 700 "$SSH_CONFIG_DIR"
touch "$SSH_CONFIG_FILE"
chmod 600 "$SSH_CONFIG_FILE"

if ! grep -q "IdentityFile ${DEPLOY_KEY_FILE}" "$SSH_CONFIG_FILE" 2>/dev/null; then
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
else
    log "SSH config already contains this deploy key"
fi

log "Testing SSH connection with ${DEPLOY_KEY_FILE}..."
SSH_OUTPUT="$(ssh -o BatchMode=yes -o IdentitiesOnly=yes -i "$DEPLOY_KEY_FILE" -T git@github.com 2>&1 || true)"

if echo "$SSH_OUTPUT" | grep -q "successfully authenticated"; then
    log "✓ SSH connection successful!"
    log ""
    log "========================================="
    log "Setup complete!"
    log "========================================="
    log ""
    log "Next step: Clone and run the private repo install:"
    log "  cd /tmp && git clone git@github.com:${GITHUB_PRIVATE_REPO}.git"
    log "  sudo bash ${GITHUB_PRIVATE_REPO#*/}/install.sh ${SITE_NAME}"
    log ""
    exit 0
fi

warn "SSH connection failed."
warn "GitHub/SSH said: ${SSH_OUTPUT}"
warn "Current key fingerprint: ${FINGERPRINT}"
warn "The key has NOT been regenerated; compare this fingerprint with GitHub and retry."
exit 1
