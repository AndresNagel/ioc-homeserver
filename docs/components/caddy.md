# Caddy

| | |
|---|---|
| **LXC ID** | 113 |
| **IP** | 192.168.1.113 |
| **Internal DNS** | — (target of every `*.welpes.com` record, not itself named) |
| **Public domain** | terminates all `*.welpes.com` domains (see below) |
| **Ports** | 80, 443 |
| **Ansible role** | `roles/caddy` |
| **Resources** | 512 MB RAM, 1 vCPU, 8 GB disk (default) |

## Purpose

Reverse proxy + TLS terminator. Gives every service a real
`https://<service>.welpes.com` URL with a browser-trusted Let's Encrypt
certificate, without exposing anything to the internet — Pi-hole resolves
`*.welpes.com` to this LXC's LAN IP only.

## Subcomponents

- **Caddy**, built with the `caddy-dns/cloudflare` plugin via Caddy's
  official build server
  (`caddyserver.com/api/download?...p=github.com/caddy-dns/cloudflare`) —
  the stock Caddy binary doesn't include DNS provider plugins.
- **TLS via DNS-01** — Caddy proves domain ownership by creating TXT
  records in Cloudflare (using `caddy_cloudflare_api_token`, vault,
  scoped to the `welpes.com` zone only). No port 80/443 forwarding from
  the internet is needed.
- Runs as a dedicated `caddy` system user, systemd service
  `caddy.service` with `AmbientCapabilities=CAP_NET_BIND_SERVICE` (so it
  can bind 80/443 without running as root).
- **Config**: `/etc/caddy/Caddyfile`, templated from
  `roles/caddy/templates/Caddyfile.j2` — one `reverse_proxy` block per
  domain.

## Proxied domains -> upstreams

| Domain | Upstream |
|---|---|
| homepage.welpes.com | 192.168.1.253:3000 (Homepage, on pve) |
| jellyfin.welpes.com | 192.168.1.102:8096 |
| navidrome.welpes.com | 192.168.1.106:4533 |
| sonarr.welpes.com | 192.168.1.104:8989 |
| radarr.welpes.com | 192.168.1.105:7878 |
| lidarr.welpes.com | 192.168.1.101:8686 |
| prowlarr.welpes.com | 192.168.1.110:9696 |
| bazarr.welpes.com | 192.168.1.112:6767 |
| transmission.welpes.com | 192.168.1.103:9091 |
| pihole.welpes.com | 192.168.1.100:80 |
| semaphore.welpes.com | 192.168.1.107:3000 |
| forgejo.welpes.com | 192.168.1.108:3001 |
| jellyseerr.welpes.com | 192.168.1.109:5055 |
| wiki.welpes.com | static files, `/var/www/wiki` (this LXC, see below) |

FlareSolverr (an internal API, not browsed to) and the Proxmox UI
(self-signed cert, needs extra reverse-proxy transport config) are
intentionally not proxied.

## LAN / network wiki

`wiki.welpes.com` serves a tiny [Docsify](https://docsify.js.org/) site from
`/var/www/wiki`:

- `index.html` — static Docsify loader, copied from
  `roles/caddy/files/wiki/index.html`.
- `README.md` — templated from `roles/caddy/templates/network.md.j2` on
  every run. It lists the LAN subnet/gateway, every host's IP/LXC ID/
  resources (from `inventory.yml`), and every Pi-hole DNS record (from
  `host_vars/pihole.yml`'s `pihole_custom_dns`) — so it can't drift from the
  actual config.

## Storage

- `/etc/caddy` — Caddyfile, owned `caddy:caddy 0750`.
- `/var/lib/caddy` — Caddy's data dir (issued certificates, ACME account
  state). Not currently in `backup_targets` — certs auto-renew, so this
  is treated as disposable.
