#!/usr/bin/env python3
"""Upload FIT files to Garmin Connect (optional step - the web importer works too:
https://connect.garmin.com/modern/import-data).

Uses python-garminconnect (pip install --upgrade garminconnect curl_cffi). Its
current login() tries several Garmin auth strategies; the old garth-only flow
was broken by Garmin in 2026, so keep that package up to date. Tokens are cached
in ~/.garminconnect so you log in (and do MFA) once.

Before uploading it checks for an existing activity whose start time is within
--overlap-s of the file's start, because Garmin rejects same-start duplicates
(HTTP 409) and an overlapping *different* activity would double-count your day.

Credentials: GARMIN_EMAIL / GARMIN_PASSWORD env vars, or prompted. Never commit them.
"""
from __future__ import annotations

import argparse
import getpass
import os
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fitlib import read_fit, fit_to_unix  # noqa: E402

TOKENSTORE = os.path.expanduser(os.environ.get("GARMINTOKENS", "~/.garminconnect"))


def login():
    try:
        from garminconnect import Garmin
    except ImportError:
        raise SystemExit("pip install --upgrade garminconnect curl_cffi")
    try:
        g = Garmin()
        g.login(TOKENSTORE)
        return g
    except Exception:
        email = os.environ.get("GARMIN_EMAIL") or input("Garmin email: ")
        pw = os.environ.get("GARMIN_PASSWORD") or getpass.getpass("Garmin password: ")
        g = Garmin(email=email, password=pw, prompt_mfa=lambda: input("MFA code: "))
        g.login(TOKENSTORE)
        return g


def fit_start(path):
    s = read_fit(path).by_num(18)[0].fields
    return fit_to_unix(s[2]), s[7] / 1000.0


def overlapping(g, start, dur, slack):
    day = datetime.fromtimestamp(start, timezone.utc).date()
    acts = g.get_activities_by_date((day - timedelta(days=1)).isoformat(), (day + timedelta(days=1)).isoformat())
    hits = []
    for a in acts or []:
        st = a.get("startTimeGMT")
        if not st:
            continue
        t = datetime.fromisoformat(st.replace(" ", "T")).replace(tzinfo=timezone.utc).timestamp()
        d = a.get("duration") or 0
        if t < start + dur + slack and start < t + d + slack:
            hits.append((a.get("activityId"), a.get("activityName"), st, (a.get("deviceId"))))
    return hits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fits", nargs="+")
    ap.add_argument("--dry-run", action="store_true", help="check only, don't upload")
    ap.add_argument("--force", action="store_true", help="upload even if an overlapping activity exists")
    ap.add_argument("--overlap-s", type=int, default=60)
    a = ap.parse_args()
    g = login()
    for p in a.fits:
        start, dur = fit_start(p)
        hits = overlapping(g, start, dur, a.overlap_s)
        tag = datetime.fromtimestamp(start, timezone.utc).isoformat(timespec="seconds")
        if hits and not a.force:
            print(f"SKIP {p} ({tag}): overlaps existing {hits}")
            continue
        if a.dry_run:
            print(f"WOULD UPLOAD {p} ({tag}, {dur / 60:.0f} min)")
            continue
        r = g.upload_activity(p)
        print(f"UPLOADED {p}: {getattr(r, 'status_code', '')} {getattr(r, 'text', r)!s:.300}")


if __name__ == "__main__":
    main()
