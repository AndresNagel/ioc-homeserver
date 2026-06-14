# Semaphore

| | |
|---|---|
| **LXC ID** | 107 |
| **IP** | 192.168.1.27 |
| **Internal DNS** | `semaphore.internal` |
| **Public domain** | semaphore.welpes.com |
| **Port** | 3000 |
| **Ansible role** | `roles/semaphore` |
| **Resources** | 256 MB RAM, 1 vCPU, 8 GB disk (default) |

## Purpose

CI/CD runner for this Ansible repo. Clones `homelab-ansible` from Forgejo
and runs the playbooks (`0_prepare_host.yml`, `1_provision_containers.yml`,
`2_configure_services.yml`, plus the on-demand task playbooks) as Task
Templates, either manually or via the Homepage dashboard's "Tasks" row.

## Subcomponents

- **Ansible Semaphore (community edition)** — single Go binary,
  downloaded from the latest GitHub release
  (`semaphoreui/semaphore`) to `/usr/local/bin/semaphore`.
- Runs as a dedicated `semaphore` system user (uid 999), systemd service
  `semaphore.service`. The unit has an `ExecStartPre=+/bin/chown -R
  semaphore:semaphore /var/lib/semaphore /etc/semaphore` to self-heal
  directory ownership on every start (a recurring `root:root` reset was
  causing SQLite "readonly database" login failures).
- **Database**: SQLite at `/var/lib/semaphore/database.sqlite3`
  (originally BoltDB, one-time-migrated — `.boltdb_migrated` marker).
- **Config**: `/etc/semaphore/config.json`, owned `semaphore:semaphore
  0640`.
- Has its own copies of `git`, `ansible`, `python3-pip`, plus the
  `community.general` Ansible collection — needed to actually execute the
  playbooks it runs.
- Admin user created on first run from `semaphore_admin_user` /
  `semaphore_admin_password` (vault).

## Storage (bind mounts)

- `mp0`: `{{ appdata_base }}/semaphore` (`/opt/appdata/semaphore`) ->
  `/var/lib/semaphore` — database, project workspaces, repo clones.
  Backed up nightly (excludes `tmp`).

## Notes

- This box's automation SSH key (`semaphore-automation@homeserver`) is in
  `proxmox_ssh_authorized_keys` and authorized on every LXC's `root`
  account, so Semaphore-run playbooks can reach every host.
