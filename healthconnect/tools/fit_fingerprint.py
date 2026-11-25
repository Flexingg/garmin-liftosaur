#!/usr/bin/env python3
"""Print the structural "fingerprint" of a FIT file, or diff two of them.

The fingerprint is what a careful observer (or a server-side heuristic) could
use to tell a watch-recorded file from a synthesized one:
  * header: header size, protocol version, profile version
  * the order in which global messages appear (run-length encoded)
  * for each global message: every distinct field layout (field num/size/base type)
  * identity: file_id / file_creator / device_info(creator)

Usage:
  fit_fingerprint.py FILE                 # fingerprint one file
  fit_fingerprint.py --diff REAL SYNTH    # what differs structurally
  fit_fingerprint.py --json FILE          # machine-readable
"""
from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fitlib import read_fit  # noqa: E402

NAMES = {0: "file_id", 49: "file_creator", 23: "device_info", 21: "event", 20: "record",
         19: "lap", 18: "session", 34: "activity", 225: "set", 12: "sport", 216: "time_in_zone",
         2: "device_settings", 3: "user_profile", 7: "zones_target", 13: "training_settings",
         160: "gps_metadata", 206: "field_description", 207: "developer_data_id",
         22: "?device_used", 79: "?user_metrics(hr_mets/vo2)", 140: "?physiological_metrics",
         141: "?epo_status", 233: "?record_aux_233", 288: "?288", 325: "?325", 326: "?326",
         327: "?327", 329: "?329", 78: "hrv", 297: "respiration_rate"}


def name(n):
    return f"{n}:{NAMES.get(n, '?')}"


def fingerprint(path):
    f = read_fit(path)
    seq = []
    for m in f.messages:
        if seq and seq[-1][0] == m.global_num:
            seq[-1][1] += 1
        else:
            seq.append([m.global_num, 1])
    layouts: dict[int, list] = {}
    for kind, d in f.events:
        if kind != "def":
            continue
        lay = [(fd.num, fd.size, fd.base) for fd in d.fields]
        layouts.setdefault(d.global_num, [])
        if lay not in layouts[d.global_num]:
            layouts[d.global_num].append(lay)
    fid = (f.by_num(0) or [None])[0]
    fc = (f.by_num(49) or [None])[0]
    creators = [m.fields for m in f.by_num(23) if m.fields.get(0) == 0]
    return {
        "file": os.path.basename(path),
        "header": {"size": f.header_size, "protocol": f.protocol_version,
                   "profile": f.profile_version, "crc_ok": f.crc_ok},
        "identity": {
            "file_id": fid.fields if fid else None,
            "file_creator": fc.fields if fc else None,
            "device_info_creator": creators[0] if creators else None,
        },
        "sequence": seq,
        "layouts": {str(k): v for k, v in layouts.items()},
        "counts": {str(k): sum(c for g, c in seq if g == k) for k in sorted({g for g, _ in seq})},
    }


def show(fp):
    print(f"== {fp['file']}")
    print("header:", fp["header"])
    for k, v in fp["identity"].items():
        print(f"{k}: {v}")
    print("message order (global:count):")
    print("  " + "  ".join(f"{name(g)}x{c}" if c > 1 else name(g) for g, c in fp["sequence"]))
    print("layouts:")
    for g, lays in sorted(fp["layouts"].items(), key=lambda kv: int(kv[0])):
        for lay in lays:
            print(f"  {name(int(g)):34s} " + " ".join(f"{n}/{s}/{b:#04x}" for n, s, b in lay))


def diff(a, b):
    print(f"== structural diff: {a['file']} (reference) vs {b['file']} (candidate)")
    for k in ("protocol", "profile", "size"):
        if a["header"][k] != b["header"][k]:
            print(f"  header.{k}: {a['header'][k]} != {b['header'][k]}")
    ia, ib = a["identity"], b["identity"]
    for key, fields in (("file_id", (1, 2, 3, 0)), ("file_creator", (0,)),
                        ("device_info_creator", (2, 3, 4, 5, 25))):
        for fnum in fields:
            va = (ia.get(key) or {}).get(fnum)
            vb = (ib.get(key) or {}).get(fnum)
            if va != vb:
                print(f"  identity {key}[{fnum}]: {va} != {vb}")
    ga, gb = set(a["counts"]), set(b["counts"])
    if ga - gb:
        print("  messages only in reference:", ", ".join(name(int(g)) for g in sorted(ga - gb, key=int)))
    if gb - ga:
        print("  messages only in candidate:", ", ".join(name(int(g)) for g in sorted(gb - ga, key=int)))
    for g in sorted(ga & gb, key=int):
        fa = {n for lay in a["layouts"].get(g, []) for n, _, _ in lay}
        fb = {n for lay in b["layouts"].get(g, []) for n, _, _ in lay}
        if fa != fb:
            print(f"  {name(int(g))}: fields only in ref {sorted(fa - fb)}, only in cand {sorted(fb - fa)}")
    oa = [g for g, _ in a["sequence"]]
    ob = [g for g, _ in b["sequence"]]
    print("  order ref :", " ".join(str(g) for g in oa[:40]), "..." if len(oa) > 40 else "")
    print("  order cand:", " ".join(str(g) for g in ob[:40]), "..." if len(ob) > 40 else "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--diff", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    fps = [fingerprint(p) for p in args.files]
    if args.json:
        print(json.dumps(fps, indent=1, default=str))
    elif args.diff:
        diff(fps[0], fps[1])
    else:
        for fp in fps:
            show(fp)


if __name__ == "__main__":
    main()
