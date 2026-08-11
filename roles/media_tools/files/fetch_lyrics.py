#!/usr/bin/env python3
# Scans the music library for audio files missing a .lrc sidecar and looks
# up synced lyrics from LRCLIB (https://lrclib.net, free/keyless). Uses only
# the exact-match /api/get endpoint - not the fuzzy /api/search - so cover
# versions and live recordings that don't match a studio original verbatim
# (e.g. Malón playing Hermética songs) are deliberately left with no .lrc
# rather than getting the wrong song's lyrics written over them. Those stay
# visibly blank for a manual tap-to-sync fix. Safe to re-run: any file that
# already has a .lrc (auto-fetched or hand-written) is left alone.
import json
import subprocess
import sys
import syslog
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

MUSIC_DIR = Path("/mnt/ssd2tb/media/music")
AUDIO_EXTENSIONS = {".mp3", ".flac", ".m4a", ".ogg", ".opus", ".wav"}
LRCLIB_GET_URL = "https://lrclib.net/api/get"
REQUEST_DELAY_SECONDS = 0.3
USER_AGENT = "homeserver-lyrics-fetch/1.0 (self-hosted, personal use)"

# Logs to syslog (visible via `journalctl -t fetch-lyrics -f`) regardless of
# how the script is invoked - systemd timer, ansible async on-demand run, or
# by hand - matching normalize_media.sh's `logger -t` convention rather than
# relying on stdout capture, which only works when launched via systemd.
syslog.openlog(ident="fetch-lyrics")


def log(message: str) -> None:
    syslog.syslog(message)
    print(message)


def ffprobe_tags(path: Path) -> dict:
    result = subprocess.run(
        ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", str(path)],
        capture_output=True,
        text=True,
        check=True,
    )
    fmt = json.loads(result.stdout).get("format", {})
    tags = {k.lower(): v for k, v in fmt.get("tags", {}).items()}
    return {
        "artist": tags.get("artist", ""),
        "title": tags.get("title", ""),
        "album": tags.get("album", ""),
        "duration": float(fmt.get("duration", 0)),
    }


def fetch_lyrics(artist: str, title: str, album: str, duration: float):
    params = {
        "artist_name": artist,
        "track_name": title,
        "album_name": album,
        "duration": str(round(duration)),
    }
    url = f"{LRCLIB_GET_URL}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise
    return data.get("syncedLyrics") or data.get("plainLyrics") or None


def main() -> int:
    if not MUSIC_DIR.is_dir():
        print(f"Music dir {MUSIC_DIR} not found", file=sys.stderr)
        return 1

    written = skipped = no_match = missing_tags = errors = 0
    for path in sorted(MUSIC_DIR.rglob("*")):
        if path.suffix.lower() not in AUDIO_EXTENSIONS:
            continue

        lrc_path = path.with_suffix(".lrc")
        if lrc_path.exists():
            skipped += 1
            continue

        try:
            tags = ffprobe_tags(path)
        except (subprocess.CalledProcessError, json.JSONDecodeError) as exc:
            log(f"ERROR reading tags: {path} ({exc})")
            errors += 1
            continue

        if not tags["artist"] or not tags["title"]:
            log(f"MISSING TAGS: {path}")
            missing_tags += 1
            continue

        try:
            lyrics = fetch_lyrics(tags["artist"], tags["title"], tags["album"], tags["duration"])
        except (urllib.error.URLError, TimeoutError) as exc:
            log(f"ERROR fetching lyrics: {path} ({exc})")
            errors += 1
            continue
        time.sleep(REQUEST_DELAY_SECONDS)

        if not lyrics:
            log(f"NO MATCH: {path}")
            no_match += 1
            continue

        lrc_path.write_text(lyrics, encoding="utf-8")
        log(f"WROTE: {lrc_path}")
        written += 1

    log(
        f"Done. {written} written, {skipped} already had lyrics, "
        f"{no_match} no exact match (cover/live? needs a manual .lrc), "
        f"{missing_tags} missing artist/title tags, {errors} errors."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
