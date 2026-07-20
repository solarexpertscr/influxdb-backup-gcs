# influxdb-backup-gcs

Public bootstrap repo for **Solar Experts** Solar Assistant installations.

> **This repo contains no backup functionality.**  
> It is used only to set up SSH deploy keys for Solar Experts installations.  
> All actual backup logic lives in a private repo that is cloned after authentication.

## Install

Run the following commands on the target Solar Assistant box:

```bash
curl -fsSL https://raw.githubusercontent.com/solarexpertscr/influxdb-backup-gcs/main/install.sh -o /tmp/install.sh
sudo bash /tmp/install.sh <sitename>
```

The script will:

1. Generate (or reuse) an SSH deploy key at `/opt/influxdb-backup-gcs/deploy_key`
2. Display the public key and fingerprint to add to GitHub
3. Test the SSH connection
4. Instruct you to clone and run the private repo installer

## Notes

- Run with `sudo` so the script can write to `/opt/influxdb-backup-gcs`
- The deploy key is read-only and scoped to the private repo
- If SSH authentication fails, **the key is not regenerated** — compare the displayed fingerprint with GitHub and retry
