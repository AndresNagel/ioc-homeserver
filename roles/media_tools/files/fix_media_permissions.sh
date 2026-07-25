#!/bin/bash
# Sonarr/Radarr/Bazarr/Transmission each write into the shared library dirs
# from their own LXC's uid namespace, so per-title folders land as e.g.
# 755 root:root - fine for the app that created them, but Jellyfin (an
# unprivileged uid in its own container) then has no write bit on that
# directory and can't delete or rename anything inside it. The library
# root dirs themselves are already 777 for this reason; this just extends
# that same world-writable convention down into every subfolder.
set -euo pipefail

LIBRARY_DIRS=(
  "/mnt/ssd2tb/media/movies"
  "/mnt/ssd2tb/media/concerts"
  "/mnt/ssd2tb/media/concerts_mkv"
  "/mnt/ssd2tb/media/music"
  "/mnt/ssd2tb/series"
)

for dir in "${LIBRARY_DIRS[@]}"; do
  [ -d "$dir" ] || continue
  find "$dir" -type d ! -perm -002 -exec chmod o+w {} +
done
