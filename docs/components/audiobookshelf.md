# Audiobookshelf

| | |
|---|---|
| **LXC ID** | 115 |
| **IP** | 192.168.1.115 |
| **Internal DNS** | `audiobookshelf.internal` |
| **Public domain** | audiobookshelf.welpes.com |
| **Port** | 13378 |
| **Ansible role** | `roles/audiobookshelf` |
| **Resources** | 2048 MB RAM, 2 vCPU, 8 GB disk (default) |

## Purpose

Self-hosted audiobook/podcast server and player — streams to native
Android/iOS apps with playback position/speed sync, sleep timer, and
chapter support. Deployed 2026-06-18 alongside Readarr (which was
removed the next day; Audiobookshelf was kept).

## Subcomponents

- **Built from source** — the upstream project (`advplyr/audiobookshelf`)
  ships no release binaries (packagecloud apt repo is defunct); Docker is
  the only official install path, so this role follows the manual-build
  approach (same pattern as Jellyseerr):
  - Node.js 20.x (NodeSource apt repo)
  - `git clone` of `advplyr/audiobookshelf` (branch `master`) to
    `/opt/audiobookshelf`
  - Client: `npm ci` + `npm run generate` (Nuxt 2 → `client/dist`)
  - Server: `npm ci --only=production`
  - `libnusqlite3-linux-x64.so` (prebuilt glibc binary from
    `mikiher/nunicode-sqlite`) provides unicode-aware SQLite full-text
    search, downloaded to `/usr/local/lib/nusqlite3/`.
- Runs as a systemd service (`audiobookshelf.service`):
  `node index.js`, `PORT=13378`, `CONFIG_PATH`/`METADATA_PATH` under
  `/var/lib/audiobookshelf`.
- Libraries (media type + folder path) are configured via the web UI,
  not Ansible — Settings → Libraries.

## Storage (bind mounts)

- `mp0`: `/mnt/ssd2tb` -> `/data` — audiobook files live under
  `/mnt/ssd2tb/books` on the host (`/data/books` inside the container).
  One folder per book (or per author containing book subfolders); `.m4b`
  or per-chapter `.mp3` both work.
- `mp1`: `/mnt/ssd2tb/configs/audiobookshelf` -> `/var/lib/audiobookshelf`
  — `absdatabase.sqlite`, metadata cache, migrations. Backed up nightly
  (excludes `metadata/cache`, `metadata/items`).

## Notes

- To add books: copy/rsync files into `/mnt/ssd2tb/books/` on the
  Proxmox host, then either wait for Audiobookshelf's periodic scan or
  trigger one from Settings → Libraries in the UI.
