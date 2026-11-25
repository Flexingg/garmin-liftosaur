#!/usr/bin/env python3
"""Read a Health Connect export (Settings > Health Connect > Export -> "Health Connect.zip")
and emit normalized session JSON for build_fit.py.

Table/column names come from AOSP packages/modules/HealthFitness
(service/java/com/android/server/healthconnect/storage/datatypehelpers/*RecordHelper.java),
read on 2026-11-25. The export is a copy of that SQLite database, but Google does
not document it, so every lookup is defensive: run with --schema first and share
the output if something doesn't line up.

Usage:
  hc_export_reader.py "Health Connect.zip" --schema
  hc_export_reader.py "Health Connect.zip" --list
  hc_export_reader.py "Health Connect.zip" --session <uuid-or-row_id> -o session.json
  hc_export_reader.py "Health Connect.zip" --all --since 2026-11-01 --out-dir sessions/
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import tempfile
import zipfile
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mappings import HC_EXERCISE_TYPE, HC_SEGMENT_REST  # noqa: E402

# Never re-import data that Garmin itself wrote into Health Connect (loops/duplicates).
DEFAULT_EXCLUDE = {"com.garmin.android.apps.connectmobile", "com.garmin.connectiq"}


def open_db(path):
    if zipfile.is_zipfile(path):
        z = zipfile.ZipFile(path)
        names = [n for n in z.namelist() if n.endswith(".db")]
        if not names:
            raise SystemExit(f"no .db inside {path}: {z.namelist()}")
        tmp = tempfile.mkdtemp(prefix="hcexport-")
        z.extract(names[0], tmp)
        path = os.path.join(tmp, names[0])
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    return con


def tables(con):
    return {r[0] for r in con.execute("select name from sqlite_master where type='table'")}


def cols(con, table):
    return {r[1] for r in con.execute(f"pragma table_info('{table}')")}


def pick(con, *candidates):
    t = tables(con)
    for c in candidates:
        if c in t:
            return c
    return None


def dump_schema(con):
    for t in sorted(tables(con)):
        n = con.execute(f"select count(*) from '{t}'").fetchone()[0]
        print(f"{t} ({n} rows): {', '.join(sorted(cols(con, t)))}")


def app_names(con):
    t = pick(con, "application_info_table")
    if not t:
        return {}
    return {r["row_id"]: r["package_name"] for r in con.execute(f"select row_id, package_name from {t}")}


def device_names(con):
    t = pick(con, "device_info_table")
    if not t:
        return {}
    c = cols(con, t)
    out = {}
    for r in con.execute(f"select * from {t}"):
        out[r["row_id"]] = " ".join(str(r[k]) for k in ("manufacturer", "model") if k in c and r[k])
    return out


def sessions(con):
    t = pick(con, "exercise_session_record_table")
    if not t:
        raise SystemExit("no exercise_session_record_table in this export (run --schema)")
    apps, devs = app_names(con), device_names(con)
    for r in con.execute(f"select * from {t} order by start_time"):
        d = dict(r)
        d["package"] = apps.get(d.get("app_info_id"))
        d["device"] = devs.get(d.get("device_info_id"))
        yield d


def ms(v):
    return v / 1000.0 if v is not None else None


def overlap_frac(a, b, x, y):
    if y <= x:
        return 1.0 if a <= x <= b else 0.0
    return max(0.0, min(b, y) - max(a, x)) / (y - x)


def interval_rows(con, table, value_col, a_ms, b_ms, app_ids):
    t = pick(con, table)
    if not t or value_col not in cols(con, t):
        return []
    q = f"select start_time, end_time, {value_col} as v, app_info_id from {t} where end_time > ? and start_time < ?"
    rows = [dict(r) for r in con.execute(q, (a_ms, b_ms))]
    same = [r for r in rows if r["app_info_id"] in app_ids]
    return same or rows


def energy_kcal(raw_total, duration_s):
    # The energy column holds small calories: TotalCaloriesBurnedRecordInternal
    # rebuilds the public record with Energy.fromCalories(getEnergy()) (AOSP, verified).
    if raw_total is None:
        return None
    return raw_total / 1000.0


def build_session(con, s, exclude):
    apps = app_names(con)
    pkg_ok = {k for k, v in apps.items() if v not in exclude}
    a_ms, b_ms = s["start_time"], s["end_time"]
    src = {s.get("app_info_id")}
    out = {
        "source": {"package": s.get("package"), "device": s.get("device"), "uuid": _uuid(s.get("uuid")),
                   "hc_exercise_type": s.get("exercise_type")},
        "sport": HC_EXERCISE_TYPE.get(s.get("exercise_type"), "cardio"),
        "title": s.get("title"),
        "start": ms(a_ms), "end": ms(b_ms),
        "utc_offset_s": s.get("start_zone_offset") or 0,
        "heart_rate": [], "route": [], "steps": [], "distance": [], "laps": [], "pauses": [], "sets": [],
    }
    dur = (b_ms - a_ms) / 1000.0

    # heart rate: series child table keyed by parent_key -> heart_rate_record_table.row_id
    hrt, hrs = pick(con, "heart_rate_record_table"), pick(con, "heart_rate_record_series_table")
    if hrt and hrs:
        q = (f"select s.epoch_millis t, s.beats_per_minute bpm, p.app_info_id app from {hrs} s "
             f"join {hrt} p on s.parent_key = p.row_id where s.epoch_millis between ? and ? order by s.epoch_millis")
        rows = [dict(r) for r in con.execute(q, (a_ms, b_ms))]
        same = [r for r in rows if r["app"] in src]
        rows = same or [r for r in rows if r["app"] in pkg_ok]
        out["heart_rate"] = [[ms(r["t"]), r["bpm"]] for r in rows]

    rt = pick(con, "exercise_route_table")
    if rt:
        for r in con.execute(f"select * from {rt} where parent_key = ? order by timestamp_millis", (s["row_id"],)):
            out["route"].append([ms(r["timestamp_millis"]), r["latitude"], r["longitude"], r["altitude"]])

    for r in interval_rows(con, "steps_record_table", "count", a_ms, b_ms, src):
        out["steps"].append([ms(r["start_time"]), ms(r["end_time"]), r["v"]])
    for r in interval_rows(con, "distance_record_table", "distance", a_ms, b_ms, src):
        out["distance"].append([ms(r["start_time"]), ms(r["end_time"]), r["v"]])
    for key, table in (("total_calories_kcal", "total_calories_burned_record_table"),
                       ("active_calories_kcal", "active_calories_burned_record_table")):
        rows = interval_rows(con, table, "energy", a_ms, b_ms, src)
        if rows:
            tot = sum(r["v"] * overlap_frac(a_ms, b_ms, r["start_time"], r["end_time"]) for r in rows)
            out[key] = round(energy_kcal(tot, dur), 1)
    if "total_calories_kcal" not in out and "active_calories_kcal" in out:
        out["total_calories_kcal"] = out["active_calories_kcal"]  # better than nothing; note in README

    lt = pick(con, "exercise_laps_table")
    if lt:
        for r in con.execute(f"select * from {lt} where parent_key = ? order by lap_start_time", (s["row_id"],)):
            out["laps"].append([ms(r["lap_start_time"]), ms(r["lap_end_time"])])

    st = pick(con, "exercise_segments_table")
    if st:
        for r in con.execute(f"select * from {st} where parent_key = ? order by segment_start_time", (s["row_id"],)):
            a, b, typ = ms(r["segment_start_time"]), ms(r["segment_end_time"]), r["segment_type"]
            if typ in HC_SEGMENT_REST:
                if typ == 39:  # PAUSE -> timer stopped
                    out["pauses"].append([a, b])
                continue
            if out["sport"] in ("strength", "hiit", "cardio") or r["repetitions_count"]:
                out["sets"].append({"start": a, "end": b, "exercise": typ,
                                    "reps": r["repetitions_count"] or None, "weight_kg": None})
    return out


def _uuid(v):
    if isinstance(v, bytes):
        return v.hex()
    return v


def match(s, key):
    return str(s.get("row_id")) == key or (_uuid(s.get("uuid")) or "").startswith(key.replace("-", ""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("export", help='"Health Connect.zip" or the .db inside it')
    ap.add_argument("--schema", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--session")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--since", help="YYYY-MM-DD (with --all)")
    ap.add_argument("--include-garmin", action="store_true", help="don't skip Garmin-originated data")
    ap.add_argument("-o", "--out")
    ap.add_argument("--out-dir")
    a = ap.parse_args()
    con = open_db(a.export)
    exclude = set() if a.include_garmin else DEFAULT_EXCLUDE
    if a.schema:
        dump_schema(con)
        return
    ss = list(sessions(con))
    if a.list:
        for s in ss:
            t0 = datetime.fromtimestamp(s["start_time"] / 1000, timezone.utc).isoformat(timespec="seconds")
            print(f"{s['row_id']:>6}  {t0}  {(s['end_time'] - s['start_time']) / 60000:6.1f} min  "
                  f"type={s.get('exercise_type'):<3} {HC_EXERCISE_TYPE.get(s.get('exercise_type'), '?'):<10} "
                  f"{s.get('package')}  {s.get('device') or ''}  {s.get('title') or ''}")
        return
    if a.session:
        s = next((s for s in ss if match(s, a.session)), None)
        if not s:
            raise SystemExit("session not found (use --list)")
        js = json.dumps(build_session(con, s, exclude), indent=1)
        open(a.out, "w").write(js) if a.out else print(js)
        return
    if a.all:
        since = datetime.fromisoformat(a.since).replace(tzinfo=timezone.utc).timestamp() * 1000 if a.since else 0
        os.makedirs(a.out_dir or ".", exist_ok=True)
        for s in ss:
            if s["start_time"] < since or s.get("package") in exclude:
                continue
            p = os.path.join(a.out_dir or ".", f"hc_{s['row_id']}_{int(s['start_time'] / 1000)}.json")
            open(p, "w").write(json.dumps(build_session(con, s, exclude), indent=1))
            print(p)
        return
    ap.print_help()


if __name__ == "__main__":
    main()
