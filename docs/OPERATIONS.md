# Operations

Day-to-day tasks: redeploying services, checking status/logs, adding DNS
records, and monitoring the background media-maintenance jobs. For the
overall design, see [Architecture](ARCHITECTURE.md).

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

### Media normalization (`normalize-media`)

A daily timer on `pve` walks `series/` and `media/movies/` (316 files as of
2026-06-14) and re-encodes anything that doesn't meet the target: audio
tracks with more than 2 channels get downmixed to AAC stereo, and video
taller than 1080p gets re-encoded to 1080p HEVC via VAAPI. Files that already
meet the target are left alone and produce **no log output at all** — so
there's no single "progress bar". Use these instead:

```bash
# When did it last run, and when's the next run scheduled?
systemctl list-timers normalize-media.timer

# Result of the last run (exit code + recent log lines)
systemctl status normalize-media.service

# Full history of every file that's ever been re-encoded
journalctl -t normalize-media

# Watch it live
journalctl -t normalize-media -f

# Trigger a run right now instead of waiting for the timer
sudo systemctl start normalize-media.service
```

A line like:
```
normalizing '/mnt/ssd2tb/series/Show/Season 01/S01E01.mkv' (height=2160 video=true audio=true)
```
means that file needed work (and shows what kind). A `FAILED: '...'` line
means ffmpeg errored on that file. Once `journalctl -t normalize-media`
stops producing new `normalizing` lines on consecutive runs, the whole
library is compliant.

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

---

## Known gotchas & open questions

### `--check` mode is broken for the semaphore/forgejo roles
Both roles have an unconditional `uri` task ("Get latest release") that
Ansible skips entirely under `--check` (the `uri` module doesn't support
check mode). The following `set_fact` then fails trying to read `.json` off
the skipped result. Pre-existing, unrelated to any particular change — just
run these two roles for real (no `--check`).

### Changing an LXC's IP applies live — no reboot needed
`community.proxmox.proxmox` (`state: present`, `update: true` by default)
pushes a new `net0` IP to a running container and it comes up on the new IP
immediately. `pct reboot` is not required.

### Re-running `1_provision_containers.yml` resets bind-mount ownership
The "Ensure bind mount source directories exist on proxmox" task resets
`/opt/appdata/<service>` ownership to `100000:100000` mode `0755`. The
service's own role (run via `2_configure_services.yml`) then fixes
ownership/mode back to its real values. This is expected back-and-forth, not
a bug — but if you run step 1 without following up with step 2, the service
may fail to read its data dir until step 2 runs.

### Cross-service hardcoded IPs live outside this repo
- **Semaphore**: project 1 / repository 1's `git_url` is stored in
  Semaphore's own sqlite DB and hardcodes Forgejo's IP
  (currently `http://192.168.1.108:3001/homeserver-admin/homelab-ansible.git`).
  If Forgejo's IP ever changes again, update this via the Semaphore REST API
  (`POST /api/auth/login`, then `GET`/`PUT /api/project/1/repositories/1`).
- **Local git remote**: the controller's `origin` remote (`git remote -v`)
  embeds Forgejo's IP *and* credentials
  (`http://homeserver-admin:<password>@192.168.1.108:3001/...`). If
  Forgejo's IP changes, update it with `git remote set-url origin ...` —
  otherwise pushes fail with a connection error.

### Pi-hole restarts can leave Homepage's Pi-hole widget showing a 401
Pi-hole v6's API is session-based. If `pihole-FTL` restarts (e.g. after a
DNS record change), Homepage's cached session becomes stale and its Pi-hole
widget logs `Error calling Pi-Hole API: 401 ... Unauthorized`. Fix: `docker
restart homepage` on `pve` to force re-authentication. Pi-hole's
password/API itself is fine in this case — don't chase credential issues.

### Open question: how does the GitOps push -> Semaphore trigger actually work?
`docs/ARCHITECTURE.md` describes a "Forgejo webhook -> Semaphore" trigger,
but as of 2026-06-14 the `homelab-ansible` repo has **zero webhooks
configured** (`GET /api/v1/repos/homeserver-admin/homelab-ansible/hooks`
returns `[]`). Builds still appear to run on push, so Semaphore must be
triggering some other way (e.g. polling on a schedule, or a webhook on a
different repo/path). Not yet confirmed — check Semaphore's Task Template
"Build" trigger config next time this needs debugging.
