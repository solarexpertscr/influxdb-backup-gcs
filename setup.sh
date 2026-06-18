#!/bin/bash

set -e

# Load environment
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found. Copy .env.example to .env and configure it first."
    exit 1
fi
source "$ENV_FILE"

# Export GCS credentials
export GOOGLE_APPLICATION_CREDENTIALS

# Derived
GCS_BUCKET="gs://${SITE_NAME}"

echo "=== Setting up InfluxDB backup for: ${SITE_NAME} ==="
echo ""

# 1. Install Google Cloud SDK if not present
if ! command -v gsutil &>/dev/null; then
    echo "Installing Google Cloud SDK..."
    curl -sSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee /etc/apt/sources.list.d/google-cloud-sdk.list
    apt-get update && apt-get install -y google-cloud-cli
    echo ""
fi

# 2. Ensure service account key directory exists
KEY_DIR="$(dirname "${GOOGLE_APPLICATION_CREDENTIALS}")"
mkdir -p "${KEY_DIR}"

if [ ! -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]; then
    echo "Service account key not found at: ${GOOGLE_APPLICATION_CREDENTIALS}"
    echo "Paste the JSON key content below (Ctrl+D to finish):"
    cat > "${GOOGLE_APPLICATION_CREDENTIALS}"
    if [ ! -s "${GOOGLE_APPLICATION_CREDENTIALS}" ]; then
        rm -f "${GOOGLE_APPLICATION_CREDENTIALS}"
        echo "ERROR: No valid content was pasted"
        exit 1
    fi
    chmod 600 "${GOOGLE_APPLICATION_CREDENTIALS}"
    echo "Service account key saved to ${GOOGLE_APPLICATION_CREDENTIALS}"
fi

# 3. Activate service account
gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}"

echo "Project: ${PROJECT_NAME}"
echo ""

# 4. Create GCS bucket (gs://<sitename>)
if gsutil ls "${GCS_BUCKET}" &>/dev/null; then
    echo "Bucket ${GCS_BUCKET} already exists, skipping creation."
else
    echo "Creating bucket ${GCS_BUCKET}..."
    gsutil mb -p "${PROJECT_NAME}" "${GCS_BUCKET}"
fi
echo ""

# 5. Apply lifecycle rules
echo "Applying lifecycle rule: delete objects older than ${RETENTION_DAYS} days..."
cat > /tmp/lifecycle.json <<EOF
{
  "lifecycle": {
    "rule": [
      {
        "action": {"type": "Delete"},
        "condition": {
          "age": ${RETENTION_DAYS}
        }
      }
    ]
  }
}
EOF
gsutil lifecycle set /tmp/lifecycle.json "${GCS_BUCKET}"
rm /tmp/lifecycle.json
echo "Lifecycle applied."
echo ""

# 6. Make script executable and set up cron
chmod +x "${SCRIPT_DIR}/backup.sh"

CRON_LINE="0 2 * * * ${SCRIPT_DIR}/backup.sh >> /var/log/influxdb-backup.log 2>&1"
(crontab -l 2>/dev/null | grep -v "backup.sh"; echo "${CRON_LINE}") | crontab -

echo "=== Setup complete ==="
echo "  Site:    ${SITE_NAME}"
echo "  Project: ${PROJECT_NAME}"
echo "  Bucket:  ${GCS_BUCKET}"
echo "  Cron:    Daily at 2:00 AM"
echo "  Log:     /var/log/influxdb-backup.log"
echo ""
echo "Test with: ${SCRIPT_DIR}/backup.sh"
