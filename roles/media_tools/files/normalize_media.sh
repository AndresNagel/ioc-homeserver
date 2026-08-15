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
# A single backlog pass (e.g. after this script was stuck for days) can run
# for many hours - long enough to spill past the night window it started in
# and collide with evening viewing. Stop cleanly once we cross into morning;
# next night's run picks up wherever this one left off.
# Overridable via env for an on-demand manual run outside the night window
# (e.g. NIGHT_START_HOUR=0 NIGHT_END_HOUR=24 to disable the guard entirely).
NIGHT_START_HOUR="${NIGHT_START_HOUR:-1}"
NIGHT_END_HOUR="${NIGHT_END_HOUR:-7}"
TORRENTS_DIR="/mnt/ssd2tb/torrents"
SSD2TB_MOUNT="/mnt/ssd2tb"
TRANSMISSION_RPC="http://192.168.1.103:9091/transmission/rpc"
VAAPI_DEVICE="/dev/dri/renderD128"
VIDEO_BITRATE="9M"
MAX_BITRATE="10M"
BUFSIZE="20M"
LOG_TAG="normalize-media"
HISTORY_LOG="/var/lib/normalize-media/history.jsonl"
REPORT_SCRIPT="/usr/local/bin/normalize_media_report.py"

mkdir -p "$(dirname "$HISTORY_LOG")"

# Appends one line per processed file (success/failed/fault) for the
# media-status.welpes.com report - not called for skipped/already-compliant
# files, only real attempts. Keeps the log bounded so it never grows
# unbounded across months of nightly runs.
log_history() {
  python3 -c '
import json, sys, time
f, before, after, status = sys.argv[1:5]
print(json.dumps({
    "ts": time.time(),
    "file": f,
    "before": int(before) if before != "-" else None,
    "after": int(after) if after != "-" else None,
    "status": status,
}))
' "$@" >> "$HISTORY_LOG"
  tail -n 1000 "$HISTORY_LOG" > "$HISTORY_LOG.tmp" && mv "$HISTORY_LOG.tmp" "$HISTORY_LOG"
  # Regenerate immediately (not just at end-of-run) so the status page shows
  # live progress during a long backlog pass instead of looking stale/empty
  # until the whole run finishes. Cheap (small file), non-fatal on failure.
  python3 "$REPORT_SCRIPT" || logger -t "$LOG_TAG" "report generation failed (non-fatal)"
}

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
# Written by the find/while loop below with find's own exit status, since
# process substitution otherwise hides that from the script entirely - see
# the loop's setup comment for why that's normally desirable but leaves a
# real find failure (e.g. an I/O error mid-scan) silently indistinguishable
# from "backlog fully processed".
FIND_STATUS_FILE="$(mktemp)"
trap 'rm -f "$ACTIVE_TORRENT_FILES" "$FIND_STATUS_FILE"' EXIT
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

# A prior run that was killed mid-encode (e.g. the disk itself timing out
# mid-write) can leave its "$f.normalize.tmp.$ext" behind. That name still
# matches the *.mkv/*.mp4 glob below, so a later run would probe the
# corrupt partial file as if it were a real library file. Clear any of
# these out first rather than let them show up as spurious ffprobe-failed
# skips every run.
for dir in "${LIBRARY_DIRS[@]}"; do
  find "$dir" -type f -iname '*.normalize.tmp.*' -delete
done

# See project memory: /mnt/ssd2tb sits on a drive with recurring
# emergency_ro faults that ssd2tb-autorecover.timer (roles/proxmox_host)
# detects and clears, typically within ~1 minute - but only once nothing on
# the host still has the mount open. A write failing here because the fs
# just went read-only out from under us is a transient, recoverable
# condition - not the same as a genuine ffmpeg failure (bad input,
# unsupported codec, etc.) which should just be skipped - so this tells the
# two apart and stops the whole run immediately on the former rather than
# cascading the same failure through the rest of the library.
#
# Deliberately does NOT wait/retry in place: an earlier version did, and on
# 2026-07-26 that backfired for real - staying alive kept the upstream
# `find` (its stdout feeds this file's while-read loop) holding an open fd
# under /mnt/ssd2tb, which made autorecover's own `umount` fail with
# "target is busy" and pushed recovery from ~1 minute out to 6+. Returning
# immediately lets this whole pipeline (including `find`) exit within
# seconds, so autorecover's next 2-minute tick finds the mount actually
# free. Any files left un-normalized just get picked up by the next
# scheduled/on-demand run.
mount_is_healthy() {
  local opts
  opts=$(findmnt -no OPTIONS "$SSD2TB_MOUNT" 2>/dev/null) || return 1
  [[ ",$opts," == *,rw,* && "$opts" != *emergency_ro* ]]
}

# Process substitution (not a `| while`) deliberately: the loop below can
# `break` early (night-window boundary, disk-fault stop) while find still
# has buffered output. In a real pipeline, that SIGPIPEs find and, combined
# with pipefail above, fails the whole script even though the early stop is
# intentional/expected. Process substitution keeps find's exit status out
# of the script's own, so an intentional stop stays a clean exit - but that
# also hides a genuine find failure (e.g. an I/O error mid-scan during an
# ssd2tb fault), which would otherwise look identical to "nothing left to
# do". find_rc below, checked after the loop, recovers that signal.
while IFS= read -r -d '' f; do
  hour="$(date +%H)"
  if [ "$((10#$hour))" -lt "$NIGHT_START_HOUR" ] || [ "$((10#$hour))" -ge "$NIGHT_END_HOUR" ]; then
    logger -t "$LOG_TAG" "outside night window (${NIGHT_START_HOUR}:00-${NIGHT_END_HOUR}:00), stopping for tonight"
    break
  fi

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

  try_write_once() {
    ffmpeg -hide_banner -loglevel warning -y -nostdin \
        "${hwaccel_args[@]}" \
        -i "$f" \
        "${map_args[@]}" \
        -c copy \
        "${video_args[@]}" \
        "${audio_args[@]}" \
        "${fmt_args[@]}" \
        "$tmp_out" && mv "$tmp_out" "$f"
  }

  # 0 = wrote successfully, 1 = genuine failure (skip, move on), 2 = ssd2tb
  # is unhealthy (stop the whole run immediately - see mount_is_healthy's
  # comment for why this must NOT wait/retry in place).
  attempt_normalize() {
    if try_write_once; then
      [ "$old_nlink" -gt 1 ] && cleanup_orphaned_original "$old_inode"
      return 0
    fi
    rm -f "$tmp_out"

    if mount_is_healthy; then
      return 1
    fi

    logger -t "$LOG_TAG" "'$f': write failed and ssd2tb is unhealthy - stopping run for tonight (ssd2tb-autorecover.timer will fix it)"
    return 2
  }

  logger -t "$LOG_TAG" "normalizing '$f' (height=$height video=$needs_video audio=$needs_audio)"
  before_size=$(stat -c %s "$f")
  rc=0
  attempt_normalize || rc=$?
  if [ "$rc" -eq 0 ]; then
    log_history "$f" "$before_size" "$(stat -c %s "$f")" "success"
  elif [ "$rc" -eq 1 ]; then
    logger -t "$LOG_TAG" "FAILED: '$f'"
    log_history "$f" "$before_size" "-" "failed"
  elif [ "$rc" -eq 2 ]; then
    log_history "$f" "$before_size" "-" "fault"
    break
  fi
done < <(
  find_rc=0
  for dir in "${LIBRARY_DIRS[@]}"; do
    find "$dir" -type f \( -iname '*.mkv' -o -iname '*.mp4' \) ! -iname '*.normalize.tmp.*' -print0 || find_rc=$?
  done
  echo "$find_rc" > "$FIND_STATUS_FILE"
)

# Unlike the per-file write-failure check, this isn't checked against
# mount_is_healthy(): by the time the while loop finishes draining whatever
# find had already buffered, an ssd2tb fault that caused this has typically
# already self-healed (autorecover fixes it in ~1min), so "is it healthy
# now" wouldn't reliably tell transient from genuine anyway. Whatever the
# cause, the library scan didn't finish and some files may have been
# missed - always surface that loudly rather than let it pass as a normal
# "nothing left to do" completion. The next scheduled/on-demand run will
# naturally retry the ones that were missed.
find_rc="$(cat "$FIND_STATUS_FILE" 2>/dev/null)"
if [ -n "$find_rc" ] && [ "$find_rc" -ne 0 ]; then
  logger -t "$LOG_TAG" "find exited with status $find_rc while scanning the library - run is INCOMPLETE, see dmesg/journal for the cause"
fi

# Regenerate the status page/summary regardless of how the run ended
# (finished the backlog, hit a genuine failure, or got cut short by a disk
# fault) - there's always something new to show. Non-fatal: a report bug
# should never be mistaken for a normalize_media.sh failure.
python3 "$REPORT_SCRIPT" || logger -t "$LOG_TAG" "report generation failed (non-fatal)"

exit "${find_rc:-0}"
