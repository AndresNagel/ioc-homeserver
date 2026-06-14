# Components

One page per LXC (plus the Proxmox host itself), written for humans:
what it is, where it lives, and what's running inside it. For the
high-level architecture and storage layout, see
[../ARCHITECTURE.md](../ARCHITECTURE.md).

All LXCs are unprivileged, built from the same base image
(`debian-12-standard_12.7-1_amd64`), and provisioned/configured by
`1_provision_containers.yml` + `2_configure_services.yml`.

| Component | LXC ID | IP | Internal DNS | Public domain (HTTPS) |
|---|---|---|---|---|
| [Proxmox host (pve)](pve.md) | — | 192.168.1.253 | `proxmox.internal` | — |
| [Pi-hole](pihole.md) | 100 | 192.168.1.100 | `pihole.internal` | pihole.welpes.com |
| [Lidarr](lidarr.md) | 101 | 192.168.1.101 | `lidarr.internal` | lidarr.welpes.com |
| [Jellyfin](jellyfin.md) | 102 | 192.168.1.102 | `jellyfin.internal` | jellyfin.welpes.com |
| [Transmission](transmission.md) | 103 | 192.168.1.103 | `transmission.internal` | transmission.welpes.com |
| [Sonarr](sonarr.md) | 104 | 192.168.1.104 | `sonarr.internal` | sonarr.welpes.com |
| [Radarr](radarr.md) | 105 | 192.168.1.105 | `radarr.internal` | radarr.welpes.com |
| [Navidrome](navidrome.md) | 106 | 192.168.1.106 | `navidrome.internal` | navidrome.welpes.com |
| [Semaphore](semaphore.md) | 107 | 192.168.1.107 | `semaphore.internal` | semaphore.welpes.com |
| [Forgejo](forgejo.md) | 108 | 192.168.1.108 | `forgejo.internal` | forgejo.welpes.com |
| [Jellyseerr](jellyseerr.md) | 109 | 192.168.1.109 | `jellyseerr.internal` | jellyseerr.welpes.com |
| [Prowlarr](prowlarr.md) | 110 | 192.168.1.110 | `prowlarr.internal` | prowlarr.welpes.com |
| [FlareSolverr](flaresolverr.md) | 111 | 192.168.1.111 | `flaresolverr.internal` | — (internal API only) |
| [Bazarr](bazarr.md) | 112 | 192.168.1.112 | `bazarr.internal` | bazarr.welpes.com |
| [Caddy](caddy.md) | 113 | 192.168.1.113 | — | terminates all `*.welpes.com` above |

Notes:
- Public domains only resolve on the LAN: Pi-hole points every
  `*.welpes.com` name at Caddy (192.168.1.113), which terminates real
  Let's Encrypt certs via DNS-01 (Cloudflare) and reverse-proxies to the
  service. There's no port-forwarding to the internet — this is a
  LAN-only setup by design.
- Homepage (the dashboard) runs as a Docker container directly on the
  Proxmox host, not in its own LXC — see [pve.md](pve.md).
