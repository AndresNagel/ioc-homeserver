# Transmission

| | |
|---|---|
| **LXC ID** | 103 |
| **IP** | 192.168.1.103 |
| **Internal DNS** | `transmission.internal` |
| **Public domain** | transmission.welpes.com |
| **Port** | 9091 (Web UI / RPC, at `/transmission/web`) |
| **Ansible role** | `roles/transmission` |
| **Resources** | 512 MB RAM, 1 vCPU, 8 GB disk (default) |

## Purpose

BitTorrent client. Receives download jobs from Sonarr/Radarr/Lidarr via
Prowlarr's indexers; completed downloads are picked up by the *arr apps
via the shared `/data` mount (hardlinks, same filesystem).

## Subcomponents

- **transmission-daemon** — installed from the Debian apt repo (not a
  binary download), unlike the *arr apps.
- A dedicated `debian-transmission` user/group is pinned to uid/gid
  102/105 to match the ownership of the pre-existing bind-mounted config
  data.
- A systemd drop-in (`/etc/systemd/system/transmission-daemon.service.d/override.conf`)
  points `--config-dir` at the bind-mounted state directory and allows RPC
  from any host (`--allowed *.*.*.*`).
- `rpc-host-whitelist` in `settings.json` includes
  `transmission.welpes.com`, otherwise the Caddy reverse proxy gets HTTP
  421 "Misdirected Request" (Transmission's CVE-2018-5702 Host-header
  mitigation rejects non-numeric hostnames by default).

## Storage (bind mounts)

- `mp0`: `/mnt/ssd2tb` -> `/data` — full media disk, shared with
  Sonarr/Radarr/Lidarr so completed torrents can be hardlinked into the
  library instead of copied.
- `mp1`: `/mnt/ssd2tb/configs/transmission` -> `/var/lib/transmission-daemon`
  — `settings.json`, blocklists, resume files. Backed up nightly
  (`backup_root: /var/lib/transmission-daemon/info`).
