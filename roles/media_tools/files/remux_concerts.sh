#!/bin/bash
# Remux BDMV Blu-ray concert rips into single chaptered MKV files so
# Jellyfin clients can navigate between songs.
#
# Chapters come from the Blu-ray's own PlayMarks (concert discs mark each
# song as a chapter) via mkvmerge's native .mpls reader — no manual chapter
# authoring needed. Video/audio streams are passed through unchanged.
#
# Idempotent: skips any concert that already has an output file, so this is
# safe to run repeatedly (e.g. from a systemd timer) as new BD rips are added.
set -euo pipefail

CONCERTS_DIR="/mnt/ssd2tb/media/concerts"
OUT_DIR="/mnt/ssd2tb/media/concerts_mkv"
LOG_TAG="remux-concerts"

mkdir -p "$OUT_DIR"

find "$CONCERTS_DIR" -type d -path "*/BDMV/PLAYLIST" -print0 | while IFS= read -r -d '' playlist_dir; do
  bdmv_dir=$(dirname "$playlist_dir")
  disc_dir=$(dirname "$bdmv_dir")

  name=$(realpath --relative-to="$CONCERTS_DIR" "$disc_dir" | tr '/' '-')
  out_file="$OUT_DIR/${name}.mkv"

  if [ -e "$out_file" ]; then
    continue
  fi

  # Pick the playlist with the most chapter marks — the main feature.
  # Menu loops / extras typically have 0-1 chapters.
  best_mpls=""
  best_chapters=-1
  for mpls in "$playlist_dir"/*.mpls; do
    chapters=$(mkvmerge -J "$mpls" | python3 -c '
import json, sys
d = json.load(sys.stdin)
ch = d.get("chapters") or []
print(ch[0]["num_entries"] if ch else 0)
')
    if [ "$chapters" -gt "$best_chapters" ]; then
      best_chapters=$chapters
      best_mpls=$mpls
    fi
  done

  if [ -z "$best_mpls" ]; then
    logger -t "$LOG_TAG" "no playlists found under $playlist_dir, skipping"
    continue
  fi

  logger -t "$LOG_TAG" "remuxing '$disc_dir' -> '$out_file' ($best_chapters chapters)"
  if mkvmerge -o "$out_file.tmp" "$best_mpls"; then
    mv "$out_file.tmp" "$out_file"
  else
    logger -t "$LOG_TAG" "FAILED: '$disc_dir'"
    rm -f "$out_file.tmp"
  fi
done
