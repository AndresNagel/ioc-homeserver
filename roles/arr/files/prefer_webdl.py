#!/usr/bin/env python3
"""Move each WEB(-DL/Rip) quality group above the Bluray/Remux entries of the
same resolution in every quality profile.

By default Radarr/Sonarr rank Bluray/Remux above WEB-DL at each resolution,
so a same-resolution Bluray/Remux release is preferred when both are
available. Those releases usually carry the original disc's image-based
(PGS/VobSub) subtitle tracks, which Jellyfin can't send to a client as a
soft subtitle - it has to burn them into the video via a full transcode.
WEB-DL/WEBRip releases essentially never carry those tracks, so preferring
them avoids the problem at the source. This only affects future grabs;
existing library files are untouched.

Usage: prefer_webdl.py <port> <api_key>
Prints "changed" if any profile was reordered, "ok" otherwise.
"""
import json
import re
import sys
import urllib.request

port, api_key = sys.argv[1], sys.argv[2]
base = f"http://localhost:{port}/api/v3/qualityprofile"


def call(url, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url, data=data, method=method,
        headers={"X-Api-Key": api_key, "Content-Type": "application/json"},
    )
    return json.loads(urllib.request.urlopen(req).read().decode())


def qname(item):
    return item["name"] if item.get("name") else item["quality"]["name"]


def resnum(name):
    m = re.search(r"(\d+p)$", name)
    return m.group(1) if m else None


def reorder(items):
    n = len(items)
    out = []
    changed = False
    i = 0
    while i < n:
        it = items[i]
        name = qname(it)
        if name.startswith("WEB "):
            res = resnum(name)
            j = i + 1
            block = []
            while j < n:
                nm = qname(items[j])
                if resnum(nm) == res and (nm.startswith("Bluray") or nm.startswith("Remux")):
                    block.append(items[j])
                    j += 1
                else:
                    break
            if block:
                changed = True
            out.extend(block)
            out.append(it)
            i = j
        else:
            out.append(it)
            i += 1
    return out, changed


profiles = call(base)
any_changed = False
for p in profiles:
    new_items, changed = reorder(p["items"])
    if changed:
        p["items"] = new_items
        call(f"{base}/{p['id']}", method="PUT", body=p)
        any_changed = True

print("changed" if any_changed else "ok")
