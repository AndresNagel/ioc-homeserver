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
#
# Caveat: the atomic replace (mv tmp -> original) gives the library file a
# new inode, breaking any hardlink Radarr/Sonarr made back to the original
# download under /mnt/ssd2tb/torrents. That leaves a full-size, now-orphaned
# copy of the pre-normalize file sitting in the torrents tree forever. After
# a successful replace, if the original had nlink>1, find the other link(s)
# under TORRENTS_DIR and delete them - unless Transmission is still actively
# seeding/downloading that exact file, in which case it's left alone.
set -euo pipefail

LIBRARY_DIRS=(
  "/mnt/ssd2tb/media/movies"
  "/mnt/ssd2tb/series"
)
TORRENTS_DIR="/mnt/ssd2tb/torrents"
TRANSMISSION_RPC="http://192.168.1.103:9091/transmission/rpc"
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

# One-shot fetch of every file path Transmission currently knows about
# (downloading or seeding), mapped from its /data/... view to host paths.
# On any failure, leave this empty - cleanup_orphaned_original() then skips
# deletion entirely rather than risk removing an active torrent's data.
ACTIVE_TORRENT_FILES="$(mktemp)"
trap 'rm -f "$ACTIVE_TORRENT_FILES"' EXIT
python3 - > "$ACTIVE_TORRENT_FILES" 2>/dev/null <<'PYEOF' || : > "$ACTIVE_TORRENT_FILES"
import json, urllib.request, urllib.error

RPC = "http://192.168.1.103:9091/transmission/rpc"
PAYLOAD = json.dumps({"method": "torrent-get", "arguments": {"fields": ["downloadDir", "files"]}}).encode()

def call(session_id=None):
    req = urllib.request.Request(RPC, data=PAYLOAD, method="POST")
    if session_id:
        req.add_header("X-Transmission-Session-Id", session_id)
    return urllib.request.urlopen(req, timeout=10)

try:
    resp = call()
except urllib.error.HTTPError as e:
    if e.code != 409:
        raise
    resp = call(e.headers.get("X-Transmission-Session-Id"))

data = json.load(resp)
for t in data["arguments"]["torrents"]:
    dl = t["downloadDir"]
    if dl.startswith("/data/"):
        dl = "/mnt/ssd2tb/" + dl[len("/data/"):]
    for f in t["files"]:
        print(f"{dl}/{f['name']}")
PYEOF

cleanup_orphaned_original() {
  local inode="$1"
  if [ ! -s "$ACTIVE_TORRENT_FILES" ] && [ ! -e "$ACTIVE_TORRENT_FILES" ]; then
    return
  fi
  while IFS= read -r -d '' orphan; do
    if grep -qxF "$orphan" "$ACTIVE_TORRENT_FILES"; then
      logger -t "$LOG_TAG" "keeping pre-normalize copy '$orphan' (active in Transmission)"
    else
      logger -t "$LOG_TAG" "removing orphaned pre-normalize copy '$orphan'"
      rm -f -- "$orphan"
    fi
  done < <(find "$TORRENTS_DIR" -xdev -inum "$inode" -print0 2>/dev/null)
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

  old_inode=$(stat -c %i "$f")
  old_nlink=$(stat -c %h "$f")

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
    if [ "$old_nlink" -gt 1 ]; then
      cleanup_orphaned_original "$old_inode"
    fi
  else
    logger -t "$LOG_TAG" "FAILED: '$f'"
    rm -f "$tmp_out"
  fi
done
