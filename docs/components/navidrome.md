# Navidrome

| | |
|---|---|
| **LXC ID** | 106 |
| **IP** | 192.168.1.106 |
| **Internal DNS** | `navidrome.internal` |
| **Public domain** | navidrome.welpes.com |
| **Port** | 4533 |
| **Ansible role** | `roles/navidrome` |
| **Resources** | 1024 MB RAM, 2 vCPU, 4 GB disk |

## Purpose

Music streaming server with a Subsonic-compatible API — lets phone/desktop
music apps stream from the Lidarr-managed music library.

## Subcomponents

- **Navidrome** — single Go binary, downloaded from the latest GitHub
  release (`navidrome/navidrome`) and extracted to `/opt/navidrome`.
- **ffmpeg** — installed for on-the-fly transcoding.
- Runs as a systemd service (`navidrome.service`, runs as root — matches
  the original hand-built container).
- `navidrome.toml` is only templated if it doesn't already exist
  (`force: false`), so Last.fm/Spotify credentials added manually are
  never overwritten by a re-run.

## Storage (bind mounts)

- `mp0`: `/mnt/ssd2tb` -> `/data` — read access to the music library
  (Lidarr's root folder).
- `mp1`: `/mnt/ssd2tb/configs/navidrome` -> `/var/lib/navidrome` —
  `navidrome.toml`, library index/database, cache. Survives container
  rebuilds. Backed up nightly (excludes `cache`).
