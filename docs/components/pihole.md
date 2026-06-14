# Pi-hole

| | |
|---|---|
| **LXC ID** | 100 |
| **IP** | 192.168.1.100 |
| **Internal DNS** | `pihole.internal` |
| **Public domain** | pihole.welpes.com |
| **Web UI / port** | http://192.168.1.100 (port 80) |
| **DNS port** | 53 (used by every other device on the LAN) |
| **Ansible role** | `roles/pihole` |
| **Resources** | 512 MB RAM, 1 vCPU, 8 GB disk (default) |

## Purpose

LAN-wide DNS resolver and ad-blocker. Also the source of truth for every
`*.internal` and `*.welpes.com` hostname on the network — every other
service in this list gets its DNS record from here
(`host_vars/pihole.yml`).

## Subcomponents

- **Pi-hole v6** — installed via the official unattended installer
  (`install.pi-hole.net`). Config lives in `/etc/pihole/pihole.toml` and
  `gravity.db` (SQLite), not the old v5 flat files.
- **pihole-FTL** — the DNS resolver daemon. Custom local DNS records
  (`*.internal`, `*.welpes.com` -> Caddy) and upstream DNS servers
  (1.1.1.1, 8.8.8.8) are set via `pihole-FTL --config`.
- **Adlists** — managed in `host_vars/pihole.yml` (`pihole_adlists`),
  applied to `gravity.db` via a templated SQL file and a gravity update.

## Storage

- `/etc/pihole` — config, gravity database. Backed up nightly
  (`backup_root: /etc/pihole`).

## Notes

- `proxmox_dns` (used while provisioning other LXCs) points at the router
  (192.168.1.254), not Pi-hole itself — avoids a chicken-and-egg problem
  when rebuilding the Pi-hole container.
- Web admin password is set from `pihole_web_password` in
  `group_vars/all/vault.yml`.
