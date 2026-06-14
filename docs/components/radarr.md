# Radarr

| | |
|---|---|
| **LXC ID** | 105 |
| **IP** | 192.168.1.105 |
| **Internal DNS** | `radarr.internal` |
| **Public domain** | radarr.welpes.com |
| **Port** | 7878 |
| **Ansible role** | `roles/arr` (shared with Sonarr/Lidarr/Prowlarr, `arr_app: radarr`) |
| **Resources** | 2048 MB RAM, 2 vCPU, 4 GB disk |

## Purpose

Movie manager — monitors for wanted movies and hands download jobs to
Transmission via Prowlarr's indexers.

## Subcomponents

- **Radarr** — self-contained .NET binary, downloaded from
  `radarr.servarr.com` (the role's default `servarr.com/v1/update`
  endpoint) and extracted to `/opt/Radarr`.
- Runs as a systemd service (`radarr.service`, `User=root`), started with
  `-data=/var/lib/radarr`.
- Web/API login set to `admin`/`admin` on first run via Radarr's own
  `config/host` API (API version `v3`, the role default).

## Storage (bind mounts)

- `mp0`: `/mnt/ssd2tb` -> `/data` — shared with Transmission so completed
  downloads can be hardlinked into `media/movies/` instead of copied.
- `mp1`: `/mnt/ssd2tb/configs/radarr` -> `/var/lib/radarr` — config,
  database, API key. Survives container rebuilds. Backed up nightly
  (excludes `MediaCover`, `logs`).
