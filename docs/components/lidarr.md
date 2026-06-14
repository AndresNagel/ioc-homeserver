# Lidarr

| | |
|---|---|
| **LXC ID** | 101 |
| **IP** | 192.168.1.101 |
| **Internal DNS** | `lidarr.internal` |
| **Public domain** | lidarr.welpes.com |
| **Port** | 8686 |
| **Ansible role** | `roles/arr` (shared with Sonarr/Radarr/Prowlarr, `arr_app: lidarr`) |
| **Resources** | 1024 MB RAM, 2 vCPU, 4 GB disk |

## Purpose

Music collection manager — monitors for new albums/artists and hands
download jobs to Transmission via Prowlarr's indexers.

## Subcomponents

- **Lidarr** — self-contained .NET binary, downloaded from
  `lidarr.servarr.com` and extracted to `/opt/Lidarr`. Not an apt package.
- Runs as a systemd service (`lidarr.service`, `User=root`), started with
  `-data=/var/lib/lidarr`.
- Web/API login is set to `admin`/`admin` on first run via Lidarr's own
  `config/host` API (API version `v1`).

## Storage (bind mounts)

- `mp0`: `/mnt/ssd2tb` -> `/data` — shared with Transmission so completed
  downloads can be hardlinked into the music library instead of copied.
- `mp1`: `/mnt/ssd2tb/configs/lidarr` -> `/var/lib/lidarr` — config,
  database (`lidarr.db`), API key. Survives container rebuilds. Backed up
  nightly (excludes `MediaCover`, `logs`, `logs.db`,
  `corruption_backup_20260613`).

## Notes

- See `project_lidarr_db_corruption_20260613` history: the database was
  restored from a scheduled backup after corruption; the
  `corruption_backup_20260613` directory is a one-off leftover artifact,
  excluded from ongoing backups.
