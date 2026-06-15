#!/bin/bash
# Enforce a 1080p/HEVC video ceiling and stereo-AAC audio ceiling across the
# Sonarr/Radarr libraries, using the host's QuickSync iGPU for any video
# re-encodes.
#
# Per file, a single ffprobe pass reports the primary video stream's height
# and every audio stream's channel count:
#   - height > 1080  -> re-encode video via VAAPI to 1080p HEVC
#   - audio channels > 2 -> re-encode that audio stream to AAC stereo
#   - everything else stays -c copy (zero-cost remux)
#
# Files that are already fully compliant are skipped entirely - no ffmpeg
# invocation at all, which matters for a daily timer over a large library.
#
# Concerts (remux_concerts.sh/compress_concerts.sh) and music are handled
# separately and excluded here. Atomic in-place replace via a temp file.
set -euo pipefail

LIBRARY_DIRS=(
  "/mnt/ssd2tb/media/movies"
  "/mnt/ssd2tb/series"
)
VAAPI_DEVICE="/dev/dri/renderD128"
VIDEO_BITRATE="9M"
MAX_BITRATE="10M"
BUFSIZE="20M"
LOG_TAG="normalize-media"

probe() {
  ffprobe -v error -show_entries stream=codec_type,height,channels -of json "$1" \
    | python3 -c '
import json, sys
try:
    streams = json.load(sys.stdin)["streams"]
except (json.JSONDecodeError, KeyError):
    sys.exit(1)
height = "na"
audio = []
for s in streams:
    if s["codec_type"] == "video" and height == "na":
        height = str(s.get("height", "na"))
    elif s["codec_type"] == "audio":
        audio.append(str(s.get("channels", "na")))
print(height)
for ch in audio:
    print(ch)
'
}

for dir in "${LIBRARY_DIRS[@]}"; do
  find "$dir" -type f \( -iname '*.mkv' -o -iname '*.mp4' \) -print0
done | while IFS= read -r -d '' f; do
  if [ ! -f "$f" ]; then
    logger -t "$LOG_TAG" "skipping '$f': file no longer exists"
    continue
  fi

  if ! probe_out=$(probe "$f"); then
    logger -t "$LOG_TAG" "skipping '$f': ffprobe failed"
    continue
  fi

  mapfile -t info <<< "$probe_out"
  height="${info[0]}"
  audio_channels=("${info[@]:1}")

  needs_video=0
  if [ "$height" != "na" ] && [ "$height" -gt 1080 ]; then
    needs_video=1
  fi

  audio_args=()
  needs_audio=0
  for i in "${!audio_channels[@]}"; do
    ch="${audio_channels[$i]}"
    if [ "$ch" != "na" ] && [ "$ch" -gt 2 ]; then
      audio_args+=(-c:a:"$i" aac -ac:a:"$i" 2 -b:a:"$i" 192k)
      needs_audio=1
    fi
  done

  if [ "$needs_video" -eq 0 ] && [ "$needs_audio" -eq 0 ]; then
    continue
  fi

  ext="${f##*.}"
  ext_lower="${ext,,}"
  tmp_out="$f.normalize.tmp.$ext"

  hwaccel_args=()
  video_args=()
  if [ "$needs_video" -eq 1 ]; then
    hwaccel_args=(-hwaccel vaapi -hwaccel_device "$VAAPI_DEVICE" -hwaccel_output_format vaapi)
    video_args=(-vf scale_vaapi=w=-2:h=1080 -c:v:0 hevc_vaapi -b:v "$VIDEO_BITRATE" -maxrate "$MAX_BITRATE" -bufsize "$BUFSIZE")
  fi

  if [ "$ext_lower" = "mp4" ]; then
    map_args=(-map 0:v -map 0:a)
    fmt_args=(-f mp4)
  else
    map_args=(-map 0)
    fmt_args=(-f matroska)
  fi

  logger -t "$LOG_TAG" "normalizing '$f' (height=$height video=$needs_video audio=$needs_audio)"
  if ffmpeg -hide_banner -loglevel warning -y \
      "${hwaccel_args[@]}" \
      -i "$f" \
      "${map_args[@]}" \
      -c copy \
      "${video_args[@]}" \
      "${audio_args[@]}" \
      "${fmt_args[@]}" \
      "$tmp_out"; then
    mv "$tmp_out" "$f"
  else
    logger -t "$LOG_TAG" "FAILED: '$f'"
    rm -f "$tmp_out"
  fi
done
