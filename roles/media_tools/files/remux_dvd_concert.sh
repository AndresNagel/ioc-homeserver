#!/bin/bash
# Remux a single DVD-Video concert (VIDEO_TS structure) into a chaptered
# MKV, using ffmpeg's dvdvideo demuxer to read chapter timestamps straight
# from the disc's own PGC navigation data, and a companion plain-text
# tracklist to supply song titles - DVD chapters carry no text natively.
#
# Unlike remux_concerts.sh (BDMV, fully automatic), this is a manual,
# on-demand tool: DVD-Video rips are rare here, and "pick the longest
# title" is a weaker main-feature heuristic than BDMV's chapter-count one,
# so a human should sanity-check the pick (and the tracklist) before
# committing to a remux.
#
# Output lands in the same concerts_mkv/ directory as the BDMV pipeline, so
# the existing compress-concerts timer picks it up automatically and
# transcodes MPEG-2 -> HEVC on its next run - no separate compression step
# needed here.
#
# Usage:
#   remux_dvd_concert.sh <disc_dir> <tracklist_file> [title_number]
#
#   disc_dir        Folder containing VIDEO_TS/ (e.g. the raw torrent dir)
#   tracklist_file  Plain text, one song title per line, in chapter order
#   title_number    Optional: force a specific DVD title (1-99). If
#                   omitted, auto-picks the longest title among 1-8.
set -euo pipefail

OUT_DIR="/mnt/ssd2tb/media/concerts_mkv"
LOG_TAG="remux-dvd-concert"

disc_dir="${1:?usage: remux_dvd_concert.sh <disc_dir> <tracklist_file> [title_number]}"
tracklist_file="${2:?usage: remux_dvd_concert.sh <disc_dir> <tracklist_file> [title_number]}"
title_override="${3:-}"

video_ts_dir="$disc_dir/VIDEO_TS"
[ -d "$video_ts_dir" ] || { echo "no VIDEO_TS/ under '$disc_dir'" >&2; exit 1; }
[ -f "$tracklist_file" ] || { echo "tracklist file '$tracklist_file' not found" >&2; exit 1; }

name=$(basename "$disc_dir")
out_file="$OUT_DIR/${name}.mkv"
mkdir -p "$OUT_DIR"

if [ -e "$out_file" ]; then
  echo "'$out_file' already exists, skipping" >&2
  exit 0
fi

if [ -n "$title_override" ]; then
  title="$title_override"
else
  echo "auto-detecting main feature title (longest of titles 1-8)..." >&2
  title=""
  best_duration=0
  for t in 1 2 3 4 5 6 7 8; do
    duration=$(ffprobe -v error -f dvdvideo -title "$t" -i "$video_ts_dir" \
      -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 2>/dev/null || true)
    [ -z "$duration" ] && continue
    is_longer=$(python3 -c "print(1 if float('$duration') > $best_duration else 0)")
    if [ "$is_longer" = "1" ]; then
      best_duration="$duration"
      title="$t"
    fi
  done
  [ -n "$title" ] || { echo "no readable titles found on disc" >&2; exit 1; }
  echo "picked title $title (${best_duration}s)" >&2
fi

chapters_json_file=$(mktemp --suffix=.json)
chapters_meta=$(mktemp --suffix=.txt)
trap 'rm -f "$chapters_json_file" "$chapters_meta"' EXIT

# preindex forces a 2-pass read for accurate chapter boundaries - slower,
# but this only runs once per disc.
ffprobe -v error -f dvdvideo -title "$title" -preindex 1 -i "$video_ts_dir" \
  -show_chapters -of json > "$chapters_json_file"

python3 - "$tracklist_file" "$chapters_json_file" "$chapters_meta" <<'PYEOF'
import json, sys

tracklist_path, chapters_path, out_path = sys.argv[1:4]

with open(chapters_path) as f:
    chapters = json.load(f)["chapters"]

with open(tracklist_path) as f:
    titles = [line.strip() for line in f if line.strip()]

if len(titles) != len(chapters):
    sys.exit(
        f"chapter count ({len(chapters)}) != tracklist line count "
        f"({len(titles)}) - check title selection or tracklist"
    )

with open(out_path, "w") as out:
    out.write(";FFMETADATA1\n")
    for chapter, title in zip(chapters, titles):
        start_ms = round(float(chapter["start_time"]) * 1000)
        end_ms = round(float(chapter["end_time"]) * 1000)
        out.write(
            f"\n[CHAPTER]\nTIMEBASE=1/1000\nSTART={start_ms}\nEND={end_ms}\ntitle={title}\n"
        )
PYEOF

# The dvdvideo demuxer's audio stream order does not necessarily match the
# DVD's own "best" track - e.g. it has been observed listing a stereo
# downmix as a:0 and the real 5.1 mix as a:1. Pick whichever audio stream
# has the most channels rather than assuming index 0.
audio_streams_json_file=$(mktemp --suffix=.json)
trap 'rm -f "$chapters_json_file" "$chapters_meta" "$audio_streams_json_file"' EXIT
ffprobe -v error -f dvdvideo -title "$title" -i "$video_ts_dir" \
  -select_streams a -show_entries stream=index,codec_name,channels -of json > "$audio_streams_json_file"
read -r audio_stream_index audio_codec <<< "$(python3 -c "
import json
streams = json.load(open('$audio_streams_json_file'))['streams']
best = max(streams, key=lambda s: s.get('channels', 0))
print(streams.index(best), best['codec_name'])
")"

# Matroska has no codec tag for pcm_dvd (DVD's raw LPCM variant, distinct
# from Blu-ray's), so ffmpeg's muxer refuses to write it via -c:a copy.
# Repack losslessly to pcm_s16le in that case - same samples, just a
# container-compatible header.
if [ "$audio_codec" = "pcm_dvd" ]; then
  audio_codec_args=(-c:a pcm_s16le)
else
  audio_codec_args=(-c:a copy)
fi

tmp_out="$out_file.tmp"
logger -t "$LOG_TAG" "remuxing '$disc_dir' (title $title, audio a:$audio_stream_index/$audio_codec) -> '$out_file'"
if ffmpeg -hide_banner -loglevel warning -y -nostdin \
    -f dvdvideo -title "$title" -i "$video_ts_dir" \
    -f ffmetadata -i "$chapters_meta" \
    -map_chapters 1 -map 0:v:0 -map "0:a:$audio_stream_index" \
    -c:v copy "${audio_codec_args[@]}" \
    -f matroska \
    "$tmp_out"; then
  mv "$tmp_out" "$out_file"
  echo "done: $out_file"
else
  logger -t "$LOG_TAG" "FAILED: '$disc_dir'"
  rm -f "$tmp_out"
  exit 1
fi
