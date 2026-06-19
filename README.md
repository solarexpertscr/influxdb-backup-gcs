# InfluxDB Backup to Google Cloud Storage (rclone)

Backs up InfluxDB to GCS using **rclone** instead of `gsutil`/`gcloud` — saves ~350MB of disk space on the Orange Pi eMMC.

## Why rclone?

| | gcloud SDK | rclone |
|---|---|---|
| Install size | ~400MB | ~50MB |
| Dependencies | Python, apt packages | Single binary |
| Auth | `gcloud auth activate-service-account` | Service account file directly |
| Upload | `gsutil cp` | `rclone copy` |

## Setup

1. Place your GCP service account JSON key at `/etc/solar-assistant/gcs-key.json`
2. Run the installer:

```bash
bash install.sh solar-assistant
```

This will:
- Install rclone (if not present)
- Configure the rclone remote with your service account
- Create the GCS bucket (if it doesn't exist)
- Set up a daily cron job at 2:00 AM

## Files

- `install.sh` — one-time installer (downloads scripts, configures rclone, creates bucket)
- `setup.sh` — rclone setup (called by install.sh)
- `backup.sh` — the backup script (runs daily via cron)
- `lifecycle.json` — bucket auto-deletion rules (30 days retention)

## Manual backup test

```bash
bash /opt/influxdb-backup-gcs/backup.sh
```

## Logs

```bash
cat /var/log/influxdb-backup.log
```

## Switching from the old version

If you had the previous `gsutil` version installed:

```bash
# 1. Remove old crontab
crontab -l | grep -v "influxdb_backup" | crontab -

# 2. Remove old scripts
rm -rf /opt/influxdb-backup-gcs

# 3. Optional: remove gcloud SDK to free ~400MB
apt-get remove --purge google-cloud-cli
apt-get autoremove

# 4. Install new version
bash <(curl -fsSL https://raw.githubusercontent.com/solarexpertscr/influxdb-backup-gcs/main/install.sh) solar-assistant
```
