# influxdb-backup-gcs

Automated InfluxDB backup to Google Cloud Storage with lifecycle-managed retention.

## Overview

Backs up InfluxDB using `influxd backup -portable`, uploads a compressed archive to a GCS bucket, and relies on GCS lifecycle rules to automatically delete old backups.

Designed to run on Solar Assistant OrangePi instances. Each site gets its own bucket and service account.

## Directory Structure

```
├── .env.example      # Template for site-specific config
├── backup.sh         # Backup script (runs from cron)
├── lifecycle.json     # GCS lifecycle rule template
├── setup.sh          # One-time setup per site
└── README.md
```

## Per-site Configuration (`.env`)

Copy `.env.example` to `.env` and configure:

```bash
# Site identifier - used as GCS bucket name
SITE_NAME="solar-assistant"

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
```

## Quick Install

One-line installer for Solar Assistant deployments:

```bash
curl -sSL https://raw.githubusercontent.com/solarexpertscr/workspace/main/scripts/influxdb-backup-gcs/install.sh | sudo bash -s -- your-site-name
```

Replace `your-site-name` with the actual site identifier. The installer will:

1. Download scripts to `/opt/influxdb-backup-gcs/`
2. Generate `.env` with the site name
3. Prompt you to paste the service account JSON key directly (paste contents, then Ctrl+D)
4. Run setup (install gsutil, create bucket, set lifecycle, add cron)

The service account key is saved to `/etc/solar-assistant/gcs-key.json` with restrictive permissions (600).

## Manual Setup

1. Copy the entire directory to the target machine
2. Create `.env` from `.env.example`
3. Run setup — it will prompt you to paste the service account JSON key directly:

```bash
chmod +x setup.sh backup.sh
./setup.sh
```

Setup will:
- Install Google Cloud SDK if not present
- Create bucket `gs://<SITE_NAME>` in the `solar-assistant-backups` project
- Apply GCS lifecycle rules (auto-delete after `RETENTION_DAYS`)
- Install a cron job (daily at 2:00 AM)

## Manual Backup

```bash
./backup.sh
```

## GCS Bucket Naming

Buckets are named `gs://<SITE_NAME>` (e.g., `gs://solar-assistant`). Each site gets its own bucket and its own service account for isolation.

## Lifecycle

GCS lifecycle rules are applied during setup. Objects older than `RETENTION_DAYS` are automatically deleted. The lifecycle rule is configured per-bucket during `setup.sh`.

## Service Account Permissions

Each site's service account needs:
- **Storage Object Admin** on `gs://<SITE_NAME>`
- **Storage Viewer** on the project (for bucket creation during setup)

## Requirements

- `influxd` CLI available (version 1.x with `-portable` flag)
- `bash` 4+
- `gsutil` (installed automatically by `setup.sh` if missing)
- Network access to GCS
