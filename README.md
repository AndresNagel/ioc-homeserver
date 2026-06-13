# Homeserver IaC — Beelink S12 / Proxmox

Ansible-managed homelab running on a single Proxmox host: a Sonarr/Radarr/
Lidarr/Prowlarr/Bazarr + Transmission media-acquisition pipeline, Jellyfin +
Navidrome for playback, Pi-hole for LAN DNS, a Homepage dashboard, and a
Forgejo/Semaphore GitOps loop that applies this repo automatically on push.

---

## Architecture

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
  [Adding a NAS later](#adding-a-nas-later)).
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
| Semaphore | 107 | 192.168.1.27 | `semaphore.internal` | 3000 | `semaphore` | Ansible CI/CD runner |
| Forgejo | 108 | 192.168.1.28 | `forgejo.internal` | 3001 | `forgejo` | Git hosting — source of truth for this repo |
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
  replacement for the decommissioned Tdarr LXC.

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

---

## Bootstrapping a host from scratch

These are the original from-scratch setup steps — useful for disaster
recovery or standing up a second host. The live `pve` host is already
provisioned; for normal changes, edit a role/playbook and push (the GitOps
loop applies it), or run the relevant playbook with `--limit`.

### 1. Install requirements on your laptop
```bash
pip install ansible
ansible-galaxy collection install community.general
```

### 2. Download an LXC template on Proxmox
```bash
# SSH into Proxmox host:
pveam update
pveam download local debian-12-standard_12.7-1_amd64.tar.zst
```
(Some hosts, e.g. transmission, override `proxmox_template` to a
Debian 13/trixie image — see `inventory.yml`/`group_vars`.)

### 3. Edit your settings
- `inventory.yml` — IPs, LXC IDs, memory/cores per host
- `group_vars/all/main.yml` — `proxmox_node`, `timezone`, SSH keys, etc.
- `host_vars/forgejo.yml` — GitHub mirror URL/username
- `group_vars/all/vault.yml` — all passwords/tokens, then encrypt:

```bash
# Generate secrets needed for Forgejo and Semaphore:
python3 -c "import secrets; print(secrets.token_hex(32))"
# Run as needed for: forgejo_secret_key, forgejo_internal_token,
# semaphore_cookie_hash, semaphore_cookie_encryption, semaphore_access_key_encryption

ansible-vault encrypt group_vars/all/vault.yml
```

### 4. Run in order
```bash
# Step 0 — prepare host directories, deploy Homepage + media_tools
ansible-playbook -i inventory.yml 0_prepare_host.yml --ask-vault-pass

# Step 1 — create LXC containers
ansible-playbook -i inventory.yml 1_provision_containers.yml --ask-vault-pass

# Step 2 — install and configure all services
ansible-playbook -i inventory.yml 2_configure_services.yml --ask-vault-pass
```

---

## Adding a NAS later

> **Status: not done.** `group_vars/all/main.yml` still defines
> `media_root: /mnt/media` and an `nfs_enabled` toggle from the original
> plan, but the live deployment bind-mounts `/mnt/ssd2tb` directly in
> `1_provision_containers.yml` for every host — those vars aren't currently
> wired up. Migrating to a NAS means updating those mounts (and
> `roles/media_tools`'s hardcoded `/mnt/ssd2tb` paths), not just flipping
> `nfs_enabled`.

The original intent: copy `/mnt/ssd2tb` to the NAS, point `0_prepare_host.yml`
at the NFS export instead, and have every LXC transparently see the same
paths — re-run `1_provision_containers.yml` to swap the bind-mount source.

---

## Day-to-day operations

### Redeploy a single service
```bash
ansible-playbook -i inventory.yml 2_configure_services.yml --limit pihole --ask-vault-pass
```

### Rebuild a container from scratch
```bash
# 1. Destroy in Proxmox UI or: pct destroy <vmid>
# 2. Re-provision + reconfigure:
ansible-playbook -i inventory.yml 1_provision_containers.yml --limit sonarr --ask-vault-pass
ansible-playbook -i inventory.yml 2_configure_services.yml --limit sonarr --ask-vault-pass
# State in /mnt/ssd2tb/configs/<app> and /mnt/ssd2tb/{media,series,torrents} is untouched.
```

### Add Pi-hole adlists / DNS records
Edit `host_vars/pihole.yml`, push to Forgejo (Semaphore auto-runs), or run
manually:
```bash
ansible-playbook -i inventory.yml 2_configure_services.yml --limit pihole --ask-vault-pass
```

### SSH into a container
```bash
pct enter <vmid>   # e.g. 104 for sonarr
```

### Check service status
```bash
systemctl status pihole-FTL              # pihole (100)
systemctl status lidarr                  # lidarr (101)
systemctl status jellyfin                # jellyfin (102)
systemctl status transmission-daemon     # transmission (103)
systemctl status sonarr radarr prowlarr  # arr apps (104/105/110)
systemctl status navidrome                # navidrome (106)
systemctl status semaphore                # semaphore (107)
systemctl status forgejo                  # forgejo (108)
systemctl status flaresolverr             # flaresolverr (111)
systemctl status bazarr                   # bazarr (112)
```

On the Proxmox host itself:
```bash
docker ps                                    # homepage
systemctl list-timers 'remux-concerts.timer' 'compress-concerts.timer' 'normalize-media.timer'
journalctl -t normalize-media                # normalize-media run history
```

---

## Service notes

### Transmission
RPC is enabled for the whole LAN (`--allowed *.*.*.*` in the systemd
override) with no authentication — fine on a trusted flat LAN, revisit if
that changes. WebUI: `http://transmission.internal:9091/transmission/web`.

### Navidrome
Music library: `/data/media/music` (i.e. `/mnt/ssd2tb/media/music` on the
host). Connect with any Subsonic-compatible client — Symfonium (Android),
Substreamer (iOS), Ultrasonic (Android, free) — at
`http://navidrome.internal:4533`.

### Homepage
Config lives in `roles/homepage/files/config/*.yaml` (services, widgets,
bookmarks, settings) — edit and re-run `0_prepare_host.yml` to redeploy.
After changing service definitions, hit `POST /api/revalidate` once if the
dashboard still shows stale content (Next.js static-shell cache).
