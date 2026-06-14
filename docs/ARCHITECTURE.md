# Architecture

Technical reference for how the homeserver is built: layout, components,
storage, the media pipeline, networking, and the GitOps loop. For a quick
overview and links to "what's running" / "how to operate it", see the main
[README](../README.md).

---

## Host layout

```
                       Beelink S12 — Proxmox VE 9 (Debian 13/trixie)
                       host "pve" — 192.168.1.253 / proxmox.internal
┌───────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│  Runs directly on the host (no LXC):                                      │
│  ┌─────────────────────┐   ┌──────────────────────────────────────────┐  │
│  │ Homepage (Docker)    │   │ media_tools — 3 daily systemd timers      │  │
│  │ :3000, dashboard for │   │ (remux-concerts, compress-concerts,       │  │
│  │ every service below  │   │  normalize-media) — use VAAPI/QuickSync   │  │
│  └─────────────────────┘   └──────────────────────────────────────────┘  │
│                                                                             │
│  Unprivileged LXC containers, one per service:                            │
│   pihole(100) lidarr(101) jellyfin(102) transmission(103) sonarr(104)     │
│   radarr(105) navidrome(106) semaphore(107) forgejo(108) prowlarr(110)    │
│   flaresolverr(111) bazarr(112)                                           │
│                                                                             │
│  /mnt/ssd2tb — single SSD on the host, bind-mounted into LXCs as /data    │
│  plus per-app config dirs (/mnt/ssd2tb/configs/<app> -> /var/lib/<app>)   │
└───────────────────────────────────────────────────────────────────────────┘
                │
                ▼  Pi-hole (LXC 100) serves <service>.internal for every host
```

Key points:
- **One Proxmox node, one shared SSD** (`/mnt/ssd2tb`) — every media-handling
  LXC bind-mounts the whole disk to `/data`, so Sonarr/Radarr/Lidarr can
  hardlink completed downloads instead of copying. No NAS yet (see
  [Adding a NAS later](OPERATIONS.md#adding-a-nas-later)).
- **Every LXC is unprivileged**, provisioned by `roles/proxmox_lxc` (creates
  the container + bind mounts + device passthrough) and configured by an
  app-specific role.
- **Two things run on the host itself, not in an LXC**: the Homepage
  dashboard (Docker container) and `media_tools`' three maintenance timers —
  both deployed via `0_prepare_host.yml`.
- **Pi-hole is both the LAN DNS resolver and the source of truth for
  `*.internal` hostnames** — every service gets a DNS record in
  `host_vars/pihole.yml`.
- **Jellyfin (LXC 102)** has `/dev/dri/renderD128` + `/dev/dri/card0` passed
  through for Intel QuickSync (VAAPI) hardware transcoding — same iGPU that
  `media_tools` uses for its encode passes.

---

## Components

| Service | LXC ID | IP | Internal DNS | Port | Role | Purpose |
|---|---|---|---|---|---|---|
| Proxmox host | — | 192.168.1.253 | `proxmox.internal` | 8006 | `proxmox_host` | Hypervisor (PVE 9 / Debian 13) |
| Homepage | — (Docker, on host) | 192.168.1.253 | `homepage.internal` | 3000 | `homepage` | Dashboard for every service below |
| Pi-hole | 100 | 192.168.1.100 | `pihole.internal` | 80 | `pihole` | DNS / ad-block, owns `.internal` records |
| Lidarr | 101 | 192.168.1.101 | `lidarr.internal` | 8686 | `arr` | Music collection management |
| Jellyfin | 102 | 192.168.1.102 | `jellyfin.internal` | 8096 | `jellyfin` | Media server, QuickSync transcoding |
| Transmission | 103 | 192.168.1.103 | `transmission.internal` | 9091 | `transmission` | Torrent download client |
| Sonarr | 104 | 192.168.1.104 | `sonarr.internal` | 8989 | `arr` | TV show management |
| Radarr | 105 | 192.168.1.105 | `radarr.internal` | 7878 | `arr` | Movie management |
| Navidrome | 106 | 192.168.1.106 | `navidrome.internal` | 4533 | `navidrome` | Music streaming (Subsonic API) |
| Semaphore | 107 | 192.168.1.107 | `semaphore.internal` | 3000 | `semaphore` | Ansible CI/CD runner |
| Forgejo | 108 | 192.168.1.108 | `forgejo.internal` | 3001 | `forgejo` | Git hosting — source of truth for this repo |
| Prowlarr | 110 | 192.168.1.110 | `prowlarr.internal` | 9696 | `arr` | Indexer management for the *arr apps |
| FlareSolverr | 111 | 192.168.1.111 | `flaresolverr.internal` | 8191 | `flaresolverr` | Cloudflare-bypass proxy for Prowlarr |
| Bazarr | 112 | 192.168.1.112 | `bazarr.internal` | 6767 | `bazarr` | Subtitle automation for Sonarr/Radarr |

Notes:
- `roles/arr` is one shared role for Sonarr/Radarr/Lidarr/Prowlarr —
  `arr_app` picks which app, all four install the same way (self-contained
  .NET binary).
- LXC ID 109 is an intentional gap. LXC 113 (Tdarr) was decommissioned
  2026-06-14 — `normalize-media` (below) is its permanent replacement.
- Semaphore/Forgejo keep their original `.27`/`.28` IPs from an earlier
  addressing scheme; every other service is `.10x`/`.11x`. Cosmetic only.

---

## Storage layout (`/mnt/ssd2tb` on the Proxmox host)

```
/mnt/ssd2tb/
├── configs/             # per-app state, bind-mounted to /var/lib/<app> in each LXC
│   ├── bazarr/  jellyfin/  lidarr/  navidrome/  prowlarr/  radarr/  sonarr/  transmission/
├── media/
│   ├── movies/          # Radarr root folder
│   ├── music/           # Lidarr root folder
│   ├── concerts/        # raw BDMV rips — input to remux-concerts
│   └── concerts_mkv/    # chaptered MKVs — output of remux/compress-concerts
├── series/              # Sonarr root folder
├── torrents/            # Transmission download dir (movies/, music/)
└── transcodes/          # Jellyfin HLS transcode scratch space
```

Every media-handling LXC (transmission, sonarr, radarr, lidarr, jellyfin,
navidrome) bind-mounts the **whole** `/mnt/ssd2tb` to `/data`, so completed
downloads in `/data/torrents` can be hardlinked into `/data/media/...` or
`/data/series/...` — no copying, instant "import".

---

## Media automation pipeline

```
Prowlarr (indexers) ──┐
                       ├──▶ Sonarr / Radarr / Lidarr ──▶ Transmission (download)
FlareSolverr (CF bypass)┘          │                          │
                                    │ hardlink on completion   │
                                    ▼                          │
                          /mnt/ssd2tb/{series,media}/ ◀────────┘
                                    │
                        ┌───────────┼────────────┐
                        ▼           ▼            ▼
                    Jellyfin    Navidrome    Bazarr (subtitles)
```

### Media maintenance (`roles/media_tools`, runs on the host)

Three daily systemd timers (`Nice=19`, `IOSchedulingClass=idle`), all using
the host's Intel iGPU (`/dev/dri/renderD128`, VAAPI):

- **`remux-concerts`** — converts raw BDMV concert rips in
  `media/concerts/` into chaptered MKVs in `media/concerts_mkv/`.
- **`compress-concerts`** — re-encodes those chaptered MKVs to HEVC at
  ~9 Mbps for comfortable WiFi streaming.
- **`normalize-media`** — walks the Sonarr (`series/`) and Radarr
  (`media/movies/`) libraries; for each file, one `ffprobe` call decides
  whether to downmix any audio track with >2 channels to AAC stereo and/or
  re-encode video >1080p down to 1080p HEVC. Fully-compliant files are
  skipped with **zero** ffmpeg invocations. This is the permanent
  replacement for the decommissioned Tdarr LXC. See
  [Operations: checking on normalize-media](OPERATIONS.md#media-normalization-normalize-media)
  for how to monitor its progress.

---

## Network / DNS

- Flat LAN, no VLANs. Gateway/router: `192.168.1.254`.
- Pi-hole (LXC 100, `192.168.1.100`) is the DNS resolver for the LAN and
  owns every `<service>.internal` record (`host_vars/pihole.yml` →
  `pihole_custom_dns`). Re-running the `pihole` role restarts `pihole-FTL`
  whenever this list changes.
- HTTPS is deferred until there's a real domain — everything is plain HTTP
  on the LAN today.

---

## GitOps loop (Forgejo → Semaphore → GitHub)

```
laptop → git push → Forgejo (forgejo.internal:3001, repo "homelab-ansible")
                       │
                       ├──▶ push mirror → GitHub (AndresNagel/ioc-homeserver, offsite backup)
                       └──▶ webhook → Semaphore (semaphore.internal:3000) → ansible-playbook runs
```

- Forgejo (LXC 108) is the source of truth for this repo. `roles/forgejo`
  configures a push mirror to GitHub automatically (`github_mirror_url` in
  `host_vars/forgejo.yml`, token in vault) — GitHub is offsite backup only.
- Semaphore (LXC 107) is wired to Forgejo via a webhook + task template
  (project "Homeserver IaC") and runs the playbooks against `pve` whenever
  `main` is pushed.

---

## Repo layout

```
0_prepare_host.yml          # host-level: dirs, NAS mount, homepage, media_tools
1_provision_containers.yml  # creates/updates all LXCs (bind mounts, devices)
2_configure_services.yml    # installs/configures the app inside each LXC
inventory.yml                # LXC IDs, IPs, memory/cores per host
group_vars/all/              # shared vars (main.yml) + vault.yml (encrypted secrets)
host_vars/                    # per-host overrides (DNS records, mirror config, etc.)
roles/
  proxmox_host, proxmox_lxc   # host prep + generic LXC provisioning
  arr                         # Sonarr/Radarr/Lidarr/Prowlarr (shared)
  transmission, jellyfin, navidrome, bazarr, flaresolverr, pihole
  semaphore, forgejo          # CI/CD
  homepage                    # dashboard (Docker, runs on host)
  media_tools                 # concert remux/compress + normalize-media timers (host)
```
