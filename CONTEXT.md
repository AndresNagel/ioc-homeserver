# CONTEXT.md — Homelab IaC Session Handoff (HISTORICAL)
# Generated from claude.ai session — this was the original planning doc.
#
# >>> For current architecture, components, IPs/LXC IDs, and operations,
# >>> see README.md instead. The stack table, LXC IDs (100-108), and IPs
# >>> below reflect the ORIGINAL PLAN, not the live host (which has 12
# >>> services on IDs 100-112, Transmission instead of qBittorrent, Homepage
# >>> instead of no dashboard, etc.) — kept here only for historical
# >>> rationale (e.g. "no Terraform" decision) and the still-open VPN TODO.

## Who you are talking to
hishkaberry, working from a machine called `kiwi` (running NixOS or similar).
Proxmox host is a Beelink S12, hostname `proxmox`, accessible at `192.168.1.253`.
SSH confirmed working: `ssh root@192.168.1.253`

---

## What we built

A full Ansible IaC project for a Proxmox homelab. No Terraform — deliberate decision
(previous attempt 6 months ago failed due to state corruption). Ansible only for
Proxmox LXC provisioning, roles for everything inside containers.

### Repo location
Tarball was downloaded from claude.ai. Extract with:
```bash
tar -xzf homelab.tar.gz
cd homelab
```

### Full stack
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

## Key architectural decisions (don't second-guess these)

**No Terraform** — user tried it before, state got messy. Ansible only.
Proxmox LXC creation via `community.general.proxmox` module (no state file).

**Unified media root at /mnt/media** — single mount point on Proxmox host,
bind-mounted into every LXC that needs it. Subpaths defined as vars in all.yml.
Reason: hardlinks work (downloads + media same filesystem), and NAS migration
is a single toggle (nfs_enabled: true in all.yml) with zero LXC changes.

```
/mnt/media/
├── movies/
├── tv/
├── music/
├── books/
└── downloads/
    ├── complete/
    └── incomplete/
```

**Appdata on host SSD at /opt/appdata** — all app config/state bind-mounted
from host into containers. Destroy a container, rebuild it, everything resumes.
qBittorrent resume data explicitly mounted so downloads survive rebuilds.

**No VLANs** — flat network, static IPs on vmbr0, PiHole handles local DNS.

**Forgejo mirrors to GitLab** — push mirror configured automatically via
Forgejo API in the role. User has GitLab account already set up.
GitLab is offsite backup only, Forgejo is source of truth.

**GitOps loop**: laptop → git push → Forgejo → webhook → Semaphore → Ansible runs.

---

## VPN — INCOMPLETE, needs to be built

Scope decided but role NOT yet written. This is the main TODO.

**What was decided:**
- Only qBittorrent LXC routes through VPN
- All other LXCs (Jellyfin, Semaphore, etc) are completely unaffected
- Provider: ProtonVPN (user has subscription)
- Protocol: WireGuard
- Kill switch: yes — internet blocked if VPN drops, LAN (192.168.1.0/24) stays up
- Architecture: wg0 interface inside qBittorrent LXC, policy-based routing
- qBittorrent bound to wg0 so it cannot leak

**What user needs to do first (ProtonVPN side):**
1. Log into account.proton.me
2. Downloads → WireGuard configuration
3. Platform: Linux, Protocol: WireGuard, pick a [P2P] server
4. If Plus plan: enable NAT-PMP / port forwarding
5. Download the .conf file — private key goes into vault.yml

**What needs to be built (Ansible):**
- New role: `roles/wireguard/` 
  - Install wireguard-tools inside qBittorrent LXC
  - Template ProtonVPN wg0.conf from vault vars
  - iptables kill switch: allow LAN (192.168.1.0/24) via eth0, block all other
    internet if wg0 is down, allow internet only via wg0
  - Systemd wg-quick@wg0 service, enabled before qbittorrent.service
  - qBittorrent config updated: bind interface to wg0
- Update `roles/qbittorrent/templates/qBittorrent.conf.j2`:
  - Add `Session\Interface=wg0`
- Update `2_configure_services.yml`: apply wireguard role to qbittorrent host
  before qbittorrent role

---

## Proxmox host details — PARTIALLY CONFIRMED

- IP: 192.168.1.253 ✓ (confirmed via SSH)
- Hostname: proxmox ✓
- Kernel: 6.8.12-17-pve ✓

**Still unknown — run these on the Proxmox host and update group_vars/all.yml:**
```bash
pvesh get /nodes --output-format json | grep name   # → proxmox_node value
pvesm status                                         # → proxmox_storage value
ip link show | grep vmbr                             # → proxmox_bridge value
pveam list local                                     # → check if debian-12 template exists
```

Current values in group_vars/all.yml (may need updating):
- proxmox_node: pve          ← verify this
- proxmox_storage: local-lvm ← verify this
- proxmox_bridge: vmbr0      ← verify this

---

## Files that need secrets filled in before first run

### group_vars/vault.yml (encrypt with ansible-vault)
```
proxmox_api_password      ← root password for 192.168.1.253
pihole_web_password       ← choose one
forgejo_admin_password    ← choose one
forgejo_secret_key        ← python3 -c "import secrets; print(secrets.token_hex(32))"
forgejo_internal_token    ← same command
gitlab_mirror_token       ← GitLab PAT with write_repository scope
semaphore_cookie_hash          ← same command
semaphore_cookie_encryption    ← same command
semaphore_access_key_encryption ← same command
```

### group_vars/forgejo.yml
```
gitlab_mirror_url         ← https://gitlab.com/yourusername/homelab-ansible.git
forgejo_admin_email       ← your email
```

---

## Run order (once secrets and Proxmox vars are confirmed)

```bash
# 0. Install deps on kiwi
pip install ansible
ansible-galaxy collection install community.general

# 1. Verify Proxmox reachable
ansible -i inventory.yml pve -m ping

# 2. Prepare host dirs + optional NFS
ansible-playbook -i inventory.yml 0_prepare_host.yml --ask-vault-pass

# 3. Create LXC containers
ansible-playbook -i inventory.yml 1_provision_containers.yml --ask-vault-pass

# 4. Configure services
ansible-playbook -i inventory.yml 2_configure_services.yml --ask-vault-pass
```

---

## Existing infrastructure on Proxmox (to be careful around)

User has existing LXCs and VMs already running on the Proxmox host.
LXC IDs 100-108 are assigned to this new stack — confirm these don't
conflict with existing containers before running playbook 1.

Check with:
```bash
pct list    # existing LXCs
qm list     # existing VMs
```

If conflicts exist, update lxc_id values in inventory.yml before running.

---

## What to do first when starting Claude Code session on kiwi

1. `cat CONTEXT.md` — Claude Code reads this file
2. Run the Proxmox verification commands above, paste output
3. Fill in vault.yml secrets
4. Build the missing WireGuard/ProtonVPN role
5. Then run the playbooks in order, debugging as needed
