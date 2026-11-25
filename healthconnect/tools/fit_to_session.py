#!/usr/bin/env python3
"""Convert a real FIT activity into the normalized session JSON.

Used for round-trip validation (real FIT -> session JSON -> build_fit.py -> compare)
and to see exactly what a Health Connect export must provide. Not needed in the
normal Health Connect -> Garmin path.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fitlib import read_fit, fit_to_unix, semicircles_to_deg  # noqa: E402

CAT_NAMES = {0: "bench_press", 6: "crunch", 7: "curl", 8: "deadlift", 13: "hyperextension",
             17: "lunge", 19: "plank", 21: "pull_up", 22: "push_up", 23: "row", 24: "shoulder_press",
             27: "sit_up", 28: "squat", 30: "triceps_extension", 14: "lateral_raise"}
SPORT = {(11, 0): "walking", (1, 0): "running", (10, 20): "strength", (17, 0): "hiking", (2, 0): "cycling"}


def convert(path):
    f = read_fit(path)
    sess = f.by_num(18)[0].fields
    act = f.by_num(34)[0].fields
    start = fit_to_unix(sess[2])
    recs_ts = [fit_to_unix(r.fields[253]) for r in f.by_num(20)]
    # session.total_elapsed_time excludes watch power-off time, so use the last record
    end = max(start + sess[7] / 1000.0, recs_ts[-1] if recs_ts else 0)
    out = {"sport": SPORT.get((sess[5], sess[6]), "walking"), "start": start, "end": round(end),
           "utc_offset_s": act[5] - act[253], "total_calories_kcal": sess.get(11),
           "heart_rate": [], "route": [], "steps": [], "pauses": [], "sets": []}
    recs = f.by_num(20)
    prev = None
    for r in recs:
        v = r.fields
        t = fit_to_unix(v[253])
        if v.get(3) is not None:
            out["heart_rate"].append([t, v[3]])
        if v.get(0) is not None:
            alt = v.get(78)
            out["route"].append([t, semicircles_to_deg(v[0]), semicircles_to_deg(v[1]),
                                 alt / 5.0 - 500 if alt is not None else None])
        if prev is not None and t - prev > 5:
            out["pauses"].append([prev + 1, t])
        prev = t
    # steps: total_cycles (strides) * 2 spread over the session, per lap if available
    for lap in f.by_num(19):
        L = lap.fields
        a = fit_to_unix(L[2])
        out["steps"].append([a, a + L[7] / 1000.0, (L.get(10) or 0) * 2])
    acts = [s.fields for s in f.by_num(225) if s.fields.get(5) == 1]
    for s in acts:
        a = fit_to_unix(s[6])
        cat = (s.get(7) or [None])[0]
        out["sets"].append({"start": a, "end": a + s[0] / 1000.0, "exercise": CAT_NAMES.get(cat, "unknown"),
                            "reps": s.get(3), "weight_kg": s[4] / 16.0 if s.get(4) is not None else None})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fit")
    ap.add_argument("-o", "--out")
    a = ap.parse_args()
    s = json.dumps(convert(a.fit))
    if a.out:
        open(a.out, "w").write(s)
    else:
        print(s)


if __name__ == "__main__":
    main()
