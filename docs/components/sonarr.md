# Sonarr

| | |
|---|---|
| **LXC ID** | 104 |
| **IP** | 192.168.1.104 |
| **Internal DNS** | `sonarr.internal` |
| **Public domain** | sonarr.welpes.com |
| **Port** | 8989 |
| **Ansible role** | `roles/arr` (shared with Lidarr/Radarr/Prowlarr, `arr_app: sonarr`) |
| **Resources** | 1024 MB RAM, 2 vCPU, 4 GB disk |

## Purpose

TV show manager — monitors for new episodes and hands download jobs to
Transmission via Prowlarr's indexers.

## Subcomponents

- **Sonarr v4** — self-contained .NET binary, extracted to `/opt/Sonarr`.
  Downloaded from `services.sonarr.tv` (Sonarr v4 moved off the legacy
  `servarr.com/v1/update` endpoint used by the other *arr apps).
- Runs as a systemd service (`sonarr.service`, `User=root`), started with
  `-data=/var/lib/sonarr`.
- Web/API login set to `admin`/`admin` on first run via Sonarr's own
  `config/host` API (API version `v3`, the role default).

## Storage (bind mounts)

- `mp0`: `/mnt/ssd2tb` -> `/data` — shared with Transmission so completed
  downloads can be hardlinked into `series/` instead of copied.
- `mp1`: `/mnt/ssd2tb/configs/sonarr` -> `/var/lib/sonarr` — config,
  database, API key. Survives container rebuilds. Backed up nightly
  (excludes `MediaCover`, `logs`).
