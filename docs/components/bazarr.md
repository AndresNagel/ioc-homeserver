# Bazarr

| | |
|---|---|
| **LXC ID** | 112 |
| **IP** | 192.168.1.112 |
| **Internal DNS** | `bazarr.internal` |
| **Public domain** | bazarr.welpes.com |
| **Port** | 6767 |
| **Ansible role** | `roles/bazarr` |
| **Resources** | 1024 MB RAM, 2 vCPU, 4 GB disk |

## Purpose

Subtitle automation for Sonarr/Radarr — searches subtitle providers and
downloads matching subtitles for the movie/TV library.

## Subcomponents

- **Bazarr** — official release zip
  (`morpheus65535/bazarr/releases/latest/download/bazarr.zip`), extracted
  to `/opt/bazarr`. Python dependencies installed into a dedicated venv
  (`/opt/bazarr/venv`).
- Runs as a systemd service (`bazarr.service`, `User=root`):
  `venv/bin/python3 bazarr.py -c /var/lib/bazarr --no-update` (Bazarr's
  own self-update is disabled — Ansible manages upgrades).
- Web/API login set to `admin`/`admin` on first run via Bazarr's settings
  API (API key read out of `/var/lib/bazarr/config/config.yaml`).

## Storage (bind mounts)

- `mp0`: `/mnt/ssd2tb` -> `/data` — same media library as Sonarr/Radarr,
  so Bazarr can read videos and write subtitle files alongside them.
- `mp1`: `/mnt/ssd2tb/configs/bazarr` -> `/var/lib/bazarr` — config,
  database, API key. Survives container rebuilds. Backed up nightly
  (excludes `log`, `logs`, `cache`).
