# Homeserver IaC — Beelink S12 / Proxmox

This repo holds the Ansible playbooks that build and run my home server: a
small Beelink S12 mini PC running Proxmox, hosting a media server, a
download/automation pipeline, a music server, ad-blocking DNS, and a
dashboard to tie it all together.

Everything is "config as code" — change something in this repo, push it, and
it gets applied to the real server automatically (see
[the GitOps loop](docs/ARCHITECTURE.md#gitops-loop-forgejo--semaphore--github)
if you're curious how).

## What's running on it

Open the dashboard first — it links to everything else:

| Service | What it's for | Address |
|---|---|---|
| **Homepage** | Dashboard — start here | `http://homepage.internal:3000` |
| **Jellyfin** | Watch movies & TV shows | `http://jellyfin.internal:8096` |
| **Navidrome** | Stream music from any phone/app | `http://navidrome.internal:4533` |
| **Sonarr / Radarr / Lidarr** | Auto-download new TV, movies, music | linked from Homepage |
| **Prowlarr** | Finds sources for the above | linked from Homepage |
| **Bazarr** | Auto-fetches subtitles | linked from Homepage |
| **Transmission** | Torrent client | `http://transmission.internal:9091` |
| **Pi-hole** | Ad-blocking + local `.internal` names | `http://pihole.internal` |
| **Forgejo** | Git server hosting this repo | `http://forgejo.internal:3001` |
| **Semaphore** | Applies this repo to the server automatically | `http://semaphore.internal:3000` |

The `*.internal` addresses only work on the home network.

## Keeping the media library tidy

A background job runs every night, quietly shrinking anything oversized:
audio tracks with more than 2 channels get downmixed to stereo, and video
above 1080p gets re-encoded down to 1080p. You don't need to do anything —
new downloads just get tidied up automatically. If you want to check on it
(or trigger it manually), see
[Operations: media normalization](docs/OPERATIONS.md#media-normalization-normalize-media).

## Want to run this yourself?

If a friend gave you this repo and you want to set up the same stack on your
own Proxmox box, see **[docs/GETTING_STARTED.md](docs/GETTING_STARTED.md)**
— it walks through what needs to change (network, storage paths, secrets,
etc.) to make this yours.

## Want to dig deeper?

- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — how it's all laid out:
  host layout, the full component list (LXC IDs, IPs, ports), storage
  layout, the media pipeline, networking/DNS, and the GitOps setup.
- **[docs/components/](docs/components/)** — one page per LXC (plus the
  Proxmox host): IP, domains, base image/resources, and what's installed
  inside.
- **[wiki.welpes.com](https://wiki.welpes.com)** — a small, always-current
  LAN/network page (hosts, IPs, DNS records), generated straight from
  `inventory.yml` and `host_vars/pihole.yml` on every deploy.
- **[docs/OPERATIONS.md](docs/OPERATIONS.md)** — day-to-day commands:
  redeploying a service, rebuilding a container, checking logs/status,
  adding DNS records, and bootstrapping a host from scratch.
- **[CONTEXT.md](CONTEXT.md)** — historical planning notes from when this
  project was first designed (kept for context, not current state).
