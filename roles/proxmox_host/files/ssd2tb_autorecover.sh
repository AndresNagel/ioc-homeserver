#!/bin/bash
# Detects the ssd2tb emergency_ro fault (see project memory: recurring
# SATA CRC/timeout errors on ata1 force ext4 to abort its journal and
# remount read-only) and runs the same recovery procedure that's been done
# by hand after every prior incident, unattended.
#
# No-ops immediately if the mount is healthy. Safe to run every couple of
# minutes via a systemd timer - each run is idempotent (pct stop/start,
# docker stop/start and umount/mount all tolerate already-in-that-state).
set -euo pipefail

MOUNT=/mnt/ssd2tb
DEVICE=/dev/sda1
LXCS="101 102 103 104 105 106 109 110 112 115"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

if ! findmnt -no OPTIONS "$MOUNT" | grep -q emergency_ro; then
  exit 0
fi

log "emergency_ro detected on $MOUNT - starting automated recovery"

for id in $LXCS; do
  log "stopping LXC $id"
  pct stop "$id" || log "WARNING: pct stop $id failed, continuing"
done

log "stopping homepage docker container"
docker stop homepage || log "WARNING: docker stop homepage failed, continuing"

log "unmounting $MOUNT"
umount "$MOUNT"

log "running e2fsck on $DEVICE"
set +e
e2fsck -f -y "$DEVICE"
FSCK_RC=$?
set -e
log "e2fsck exit code: $FSCK_RC"

# 0 = no errors, 1 = errors corrected - both fine to proceed automatically.
# Anything higher (2 = reboot needed, 4 = uncorrected errors, ...) means
# this needs a human, not another automated remount. Leave the volume
# unmounted and containers stopped rather than papering over it.
if [ "$FSCK_RC" -ge 2 ]; then
  log "CRITICAL: e2fsck returned $FSCK_RC (expected 0 or 1) - leaving $MOUNT unmounted and LXCs stopped for manual review, NOT remounting automatically"
  exit 1
fi

log "remounting $MOUNT"
mount "$MOUNT"

log "write test"
touch "$MOUNT/.autorecover_test" && rm "$MOUNT/.autorecover_test"

log "restarting nfs-kernel-server and pvestatd"
systemctl restart nfs-kernel-server pvestatd

log "starting homepage docker container"
docker start homepage || log "WARNING: docker start homepage failed, continuing"

for id in $LXCS; do
  log "starting LXC $id"
  pct start "$id" || log "WARNING: pct start $id failed, continuing"
done

log "automated recovery complete"
