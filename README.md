# InfluxDB Backup to GCS — Shard-Based

Backs up InfluxDB to Google Cloud Storage using **shard-level sync** with rclone.

Instead of uploading a full tarball of the entire database every day, this approach uploads individual shard files — rclone's `--update` flag automatically skips frozen shards that haven't changed, and only re-uploads the active shard.

## Why shard-based?

| | Old approach (daily tarball) | Shard-based |
|---|---|---|
| Daily upload | Entire DB compressed | Only changed shards |
| Upload time | Minutes/hours (grows with DB) | Seconds (constant) |
| GCS storage | N copies × 30-day lifecycle | One cumulative set, kept forever |
| Restore | Extract tar then restore | Pull from GCS, restore directly |
| Retention | 30 days max | Indefinite history |

## Strategy

- **InfluxDB** splits data into time-windowed **shards** (typically 1 week each).
- The **active shard** grows as new data arrives; it re-uploads daily.
- Once a shard window closes (~7 days), the shard is **frozen** and never re-uploaded.
- rclone compares file size/modification time and only transfers what changed.

## Files

| File | Purpose |
|---|---|
| `backup.sh` | Creates a `-portable` backup and syncs shard files to GCS |
| `restore.sh` | Pulls shards from GCS and runs `influxd restore` |
| `install.sh` | Downloads scripts, creates `.env`, runs `setup.sh` |
| `setup.sh` | Configures rclone, creates bucket, applies lifecycle, installs cron |
| `lifecycle.json` | GCS bucket lifecycle: transition to NEARLINE after 30 days |

## Setup

**Prerequisite:** Upload a fine-grained GitHub PAT (with read-only access to
`solarexpertscr/workspace`) to your GCS bucket:

```bash
# One-time setup per client (run on any machine with gsutil/rclone access):
echo "github_pat_11XXXXX..." > /tmp/.github-pat
rclone copyto /tmp/.github-pat gcs:solar-assistant-<sitename>/backup/.github-pat
```

Then on the OrangePi:

```bash
# 1. Place your GCP service account key
sudo cp /path/to/key.json /etc/solar-assistant/gcs-key.json
sudo chmod 600 /etc/solar-assistant/gcs-key.json

# 2. Copy install.sh to the machine (via scp, USB, or any out-of-band method).
#    The first install MUST be done out-of-band because the script needs the
#    PAT to authenticate subsequent downloads from the private repo.
sudo scp install.sh root@<orangepi>:/tmp/install.sh

# 3. Run the installer (downloads PAT from GCS, then downloads remaining
#    scripts from the private workspace repo, creates bucket, configures
#    rclone, installs cron)
sudo bash /tmp/install.sh solar-assistant
```

### Permission model

- The GCS bucket acts as the **permission gate**: only machines with the
  `.github-pat` file in their bucket can install or self-update.
- Each OrangePi has its own fine-grained PAT, **revocable independently**
  from GitHub if a machine is compromised.
- The PAT is **read-only** on the workspace repo, so even if compromised
  it cannot write to or modify any files.
- The PAT is never hardcoded in the scripts — it's stored in
  `/opt/influxdb-backup-gcs/.github-pat` (chmod 600) on each machine.

## Manual backup

```bash
sudo bash /opt/influxdb-backup-gcs/backup.sh
```

## Restore

```bash
# Dry-run: show what would be restored
sudo bash /opt/influxdb-backup-gcs/restore.sh --dry-run

# Actual restore
sudo bash /opt/influxdb-backup-gcs/restore.sh

# Restore to a custom location
sudo bash /opt/influxdb-backup-gcs/restore.sh --restore-dir /custom/path

# List what's on GCS
sudo bash /opt/influxdb-backup-gcs/restore.sh --list
```

## Logs

```bash
tail -f /var/log/influxdb-backup.log
```

## Cron schedule

| When | What |
|---|---|
| `0 2 * * *` | Daily backup |
| `0 3 * * 0` | Sunday auto-update (pulls latest backup.sh from GitHub) |

## GCS Lifecycle

`lifecycle.json` transitions objects from **STANDARD** to **NEARLINE** 30 days after last modification. This means:

- The active shard (re-written daily) stays on Standard (fast access)
- Frozen shards automatically move to Nearline (~60% cheaper) after 30 days idle
- All history is kept indefinitely — no deletion

Apply it via GCP Console or (if `gsutil` is installed):

```bash
gsutil lifecycle set /opt/influxdb-backup-gcs/lifecycle.json gs://BUCKET_NAME
```

## Upgrade from old tarball version

The old backup.sh uploaded a full `.tar.gz` daily. The new version uploads shards. If you had the old version installed:

1. Old backups on GCS are still valid — they're just full tarballs under `backups/`
2. The new version writes shard files under `influxdb/` — different prefix, no conflict
3. Run `install.sh` as above to upgrade in place

## Self-update

```bash
sudo bash /opt/influxdb-backup-gcs/backup.sh --update
```
