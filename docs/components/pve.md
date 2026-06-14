# Proxmox host (pve)

| | |
|---|---|
| **Type** | Bare-metal hypervisor (not an LXC) |
| **IP** | 192.168.1.253 |
| **Internal DNS** | `proxmox.internal` |
| **Web UI** | https://192.168.1.253:8006 (self-signed cert) |
| **Ansible role(s)** | `proxmox_host`, `media_tools`, `homepage`, `backup` |
| **Inventory group** | `proxmox_host` |

## Purpose

The hardware everything else runs on: a Beelink S12 mini-PC running
Proxmox VE 9 (Debian 13/trixie). Hosts every service LXC, plus a couple
of things that run directly on the host instead of in a container.

## Hardware / OS

- Proxmox VE 9 (Debian 13/trixie)
- Intel iGPU (Iris Xe / i5-1235U) — passed through to LXCs that need
  QuickSync (Jellyfin) and used directly by `media_tools` for HW encoding
- Single SSD mounted at `/mnt/ssd2tb`, bind-mounted into LXCs as `/data`
  and `/mnt/ssd2tb/configs/<app>` -> `/var/lib/<app>`

## What runs directly on the host (not in an LXC)

### Homepage dashboard (`roles/homepage`)
- Docker container, deployed via `docker compose` from `/opt/homepage`
- Port 3000 — `homepage.internal` / `homepage.welpes.com`
- Dashboard tiles + live widgets for every service in this list, plus a
  "Tasks" row linking to on-demand Semaphore templates (Jellyfin library
  refresh, run `normalize-media` now)
- Config: `/opt/homepage/config/*.yaml` (static) +
  `/opt/homepage/config/services.yaml` (templated by
  `4_homepage_widgets.yml` so it can embed widget API keys via
  `/opt/homepage/.env`)

### media_tools (`roles/media_tools`)
Three systemd timers operating on `/mnt/ssd2tb` directly, using
`ffmpeg`/`mkvtoolnix` + Intel VAAPI (QuickSync):
- **remux-concerts** — BDMV concert rips -> chaptered MKV
- **compress-concerts** — HEVC re-encode of remuxed concerts for
  WiFi-friendly streaming
- **normalize-media** — daily pass over the movies/series libraries:
  downmixes >2-channel audio tracks and re-encodes anything above 1080p
  to 1080p HEVC. Can also be triggered on-demand via the "Normalize Media
  Now" tile on the Homepage dashboard (Semaphore template "6 - Normalize
  Media Now").

### Backups (`roles/backup`, `3_backup.yml`)
- Nightly (3am) job on the Ansible controller pulls a tarball snapshot of
  each `backup_targets` host's `backup_root` (with SQLite databases
  hot-copied via `sqlite3 .backup`) into `~/homeserver-backups/` with
  7-day retention.

## Storage layout (`/mnt/ssd2tb`)

```
/mnt/ssd2tb/
├── configs/<app>/    # per-app state, bind-mounted to /var/lib/<app> in each LXC
├── media/movies/     # Radarr root folder
├── media/music/      # Lidarr root folder
├── media/concerts*/  # concert rips + remuxed/compressed MKVs
├── series/           # Sonarr root folder
├── torrents/         # Transmission download dir
└── transcodes/       # Jellyfin HLS transcode scratch space
```
