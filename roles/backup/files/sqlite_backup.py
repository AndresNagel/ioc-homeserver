#!/usr/bin/env python3
# Hot-copies SQLite databases via the .backup command (safe even while the
# owning app is writing to them), preserving their relative path under root.
# Files matched by extension but that aren't actually SQLite (e.g. a leftover
# BoltDB file named *.db) are copied as-is instead.
import os
import shutil
import subprocess
import sys

root, stage, *databases = sys.argv[1:]

for src in databases:
    rel = os.path.relpath(src, root)
    dest = os.path.join(stage, rel)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    result = subprocess.run(["sqlite3", src, f".backup '{dest}'"], capture_output=True, text=True)
    if result.returncode != 0:
        shutil.copy2(src, dest)
