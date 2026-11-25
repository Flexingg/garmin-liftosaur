#!/usr/bin/env python3
"""Build a Venu-2S-shaped FIT activity from a normalized session JSON.

Strategy: "template cloning".
  A real FIT recorded by *your* watch (exported from Garmin Connect -> Export
  Original) is used as a template. From it we copy, byte-for-byte except for the
  timestamps:
    file_id (serial / product / manufacturer), file_creator (firmware),
    the device_info block (creator + barometer/whr/sensor hub/gps),
    device_settings, user_profile, sport, training_settings, zones_target,
    and the undocumented preamble messages (288/327/326/22/141/79).
  Then we synthesize the parts that carry the workout itself - records, laps,
  sets, time_in_zone, session, activity - using the *template's own message
  layouts* (same field numbers, sizes, base types, same order), so the result
  has the same structural fingerprint as a watch-recorded file.

What we deliberately do NOT synthesize (documented in ../FINDINGS.md):
  * mesg 140 (on-device Firstbeat physiological metrics: TE, load, recovery...)
  * mesg 233 (per-second opaque 4-byte blob), 325/326/288/22 mid-stream
  These are computed by the watch's firmware from raw sensor data we don't have;
  faking them would be worse than omitting them.

Session JSON (see ../samples/session.example.json):
{
  "sport": "walking" | "strength" | "running" | "hiking" | "cycling" | ...,
  "title": "optional, informational only",
  "start": 1764002226, "end": 1764006153,        # unix seconds (or ISO-8601)
  "utc_offset_s": -21600,                         # local time offset
  "heart_rate": [[unix_s, bpm], ...],
  "route": [[unix_s, lat_deg, lon_deg, alt_m|null], ...],
  "steps": [[start_s, end_s, count], ...],
  "distance": [[start_s, end_s, meters], ...],    # used only if no route
  "total_calories_kcal": 260, "active_calories_kcal": 150,
  "laps": [[start_s, end_s], ...],                # optional; else auto 1 mile laps (walk/run)
  "pauses": [[start_s, end_s], ...],
  "hr_max_gap_s": 10,                             # interpolate HR across gaps up to this
  "sets": [{"start": s, "end": s, "exercise": "bench_press" | <HC segment type int>,
            "reps": 8, "weight_kg": 60.0}, ...]   # strength only; rests are inferred
}
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fitlib import (FitWriter, read_fit, unix_to_fit, deg_to_semicircles,  # noqa: E402
                    BASE_TYPES)
from mappings import SPORTS, exercise_to_fit  # noqa: E402

PREAMBLE_COPY = {0, 49, 288, 327, 326, 23, 22, 141, 2, 3, 79, 12, 13, 7}
MILE = 1609.344


# ----------------------------------------------------------------- helpers

def to_unix(v):
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    return datetime.fromisoformat(str(v).replace("Z", "+00:00")).timestamp()


def haversine(lat1, lon1, lat2, lon2):
    r = 6371008.8
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def interp_series(points, t, max_gap):
    """Linear interpolation in sorted [(t, v)], None if outside/too sparse."""
    import bisect
    if not points:
        return None
    ts = interp_series._cache.get(id(points))
    if ts is None:
        ts = [p[0] for p in points]
        interp_series._cache[id(points)] = ts
    i = bisect.bisect_left(ts, t)
    if i < len(ts) and abs(ts[i] - t) < 0.5:
        return points[i][1]
    if i == 0 or i == len(ts):
        j = 0 if i == 0 else len(ts) - 1
        return points[j][1] if abs(ts[j] - t) <= max_gap / 2 else None
    (t0, v0), (t1, v1) = points[i - 1], points[i]
    if t1 - t0 > max_gap or v0 is None or v1 is None:
        return None
    return v0 + (v1 - v0) * (t - t0) / (t1 - t0)


interp_series._cache = {}


class Template:
    def __init__(self, path):
        self.fit = read_fit(path)
        self.layouts = {}  # global -> [list of field defs] in first-seen order
        for kind, d in self.fit.events:
            if kind == "def":
                lay = [(fd.num, fd.size, fd.base) for fd in d.fields]
                self.layouts.setdefault(d.global_num, [])
                if lay not in self.layouts[d.global_num]:
                    self.layouts[d.global_num].append(lay)
        msgs = self.fit.messages
        # preamble = everything before the first record
        first_rec = next(i for i, m in enumerate(msgs) if m.global_num == 20)
        self.preamble = [m for m in msgs[:first_rec] if m.global_num in PREAMBLE_COPY or m.global_num == 21]
        # closing device_info block = the last contiguous run of device_info msgs
        tail = []
        for m in reversed(msgs):
            if m.global_num == 23:
                tail.append(m)
            elif tail:
                break
        self.closing_device_info = list(reversed(tail))
        tiz = self.fit.by_num(216)
        self.tiz_proto = tiz[0].fields if tiz else None
        self.session_proto = (self.fit.by_num(18) or [None])[0]
        self.sport = (self.fit.by_num(12) or [None])[0]

    def layout(self, gnum, want=None, avoid=None):
        lays = self.layouts.get(gnum) or []
        for lay in lays:
            nums = {n for n, _, _ in lay}
            if (not want or want <= nums) and (not avoid or not (avoid & nums)):
                return lay
        return lays[0] if lays else None


def climb(alts, band=3.0):
    """Total ascent/descent with a hysteresis band (GPS/HC altitude is noisy;
    the watch uses a barometer). Returns (ascent_m, descent_m)."""
    if not alts:
        return None, None
    asc = desc = 0.0
    ref = alts[0]
    for a in alts[1:]:
        if a - ref >= band:
            asc += a - ref
            ref = a
        elif ref - a >= band:
            desc += ref - a
            ref = a
    return asc, desc


def scaled(v, scale=1, offset=0):
    if v is None:
        return None
    return int(round((v + offset) * scale))


def emit(w: FitWriter, gnum: int, layout, values: dict):
    """Write a message using a template layout; unknown fields become invalid."""
    fields = []
    for num, size, base in layout:
        code, bsize, _ = BASE_TYPES[base]
        v = values.get(num)
        if code == "s":
            fields.append((num, base, v, size))
            continue
        n = size // bsize
        if n > 1:
            if not isinstance(v, (list, tuple)):
                v = [v] + [None] * (n - 1)
            v = list(v)[:n] + [None] * max(0, n - len(v))
        fields.append((num, base, v, None))
    w.write_sized(gnum, fields)


def copy_msg(w, m, ts=None, overrides=None):
    vals = dict(m.fields)
    if ts is not None and 253 in vals:
        vals[253] = ts
    if overrides:
        vals.update(overrides)
    emit(w, m.global_num, [(fd.num, fd.size, fd.base) for fd in m.definition.fields], vals)


# ------------------------------------------------------------------- build

def build(session: dict, template_path: str, out_path: str, serial_override=None):
    tpl = Template(template_path)
    sport_key = session.get("sport", "walking")
    sp = SPORTS.get(sport_key)
    if sp is None:
        raise SystemExit(f"unknown sport {sport_key!r}; known: {', '.join(SPORTS)}")
    start = to_unix(session["start"])
    end = to_unix(session["end"])
    s_fit, e_fit = unix_to_fit(start), unix_to_fit(end)
    utc_off = int(session.get("utc_offset_s", tpl_local_offset(tpl)))

    hr = sorted((to_unix(t), float(b)) for t, b in session.get("heart_rate", []))
    route = sorted((to_unix(r[0]), r[1], r[2], r[3] if len(r) > 3 else None) for r in session.get("route", []))
    pauses = [(to_unix(a), to_unix(b)) for a, b in session.get("pauses", [])]
    steps = [(to_unix(a), to_unix(b), float(c)) for a, b, c in session.get("steps", [])]
    dist_iv = [(to_unix(a), to_unix(b), float(c)) for a, b, c in session.get("distance", [])]

    # max gap (s) between HR samples we will interpolate across; the watch never invents HR
    hr_gap = float(session.get("hr_max_gap_s", 10))

    def paused(t):
        return any(a <= t < b for a, b in pauses)

    # ---- per-second timeline
    secs = [t for t in range(int(start), int(end) + 1) if not paused(t)]
    lat_pts = [(r[0], r[1]) for r in route]
    lon_pts = [(r[0], r[2]) for r in route]
    alt_pts = [(r[0], r[3]) for r in route if r[3] is not None]

    cum = 0.0
    prev = None
    rec = []
    # distance from intervals if no route: spread evenly over each interval
    def dist_rate(t):
        return sum(c / max(1.0, b - a) for a, b, c in dist_iv if a <= t < b)

    def step_rate(t):  # steps per second
        return sum(c / max(1.0, b - a) for a, b, c in steps if a <= t < b)

    for t in secs:
        lat = interp_series(lat_pts, t, 30)
        lon = interp_series(lon_pts, t, 30)
        alt = interp_series(alt_pts, t, 60)
        if route and lat is not None and prev is not None:
            seg = haversine(prev[0], prev[1], lat, lon)
            cum += seg if seg < 50 else 0  # drop GPS teleports
        elif not route and sp["moving"]:
            cum += dist_rate(t)
        if lat is not None:
            prev = (lat, lon)
        h = interp_series(hr, t, hr_gap)
        spm = step_rate(t) * 60.0
        rec.append({"t": t, "lat": lat, "lon": lon, "alt": alt, "dist": cum,
                    "hr": int(round(h)) if h is not None else None,
                    "cad": spm / 2.0 if sp["moving"] and spm > 0 else (0 if sp["moving"] else None)})
    # speed = smoothed distance derivative
    for i, r in enumerate(rec):
        j0, j1 = max(0, i - 5), min(len(rec) - 1, i + 5)
        dt = rec[j1]["t"] - rec[j0]["t"]
        r["speed"] = (rec[j1]["dist"] - rec[j0]["dist"]) / dt if dt > 0 and sp["moving"] else (0.0 if sp["moving"] else None)

    total_dist = rec[-1]["dist"] if rec else 0.0
    total_steps = sum(c for _, _, c in steps)
    timer_time = len(secs) - 1 if secs else 0
    elapsed = end - start

    w = FitWriter(profile_version=tpl.fit.profile_version, protocol_version=tpl.fit.protocol_version)

    # ---- preamble (cloned)
    for m in tpl.preamble:
        if m.global_num == 0:
            ov = {4: s_fit}
            if serial_override:
                ov[3] = serial_override
            copy_msg(w, m, overrides=ov)
        elif m.global_num == 21:
            copy_msg(w, m, ts=s_fit)  # timer start
        elif m.global_num == 12:
            copy_msg(w, m, overrides={0: sp["sport"], 1: sp["sub_sport"], 3: sp["name"]}
                     if sp["name"] != (m.fields.get(3)) else None)
        elif m.global_num == 23 and serial_override and m.fields.get(0) == 0:
            copy_msg(w, m, ts=s_fit, overrides={3: serial_override})
        else:
            copy_msg(w, m, ts=s_fit if 253 in m.fields else None)

    hr_bounds = tpl.tiz_proto

    def tiz(ref_mesg, ref_idx, ts, a, b):
        if not hr_bounds:
            return
        bounds = [x for x in (hr_bounds.get(6) or []) if x is not None]
        zones = [0] * 7
        for r in rec:
            if a <= r["t"] < b and r["hr"] is not None:
                z = sum(1 for x in bounds if r["hr"] > x)
                zones[min(z, 6)] += 1000
        vals = dict(hr_bounds)
        vals.update({253: ts, 0: ref_mesg, 1: ref_idx, 2: zones})
        emit(w, 216, tpl.layout(216), vals)

    # ---- records (+ laps for moving sports, + gps_metadata like the watch)
    rec_lay_hr = tpl.layout(20, want={3})
    rec_lay_nohr = tpl.layout(20, avoid={3}) or rec_lay_hr
    gps_lay = tpl.layout(160)
    lap_lay = tpl.layout(19)
    laps_in = [(to_unix(a), to_unix(b)) for a, b in session.get("laps", [])]
    lap_bounds = []
    if sp["moving"] and lap_lay:
        if laps_in:
            lap_bounds = [b for _, b in laps_in]
        else:  # auto-lap every mile, like the watch's default
            nxt = MILE
            for r in rec:
                if r["dist"] >= nxt:
                    lap_bounds.append(r["t"])
                    nxt += MILE
    lap_bounds = [b for b in lap_bounds if b < end] + [end]
    laps_out = []
    lap_start = start
    lap_i = 0
    step_cycles = lambda a, b: sum(c * max(0, min(b, y) - max(a, x)) / max(1, y - x) for x, y, c in steps) / 2.0

    def lap_summary(a, b, idx, trigger):
        rs = [r for r in rec if a <= r["t"] <= b]
        hrs = [r["hr"] for r in rs if r["hr"] is not None]
        lats = [r["lat"] for r in rs if r["lat"] is not None]
        lons = [r["lon"] for r in rs if r["lon"] is not None]
        alts = [r["alt"] for r in rs if r["alt"] is not None]
        asc, desc = climb(alts)
        d = (rs[-1]["dist"] - rs[0]["dist"]) if rs else 0.0
        timer = max(0, len(rs) - 1)
        cyc = step_cycles(a, b)
        spd = [r["speed"] for r in rs if r["speed"] is not None]
        cads = [r["cad"] for r in rs if r["cad"]]
        frac = lambda lst: (sum(lst) / len(lst)) if lst else None
        first = next((r for r in rs if r["lat"] is not None), None)
        last = next((r for r in reversed(rs) if r["lat"] is not None), None)
        return {
            "start": a, "end": b, "idx": idx, "trigger": trigger, "dist": d, "timer": timer,
            "elapsed": b - a, "cycles": cyc, "hr_avg": frac(hrs), "hr_max": max(hrs) if hrs else None,
            "cad_avg": frac(cads), "cad_max": max(cads) if cads else None,
            "spd_avg": d / timer if timer else None, "spd_max": max(spd) if spd else None,
            "asc": asc, "desc": desc, "alt_min": min(alts) if alts else None,
            "alt_max": max(alts) if alts else None, "alt_avg": frac(alts),
            "nec": (max(lats), max(lons)) if lats else None, "swc": (min(lats), min(lons)) if lats else None,
            "first": (first["lat"], first["lon"]) if first else None,
            "last": (last["lat"], last["lon"]) if last else None,
        }

    def emit_lap(L, cal):
        sc = deg_to_semicircles
        v = {253: unix_to_fit(L["end"]), 254: L["idx"], 0: 9, 1: 1, 2: unix_to_fit(L["start"]),
             7: scaled(L["elapsed"], 1000), 8: scaled(L["timer"], 1000), 9: scaled(L["dist"], 100),
             10: int(L["cycles"]), 11: cal, 15: scaled(L["hr_avg"]), 16: L["hr_max"],
             17: int(L["cad_avg"]) if L["cad_avg"] else None, 18: int(L["cad_max"]) if L["cad_max"] else None,
             21: scaled(L["asc"]), 22: scaled(L["desc"]), 24: L["trigger"], 25: sp["sport"], 39: sp["sub_sport"],
             110: scaled(L["spd_avg"], 1000), 111: scaled(L["spd_max"], 1000),
             112: scaled(L["alt_avg"], 5, 500), 113: scaled(L["alt_min"], 5, 500), 114: scaled(L["alt_max"], 5, 500),
             80: int((L["cad_avg"] % 1) * 128) if L["cad_avg"] else None}
        if L["first"]:
            v.update({3: sc(L["first"][0]), 4: sc(L["first"][1]), 5: sc(L["last"][0]), 6: sc(L["last"][1]),
                      27: sc(L["nec"][0]), 28: sc(L["nec"][1]), 29: sc(L["swc"][0]), 30: sc(L["swc"][1])})
        emit(w, 19, lap_lay, v)

    # ---- strength sets (active + inferred rest), mirroring the watch layout
    set_lay = tpl.layout(225)
    sets = sorted(session.get("sets", []), key=lambda s: to_unix(s["start"]))
    set_msgs = []
    if sets:
        if not set_lay:
            # strength data but a walk template: use the canonical Venu 2S set layout
            set_lay = [(254, 4, 0x86), (0, 4, 0x86), (6, 4, 0x86), (7, 4, 0x84), (8, 4, 0x84), (3, 2, 0x84),
                       (4, 2, 0x84), (9, 2, 0x84), (10, 2, 0x84), (11, 2, 0x84), (12, 2, 0x84), (13, 2, 0x84),
                       (2, 2, 0x0A), (5, 1, 0x02)]
        idx = 0
        for i, s in enumerate(sets):
            a, b = to_unix(s["start"]), to_unix(s["end"])
            nxt = to_unix(sets[i + 1]["start"]) if i + 1 < len(sets) else end
            cat, sub = exercise_to_fit(s.get("exercise"))
            weight = s.get("weight_kg")
            # watch convention: an active set's timestamp is when the *following rest* ends
            set_msgs.append((a, {254: unix_to_fit(nxt), 0: scaled(b - a, 1000), 6: unix_to_fit(a), 7: [cat, None],
                                 8: [sub, None], 3: s.get("reps"), 4: scaled(weight, 16),
                                 9: (2 if session.get("weight_unit", "lb") == "lb" else 1) if weight is not None else None,
                                 10: idx, 5: 1}))
            idx += 1
            if nxt - b >= 1:
                set_msgs.append((b, {254: unix_to_fit(nxt), 0: scaled(nxt - b, 1000), 6: unix_to_fit(b),
                                     10: idx, 5: 0}))
                idx += 1

    pending_sets = list(set_msgs)

    def emit_set(v):
        emit(w, 225, set_lay, v)
        a = v[6] + 631065600
        tiz(216, v[10], v[254], a, a + v[0] / 1000.0)

    total_kcal = session.get("total_calories_kcal")
    prev_t = None
    for r in rec:
        if prev_t is not None and r["t"] - prev_t > 1:  # a pause: timer stop_all ... timer start
            emit(w, 21, tpl.layout(21), {253: unix_to_fit(prev_t + 1), 3: 0, 0: 0, 1: 4, 4: 0})
            emit(w, 21, tpl.layout(21), {253: unix_to_fit(r["t"]), 3: 0, 0: 0, 1: 0, 4: 0})
        prev_t = r["t"]
        lay = rec_lay_hr if r["hr"] is not None else rec_lay_nohr
        v = {253: unix_to_fit(r["t"]), 5: scaled(r["dist"], 100), 3: r["hr"], 136: r["hr"],
             73: scaled(r["speed"], 1000), 78: scaled(r["alt"], 5, 500),
             4: int(r["cad"]) if r["cad"] is not None else None,
             53: int((r["cad"] % 1) * 128) if r["cad"] is not None else None,
             # cycle_length16: metres per stride (cadence is strides/min)
             87: scaled(r["speed"] / (r["cad"] / 60.0) if r["cad"] and r["speed"] else 0.0, 100)
             if sp["moving"] else None}
        if r["lat"] is not None:
            v[0], v[1] = deg_to_semicircles(r["lat"]), deg_to_semicircles(r["lon"])
        emit(w, 20, lay, v)
        # the watch writes each set when the rest that follows it ends
        while pending_sets and pending_sets[0][1][254] <= unix_to_fit(r["t"]) < e_fit:
            emit_set(pending_sets.pop(0)[1])
        if gps_lay and r["lat"] is not None:
            emit(w, 160, gps_lay, {3: scaled(r["alt"], 5, 500), 4: scaled(r["speed"], 1000)})
        if lap_lay and sp["moving"] and lap_i < len(lap_bounds) - 1 and r["t"] >= lap_bounds[lap_i]:
            L = lap_summary(lap_start, r["t"], lap_i, 2 if not laps_in else 0)
            laps_out.append(L)
            cal = int(round(total_kcal * L["timer"] / max(1, timer_time))) if total_kcal else None
            emit_lap(L, cal)
            tiz(19, lap_i, unix_to_fit(r["t"]), lap_start, r["t"])
            lap_start = r["t"] + 1
            lap_i += 1

    # ---- closing
    if lap_lay and sp["moving"]:
        L = lap_summary(lap_start, end, lap_i, 7)  # 7 = session_end
        laps_out.append(L)
        cal = int(round(total_kcal * L["timer"] / max(1, timer_time))) if total_kcal else None
    emit(w, 21, tpl.layout(21), {253: e_fit, 3: 0, 0: 0, 1: 4, 4: 0})  # timer stop_all
    for m in tpl.closing_device_info:
        ov = {3: serial_override} if (serial_override and m.fields.get(0) == 0) else None
        copy_msg(w, m, ts=e_fit, overrides=ov)
    for _, v in pending_sets:
        emit_set(v)
    if lap_lay and sp["moving"]:
        emit_lap(L, cal)
        tiz(19, lap_i, e_fit, L["start"], end + 1)

    hrs = [r["hr"] for r in rec if r["hr"] is not None]
    lats = [r["lat"] for r in rec if r["lat"] is not None]
    lons = [r["lon"] for r in rec if r["lon"] is not None]
    alts = [r["alt"] for r in rec if r["alt"] is not None]
    cads = [r["cad"] for r in rec if r["cad"]]
    spds = [r["speed"] for r in rec if r["speed"]]
    active_sets = [v for _, v in set_msgs if v[5] == 1]
    sc = deg_to_semicircles
    sess = {253: e_fit + 1, 254: 0, 0: 9, 1: 1, 2: s_fit, 5: sp["sport"], 6: sp["sub_sport"],
            7: scaled(elapsed, 1000), 8: scaled(timer_time, 1000), 9: scaled(total_dist, 100),
            11: int(round(total_kcal)) if total_kcal else None, 16: scaled(sum(hrs) / len(hrs)) if hrs else None,
            17: max(hrs) if hrs else None, 25: 0, 26: max(1, len(laps_out)) if sp["moving"] else len(set_msgs),
            28: 0, 110: sp["name"], 152: 0, 81: 0, 184: 0}
    if sp["moving"]:
        sess.update({10: int(total_steps / 2), 124: scaled(total_dist / timer_time if timer_time else 0, 1000),
                     125: scaled(max(spds) if spds else 0, 1000),
                     18: int(sum(cads) / len(cads)) if cads else None, 19: int(max(cads)) if cads else None,
                     92: int(((sum(cads) / len(cads)) % 1) * 128) if cads else None, 93: 0,
                     22: scaled(climb(alts)[0]), 23: scaled(climb(alts)[1])})
        if lats:
            fr = next(r for r in rec if r["lat"] is not None)
            lr = next(r for r in reversed(rec) if r["lat"] is not None)
            sess.update({3: sc(fr["lat"]), 4: sc(fr["lon"]), 38: sc(lr["lat"]), 39: sc(lr["lon"]),
                         29: sc(max(lats)), 30: sc(max(lons)), 31: sc(min(lats)), 32: sc(min(lons))})
    else:
        sess.update({9: 0, 10: sum(v.get(3) or 0 for v in active_sets), 124: 0,
                     78: scaled(sum(v[0] for v in active_sets) / 1000.0, 1000), 151: len(active_sets)})
    if sets:
        sess[10] = sum(v.get(3) or 0 for v in active_sets)
    sess_lay = [(fd.num, fd.size, fd.base) for fd in tpl.session_proto.definition.fields]
    emit(w, 18, sess_lay, sess)
    tiz(18, 0, e_fit + 1, start, end + 1)
    emit(w, 34, tpl.layout(34), {253: e_fit + 1, 0: scaled(timer_time, 1000), 1: 1, 2: 0, 3: 26, 4: 1,
                                 5: e_fit + 1 + utc_off})
    data = w.to_bytes()
    with open(out_path, "wb") as fh:
        fh.write(data)
    return {"out": out_path, "bytes": len(data), "records": len(rec), "laps": len(laps_out),
            "sets": len(set_msgs), "distance_m": round(total_dist, 1), "hr_samples": len(hrs)}


def tpl_local_offset(tpl):
    a = (tpl.fit.by_num(34) or [None])[0]
    if a and a.fields.get(5) and a.fields.get(253):
        return a.fields[5] - a.fields[253]
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("session", help="normalized session JSON (from hc_export_reader.py)")
    ap.add_argument("--template", required=True,
                    help="a real FIT from your watch, same kind of activity (walk template for walks/runs, "
                         "strength template for strength)")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--serial", type=int, help="override unit id (default: template's)")
    a = ap.parse_args()
    session = json.load(open(a.session))
    print(json.dumps(build(session, a.template, a.out, a.serial), indent=1))


if __name__ == "__main__":
    main()
