# Setting up your own copy

So you've been given (or forked) this repo and want to run the same stack on
your own Proxmox box. This repo isn't a generic "drop it anywhere" tool yet —
quite a few things are hardcoded to *this* host's network and disk layout —
but adapting it is mostly find-and-replace. Here's the checklist.

## 1. What you need

- **A Proxmox VE host.** This repo provisions LXC containers via the
  Proxmox API, so Proxmox VE needs to already be installed. If you're
  starting from a bare Debian server, install Proxmox VE on it first (it's
  installed on top of Debian — see the official Proxmox docs for your
  Debian version) before coming back to this repo.
- **A second machine** (your laptop) with Ansible, to run the playbooks
  from. See [Operations: bootstrapping](OPERATIONS.md#bootstrapping-a-host-from-scratch)
  for the exact `pip`/`ansible-galaxy` commands.
- **A spare disk/partition for media** — see step 3.
- *(Optional)* An Intel CPU with an iGPU (QuickSync) if you want hardware
  video transcoding — see step 8.

## 2. Get the code

Fork or clone this repo, then push it somewhere you control (your own
Forgejo/GitHub/GitLab — or just keep it local on your laptop, the GitOps
loop in [docs/ARCHITECTURE.md](ARCHITECTURE.md#gitops-loop-forgejo--semaphore--github)
is entirely optional).

## 3. Storage — match the mount path (or rename it)

This repo hardcodes `/mnt/ssd2tb` as the data-disk mount point in several
places: `1_provision_containers.yml`, `roles/proxmox_lxc`,
`roles/proxmox_host`, `roles/jellyfin`, `roles/transmission`,
`roles/homepage`, and `roles/media_tools`. The path isn't read from a
variable yet, so the easiest path is:

- Format and mount your media disk at `/mnt/ssd2tb` on the Proxmox host too
  (even if it's a different size/disk).
- *Or* do a project-wide find-and-replace of `/mnt/ssd2tb` with whatever
  path you prefer, e.g.:
  ```bash
  grep -rl '/mnt/ssd2tb' --include=*.yml --include=*.sh . | xargs sed -i 's#/mnt/ssd2tb#/mnt/yourpath#g'
  ```

Either way, create the top-level layout on the Proxmox host before running
the playbooks:
```bash
mkdir -p /mnt/ssd2tb/{configs,media/{movies,music,concerts,concerts_mkv},series,torrents,transcodes}
```
(`roles/proxmox_lxc` creates the per-app subdirectories under `configs/`
with the right ownership automatically — see
[docs/ARCHITECTURE.md](ARCHITECTURE.md#storage-layout-mntssd2tb-on-the-proxmox-host)
for what each directory is for.)

## 4. Networking — pick your IPs

- **`inventory.yml`** — set `ansible_host` for `pve` and every LXC to free
  IPs on *your* LAN. Keep the `lxc_id` values unless they clash with
  containers you already have (`pct list` to check).
- **`host_vars/pihole.yml`** → `pihole_custom_dns` — update every
  `{ ip, name }` pair to match the IPs you just chose in `inventory.yml`.
  This is what makes `<service>.internal` resolve on your LAN.
- **`group_vars/all/main.yml`**:
  - `proxmox_host` — your Proxmox host's IP
  - `proxmox_gateway` / `proxmox_dns` — your router's IP
  - `proxmox_bridge` — usually `vmbr0`, check `ip link show` on the host
  - `proxmox_node` — your node's hostname (top-left of the Proxmox UI)
  - `proxmox_storage` — run `pvesm status` on the host; common values are
    `local-lvm` or `local-zfs`

## 5. SSH keys

Replace `proxmox_ssh_authorized_keys` in `group_vars/all/main.yml` with your
own public key(s) — these get authorized for `root` on every LXC the
playbooks create.

## 6. Timezone

Set `timezone` in `group_vars/all/main.yml` to your own (e.g. `Europe/Madrid`,
`Pacific/Auckland`).

## 7. Secrets (the vault)

Create your own `group_vars/all/vault.yml` (the one in this repo is
encrypted with a password you don't have) with these keys:

```yaml
proxmox_api_token_secret: ...       # Proxmox UI: Datacenter -> Permissions -> API Tokens
                                     # create a token for root@pam named "automation"
pihole_web_password: ...            # pick one
forgejo_admin_password: ...         # pick one
forgejo_secret_key: ...             # python3 -c "import secrets; print(secrets.token_hex(32))"
forgejo_internal_token: ...         # same command, different value
github_mirror_token: ...            # optional — see step 9
semaphore_cookie_hash: ...          # python3 -c "import secrets; print(secrets.token_hex(32))"
semaphore_cookie_encryption: ...    # same command, different value
semaphore_access_key_encryption: .. # same command, different value
```

Then encrypt it:
```bash
ansible-vault encrypt group_vars/all/vault.yml
```
(`.vault_pass` — a file containing your vault password — is already
gitignored, so it's safe to keep one locally and pass
`--vault-password-file .vault_pass` instead of typing `--ask-vault-pass`
every time.)

## 8. Optional: GitOps (Forgejo + Semaphore + GitHub mirror)

`host_vars/forgejo.yml` points its GitHub push-mirror at
`AndresNagel/ioc-homeserver` — either repoint `github_mirror_url` /
`github_mirror_username` / `github_mirror_token` at your own GitHub repo, or
remove the push-mirror task in `roles/forgejo` if you don't want an offsite
mirror.

The whole Forgejo + Semaphore CI/CD loop is optional, too — you can always
just run the three playbooks by hand from your laptop whenever you change
something.

## 9. Optional: hardware video transcoding (Intel QuickSync)

`roles/jellyfin` and `roles/media_tools` pass through `/dev/dri/renderD128`
and `/dev/dri/card0` and install Intel's VAAPI driver, for fast hardware
transcoding. If your Proxmox host's CPU doesn't have an Intel iGPU:

- Drop the `dev0`/`dev1` lines for the `jellyfin` container in
  `1_provision_containers.yml` — Jellyfin will fall back to software
  transcoding (slower, but works).
- Skip the `media_tools` role in `0_prepare_host.yml` — its normalize/remux
  jobs assume VAAPI is available.

## 10. Run it

Once the above is done, follow
[docs/OPERATIONS.md → Bootstrapping a host from scratch](OPERATIONS.md#bootstrapping-a-host-from-scratch)
to run the three playbooks in order. From then on, see
[docs/OPERATIONS.md](OPERATIONS.md) for day-to-day commands and
[docs/ARCHITECTURE.md](ARCHITECTURE.md) for how everything fits together.
