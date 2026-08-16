#!/usr/bin/env python3
# Regenerates the static status page + summary.json that
# media-status.welpes.com and the Homepage widget read, from
# normalize_media.sh's history.jsonl. Called once at the end of every
# normalize_media.sh run (success, failure, or disk-fault interruption) -
# not on a timer, since there's nothing new to show between runs.
import json
import time
from pathlib import Path

HISTORY_LOG = Path("/var/lib/normalize-media/history.jsonl")
REPORT_DIR = Path("/var/lib/normalize-media/report")
MAX_ROWS_SHOWN = 200


def human_size(n):
    if n is None:
        return "-"
    n = float(n)
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if abs(n) < 1024:
            return f"{n:.1f}{unit}"
        n /= 1024
    return f"{n:.1f}PB"


def load_entries():
    if not HISTORY_LOG.exists():
        return []
    entries = []
    for line in HISTORY_LOG.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return entries


def main():
    entries = load_entries()
    entries.sort(key=lambda e: e["ts"], reverse=True)

    now = time.localtime()
    today_start = time.mktime((now.tm_year, now.tm_mon, now.tm_mday, 0, 0, 0, 0, 0, -1))
    today_entries = [e for e in entries if e["ts"] >= today_start]
    today_saved = sum(
        (e["before"] - e["after"])
        for e in today_entries
        if e["status"] == "success" and e.get("before") and e.get("after")
    )
    today_success = sum(1 for e in today_entries if e["status"] == "success")
    today_failed = sum(1 for e in today_entries if e["status"] in ("failed", "fault"))

    total_saved = sum(
        (e["before"] - e["after"])
        for e in entries
        if e["status"] == "success" and e.get("before") and e.get("after")
    )
    total_success = sum(1 for e in entries if e["status"] == "success")

    last = entries[0] if entries else None

    summary = {
        "last_status": last["status"] if last else "none",
        "last_file": Path(last["file"]).name if last else None,
        "last_time": last["ts"] if last else None,
        "today_files": today_success,
        "today_failed": today_failed,
        "today_saved_bytes": today_saved,
        "today_saved_human": human_size(today_saved),
        "total_files": total_success,
        "total_saved_bytes": total_saved,
        "total_saved_human": human_size(total_saved),
    }

    STATUS_BADGE = {
        "success": '<span style="color:#2a2">✅ success</span>',
        "failed": '<span style="color:#c33">❌ failed</span>',
        "fault": '<span style="color:#c93">⚠️ disk fault</span>',
    }

    rows = []
    for e in entries[:MAX_ROWS_SHOWN]:
        when = time.strftime("%Y-%m-%d %H:%M", time.localtime(e["ts"]))
        name = Path(e["file"]).name
        before = human_size(e.get("before"))
        after = human_size(e.get("after"))
        saved = (
            human_size(e["before"] - e["after"])
            if e["status"] == "success" and e.get("before") and e.get("after")
            else "-"
        )
        badge = STATUS_BADGE.get(e["status"], e["status"])
        rows.append(
            f"<tr><td>{when}</td><td>{name}</td><td>{before}</td>"
            f"<td>{after}</td><td>{saved}</td><td>{badge}</td></tr>"
        )

    html = f"""<!doctype html>
<html><head><meta charset="utf-8">
<title>Normalize Media Status</title>
<meta http-equiv="refresh" content="120">
<style>
body {{ font-family: system-ui, sans-serif; margin: 2rem; background: #111; color: #eee; }}
h1 {{ font-size: 1.3rem; }}
.stats {{ display: flex; gap: 2rem; margin-bottom: 1.5rem; flex-wrap: wrap; }}
.stat {{ background: #1c1c1c; padding: 0.75rem 1.25rem; border-radius: 8px; }}
.stat b {{ display: block; font-size: 1.4rem; }}
table {{ border-collapse: collapse; width: 100%; font-size: 0.9rem; }}
th, td {{ text-align: left; padding: 0.4rem 0.8rem; border-bottom: 1px solid #333; }}
th {{ color: #999; font-weight: normal; }}
</style></head>
<body>
<h1>normalize_media.sh — processed files</h1>
<div class="stats">
  <div class="stat">Today<b>{today_success} files</b></div>
  <div class="stat">Saved today<b>{human_size(today_saved)}</b></div>
  <div class="stat">Total saved<b>{human_size(total_saved)}</b></div>
  <div class="stat">Last run<b>{STATUS_BADGE.get(summary["last_status"], summary["last_status"])}</b></div>
</div>
<table>
<tr><th>When</th><th>File</th><th>Before</th><th>After</th><th>Saved</th><th>Status</th></tr>
{''.join(rows) if rows else '<tr><td colspan="6">No runs recorded yet</td></tr>'}
</table>
</body></html>
"""

    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    (REPORT_DIR / "index.html").write_text(html)
    (REPORT_DIR / "summary.json").write_text(json.dumps(summary))


if __name__ == "__main__":
    main()
