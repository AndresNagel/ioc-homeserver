# FlareSolverr

| | |
|---|---|
| **LXC ID** | 111 |
| **IP** | 192.168.1.111 |
| **Internal DNS** | `flaresolverr.internal` |
| **Public domain** | — (internal API only, not exposed via Caddy) |
| **Port** | 8191 |
| **Ansible role** | `roles/flaresolverr` |
| **Resources** | 1024 MB RAM, 1 vCPU, 8 GB disk (default) |

## Purpose

Cloudflare-bypass proxy used by Prowlarr for indexers that sit behind
Cloudflare's anti-bot challenge. Stateless — Prowlarr is the only
consumer.

## Subcomponents

- **FlareSolverr** — release tarball, downloaded from the latest GitHub
  release (`FlareSolverr/FlareSolverr`) and extracted to
  `/opt/flaresolverr`.
- Bundles its own Chromium; the role installs Xvfb plus the Chrome
  runtime shared libraries (`libnss3`, `libgbm1`, etc.) it needs to run
  headless.
- Runs as a systemd service (`flaresolverr.service`, `User=root`,
  `Restart=always`, `LOG_LEVEL=info`).

## Storage

None — no bind mounts, no persistent state. Not in `backup_targets`
(stateless / fully rebuildable from the role).
