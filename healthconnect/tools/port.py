#!/usr/bin/env python3
"""One-shot: Health Connect export -> Venu-2S FIT files (-> optional upload).

  port.py "Health Connect.zip" --templates ../templates --since 2026-11-20 --out ../out
  port.py ... --upload            # then hand the FITs to upload.py

--templates is a folder of real FITs from your watch (Garmin Connect > activity >
gear > Export Original). One walk and one strength file is enough; the walk one
is used for every GPS/"moving" sport, the strength one for everything indoors.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fitlib import read_fit  # noqa: E402
from mappings import SPORTS  # noqa: E402
import hc_export_reader as hc  # noqa: E402
from build_fit import build  # noqa: E402


def pick_templates(folder):
    moving = strength = None
    for p in sorted(glob.glob(os.path.join(folder, "**", "*.fit"), recursive=True)):
        f = read_fit(p)
        s = f.by_num(18)
        if not s:
            continue
        if f.by_num(19) and any(m.fields.get(0) is not None for m in f.by_num(20)):
            moving = moving or p
        elif f.by_num(225):
            strength = strength or p
    if not (moving or strength):
        raise SystemExit(f"no usable watch FITs in {folder}")
    return moving or strength, strength or moving


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("export")
    ap.add_argument("--templates", required=True)
    ap.add_argument("--since")
    ap.add_argument("--out", default="out")
    ap.add_argument("--upload", action="store_true")
    a = ap.parse_args()
    t_moving, t_strength = pick_templates(a.templates)
    print(f"templates: moving={os.path.basename(t_moving)} strength={os.path.basename(t_strength)}")
    os.makedirs(a.out, exist_ok=True)
    con = hc.open_db(a.export)
    since = 0
    if a.since:
        from datetime import datetime, timezone
        since = datetime.fromisoformat(a.since).replace(tzinfo=timezone.utc).timestamp() * 1000
    fits = []
    for s in hc.sessions(con):
        if s["start_time"] < since or s.get("package") in hc.DEFAULT_EXCLUDE:
            continue
        sess = hc.build_session(con, s, hc.DEFAULT_EXCLUDE)
        tpl = t_moving if SPORTS[sess["sport"]]["moving"] else t_strength
        base = os.path.join(a.out, f"hc_{int(sess['start'])}_{sess['sport']}")
        json.dump(sess, open(base + ".json", "w"), indent=1)
        info = build(sess, tpl, base + ".fit")
        fits.append(base + ".fit")
        print(f"{base}.fit  {info['records']} s, {info['distance_m']} m, {info['hr_samples']} HR, "
              f"{info['sets']} sets  (from {sess['source']['package']})")
    if a.upload and fits:
        subprocess.call([sys.executable, os.path.join(HERE, "upload.py"), *fits])


if __name__ == "__main__":
    main()
