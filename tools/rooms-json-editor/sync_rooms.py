#!/usr/bin/env python3
"""rooms.json is the source of truth for the saved Rooms JSON.

Run this after editing rooms.json (or after pasting a new config into it). It rewrites rooms.min.json (the single
line you paste into Composer) and updates the LIVE value embedded in index.html, so the editor opens on the same
config. Standard library only:   python3 sync_rooms.py
"""
import json, os, re, sys

here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, "rooms.json")
data = json.load(open(src, encoding="utf-8"))
mini = json.dumps(data, separators=(",", ":"), ensure_ascii=False)
if "'" in mini or "\\" in mini:
    sys.exit("rooms.json contains a quote or backslash that the editor cannot embed; remove it.")
json.dump(data, open(src, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
open(src, "a", encoding="utf-8").write("\n")
open(os.path.join(here, "rooms.min.json"), "w", encoding="utf-8").write(mini + "\n")

page = os.path.join(here, "index.html")
html = open(page, encoding="utf-8").read()
new, n = re.subn(r"(var LIVE = ')[^']*(';)", lambda m: m.group(1) + mini + m.group(2), html, count=1)
if n != 1:
    sys.exit("could not find the LIVE value in index.html")
open(page, "w", encoding="utf-8").write(new)
print("updated rooms.json, rooms.min.json and index.html")
