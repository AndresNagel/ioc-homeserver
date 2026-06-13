#!/bin/bash
# Re-encode the chaptered concert MKVs (output of remux_concerts.sh) from
# their original Blu-ray bitrate (~35 Mbps H.264 + PCM) down to a bitrate
# that streams comfortably over WiFi, using the host's QuickSync iGPU.
#
# Skips any file whose video codec is already HEVC — that's the signature
# of a previous run of this script, since the BDMV remux always produces
# H.264. Idempotent and safe to re-run as new concerts are added by
# remux_concerts.sh. Replaces the file in place once the re-encode
# succeeds, so concerts_mkv/ stays a single directory for Jellyfin.
#
# Chapters and subtitle tracks are preserved; audio is downmixed from PCM
# to AAC (PCM is only ~2 Mbps and not the bottleneck, but AAC avoids
# Jellyfin re-transcoding audio on every playback too).
set -euo pipefail

CONCERTS_MKV_DIR="/mnt/ssd2tb/media/concerts_mkv"
VAAPI_DEVICE="/dev/dri/renderD128"
VIDEO_BITRATE="9M"
MAX_BITRATE="10M"
BUFSIZE="20M"
LOG_TAG="compress-concerts"

for f in "$CONCERTS_MKV_DIR"/*.mkv; do
  [ -e "$f" ] || continue

  vcodec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
    -of default=nokey=1:noprint_wrappers=1 "$f")

  if [ "$vcodec" = "hevc" ]; then
    continue
  fi

  tmp_out="$f.hevc.tmp"

  logger -t "$LOG_TAG" "compressing '$f' (codec=$vcodec) -> HEVC ${VIDEO_BITRATE}bps"
  if ffmpeg -hide_banner -loglevel warning -y \
      -hwaccel vaapi -hwaccel_device "$VAAPI_DEVICE" -hwaccel_output_format vaapi \
      -i "$f" \
      -map 0 \
      -c:v hevc_vaapi -b:v "$VIDEO_BITRATE" -maxrate "$MAX_BITRATE" -bufsize "$BUFSIZE" \
      -c:a aac -b:a 192k \
      -c:s copy \
      -f matroska \
      "$tmp_out"; then
    mv "$tmp_out" "$f"
  else
    logger -t "$LOG_TAG" "FAILED: '$f'"
    rm -f "$tmp_out"
  fi
done
