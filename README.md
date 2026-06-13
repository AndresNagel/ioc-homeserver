# Homelab IaC — Beelink S12 / Proxmox

## Stack
| Service     | IP             | LXC ID | Port  |
|-------------|----------------|--------|-------|
| PiHole      | 192.168.1.20   | 100    | 80    |
| qBittorrent | 192.168.1.21   | 101    | 8080  |
| Sonarr      | 192.168.1.22   | 102    | 8989  |
| Radarr      | 192.168.1.23   | 103    | 7878  |
| Prowlarr    | 192.168.1.24   | 104    | 9696  |
| Jellyfin    | 192.168.1.25   | 105    | 8096  |
| Navidrome   | 192.168.1.26   | 106    | 4533  |
| Semaphore   | 192.168.1.27   | 107    | 3000  |
| Forgejo     | 192.168.1.28   | 108    | 3001  |

---

## Media layout (on Proxmox host SSD)

All media and downloads live under a single root — same path inside every LXC.
This enables hardlinks (no copying on import) and makes NAS migration transparent.

```
/mnt/media/
├── movies/
├── tv/
├── music/
├── books/
└── downloads/
    ├── complete/     ← qBittorrent drops finished torrents here
    └── incomplete/   ← qBittorrent working directory
```

**Why downloads are inside /mnt/media:**
Sonarr/Radarr hardlink completed downloads to movies/ or tv/ instead of copying.
Hardlinks only work within the same filesystem — keeping everything under
/mnt/media guarantees this whether storage is local SSD or a future NAS.

---

## First-time setup

### 1. Install requirements on your laptop
```bash
pip install ansible
ansible-galaxy collection install community.general
```

### 2. Download the Debian 12 LXC template on Proxmox
```bash
# SSH into Proxmox host:
pveam update
pveam download local debian-12-standard_12.7-1_amd64.tar.zst
```

### 3. Edit your settings
- `inventory.yml` — set your actual Proxmox IP
- `group_vars/all.yml` — set proxmox_node, timezone
- `group_vars/forgejo.yml` — set gitlab_mirror_url, admin email
- `group_vars/vault.yml` — set all passwords/tokens, then encrypt:

```bash
# Generate secrets needed for Forgejo and Semaphore:
python3 -c "import secrets; print(secrets.token_hex(32))"
# Run 5 times total (forgejo_secret_key, forgejo_internal_token,
# semaphore_cookie_hash, semaphore_cookie_encryption, semaphore_access_key_encryption)

ansible-vault encrypt group_vars/vault.yml
```

### 4. Run in order

```bash
# Step 0 — prepare host directories (run once, and again when adding NAS)
ansible-playbook -i inventory.yml 0_prepare_host.yml --ask-vault-pass

# Step 1 — create LXC containers
ansible-playbook -i inventory.yml 1_provision_containers.yml --ask-vault-pass

# Step 2 — install and configure all services
ansible-playbook -i inventory.yml 2_configure_services.yml --ask-vault-pass
```

---

## Adding a NAS later (zero container changes)

When you get a NAS, the only file you touch is `group_vars/all.yml`:

```yaml
nfs_enabled: true
nfs_server: "192.168.1.50"     # your NAS IP
nfs_export: "/volume1/media"   # your NAS export path
```

Then run:
```bash
# Copy your data to the NAS first:
rsync -av /mnt/media/ 192.168.1.50:/volume1/media/

# Then swap the mount:
ansible-playbook -i inventory.yml 0_prepare_host.yml --ask-vault-pass
```

All LXCs transparently see the NAS. No container changes needed.

---

## GitOps loop (Forgejo → Semaphore)

```
Edit playbook on laptop
  → git push → Forgejo (192.168.1.28:3001)
  → webhook → Semaphore (192.168.1.27:3000)
  → Ansible runs automatically
  → Forgejo mirrors to GitLab (offsite backup)
```

### Wire Semaphore to Forgejo (one-time, in UI)
1. Open Semaphore → Key Store → add SSH key or token for Forgejo
2. Repositories → add `http://forgejo.local:3001/admin/homelab-ansible.git`
3. Task Templates → set playbook path, inventory, vault password
4. In Forgejo repo → Settings → Webhooks → add Semaphore webhook URL

### GitLab mirror
The Ansible role sets this up automatically for the homelab-ansible repo.
For new repos you create in Forgejo: Settings → Mirror Settings → Push Mirror → add GitLab URL.

---

## Day-to-day operations

### Redeploy a single service
```bash
ansible-playbook -i inventory.yml 2_configure_services.yml --limit pihole --ask-vault-pass
```

### Rebuild a container from scratch
```bash
# 1. Destroy in Proxmox UI or: pct destroy 100
# 2. Re-provision + reconfigure:
ansible-playbook -i inventory.yml 1_provision_containers.yml --limit pihole --ask-vault-pass
ansible-playbook -i inventory.yml 2_configure_services.yml --limit pihole --ask-vault-pass
# Data in /opt/appdata/pihole and /mnt/media is untouched.
```

### Add PiHole adlists
Edit `group_vars/pihole.yml`, push to Forgejo, Semaphore auto-runs. Or manually:
```bash
ansible-playbook -i inventory.yml 2_configure_services.yml --limit pihole --ask-vault-pass
```

### SSH into a container
```bash
pct enter 100   # replace with LXC ID
```

### Check service status
```bash
systemctl status pihole-FTL
systemctl status qbittorrent
systemctl status sonarr radarr prowlarr
systemctl status jellyfin
systemctl status navidrome
systemctl status semaphore
systemctl status forgejo
```

---

## qBittorrent WebUI password

First run generates a temp password in logs. Set via WebUI, then capture the hash:
```bash
cat /home/qbt/.config/qBittorrent/qBittorrent.conf | grep Password_PBKDF2
```
Paste into `group_vars/vault.yml` → `qbt_webui_password_hash`, re-encrypt.

---

## Navidrome

Music folder: `/mnt/media/music` — structure expected: `Artist/Album/track.flac`

Recommended phone apps (Subsonic-compatible):
- **Symfonium** (Android) — best overall
- **Substreamer** (iOS)
- **Ultrasonic** (Android, free)

Connect to `http://navidrome.local:4533`
