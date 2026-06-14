# Prowlarr

| | |
|---|---|
| **LXC ID** | 110 |
| **IP** | 192.168.1.110 |
| **Internal DNS** | `prowlarr.internal` |
| **Public domain** | prowlarr.welpes.com |
| **Port** | 9696 |
| **Ansible role** | `roles/arr` (shared with Sonarr/Radarr/Lidarr, `arr_app: prowlarr`) |
| **Resources** | 512 MB RAM, 1 vCPU, 4 GB disk |

## Purpose

Indexer manager — Sonarr/Radarr/Lidarr all query Prowlarr instead of
configuring indexers individually. Uses FlareSolverr to get past
Cloudflare-protected indexers.

## Subcomponents

- **Prowlarr** — self-contained .NET binary, downloaded from
  `prowlarr.servarr.com` (the role's default `servarr.com/v1/update`
  endpoint) and extracted to `/opt/Prowlarr`.
- Runs as a systemd service (`prowlarr.service`, `User=root`), started
  with `-data=/var/lib/prowlarr`.
- Web/API login set to `admin`/`admin` on first run via Prowlarr's own
  `config/host` API (API version `v1`).

## Storage (bind mounts)

- `mp0`: `/mnt/ssd2tb/configs/prowlarr` -> `/var/lib/prowlarr` — config,
  database, API key, indexer definitions. Survives container rebuilds.
  Backed up nightly (excludes `MediaCover`, `logs`).

Unlike Sonarr/Radarr/Lidarr, Prowlarr has no `/data` mount — it doesn't
touch media files directly, only indexer/search traffic.

## Notes

- Talks to FlareSolverr (192.168.1.111:8191) for indexers behind
  Cloudflare.
