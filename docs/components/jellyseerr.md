# Jellyseerr

| | |
|---|---|
| **LXC ID** | 109 |
| **IP** | 192.168.1.109 |
| **Internal DNS** | `jellyseerr.internal` |
| **Public domain** | jellyseerr.welpes.com |
| **Port** | 5055 |
| **Ansible role** | `roles/jellyseerr` |
| **Resources** | 2048 MB RAM, 2 vCPU, 8 GB disk (default) |

## Purpose

Media request UI — household members browse/search for movies and shows
and submit requests, which Jellyseerr forwards to Radarr/Sonarr; once
downloaded, content shows up in Jellyfin. (Upstream project rebranded to
"Seerr"; the LXC/inventory name `jellyseerr` is kept for continuity.)

## Subcomponents

- **Built from source** — the upstream project (`seerr-team/seerr`) ships
  no pre-built binary release, only Docker images, so this role follows
  the documented manual-install path:
  - Node.js 22.x (NodeSource apt repo) + `pnpm`
  - `git clone` of `seerr-team/seerr` (branch `main`) to `/opt/jellyseerr`
  - `pnpm install` + `pnpm build`
- Runs as a systemd service (`jellyseerr.service`,
  `node dist/index.js`), config via `/etc/jellyseerr/jellyseerr.conf`
  (`PORT=5055`, `CONFIG_DIRECTORY=/var/lib/jellyseerr`).
- Connects to Jellyfin (192.168.1.102:8096) for libraries/auth and to
  Sonarr/Radarr for requests — configured via the first-run setup wizard
  in the browser, not by Ansible.

## Storage (bind mounts)

- `mp0`: `/mnt/ssd2tb/configs/jellyseerr` -> `/var/lib/jellyseerr` —
  `settings.json` (incl. Jellyfin API key), request database, sessions.
  Backed up nightly. App code in `/opt/jellyseerr` is **not** backed up
  (rebuilt from source on redeploy).

## Notes

- The Jellyfin API key stored in `/var/lib/jellyseerr/settings.json` is
  reused by `5_jellyfin_refresh.yml` (the "Jellyfin Refresh" Homepage
  task) — no separate Jellyfin credential needed.
