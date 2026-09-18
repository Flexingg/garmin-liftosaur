#!/usr/bin/env python3
"""Minimal FIT file inspector (stdlib only).

Answers the only questions that matter for the watch's recorded activity:
  - which global messages are present, and how many
  - do RECORD messages carry the NATIVE heart_rate field (so Garmin computes zones)
  - does the file contain FIT DEVELOPER FIELDS (field_description/developer_data_id)
    and what are they, per lap
  - what do the LAP and SESSION summaries say

No third-party dependency: FIT is a small binary format, so this decodes it.
Usage: inspect_fit.py FILE.fit [FILE.fit ...] [--expect-laps N] [--expect-dev-fields N]

With --expect-laps/--expect-dev-fields, exits non-zero (with a clear message on
stderr) if the LAST file given does not match — so this can gate Task 6's
device verification instead of relying on eyeballing the printout.
"""
from __future__ import annotations

import argparse
import struct
import sys

# base type id (byte & 0x1F) -> (size, struct char, is_string)
BT = {
    0x00: (1, "B", False), 0x01: (1, "b", False), 0x02: (1, "B", False),
    0x03: (2, "h", False), 0x04: (2, "H", False), 0x05: (4, "i", False),
    0x06: (4, "I", False), 0x07: (1, "s", True), 0x08: (4, "f", False),
    0x09: (8, "d", False), 0x0A: (1, "B", False), 0x0B: (2, "H", False),
    0x0C: (4, "I", False), 0x0D: (1, "B", False), 0x0E: (8, "q", False),
    0x0F: (8, "Q", False), 0x10: (8, "Q", False),
}

GMSG = {
    0: "file_id", 12: "sport", 18: "session", 19: "lap", 20: "record",
    21: "event", 23: "device_info", 34: "activity", 49: "file_creator",
    206: "field_description", 207: "developer_data_id", 79: "hr_zone",
    216: "time_in_zone", 22: "undocumented",
}

# Fixed display order for per-lap developer fields, so the table is stable
# across runs regardless of FIT field-definition order in the file.
LAP_DEV_ORDER = [
    "Exercise", "SetIndex", "Weight", "Reps", "Amrap", "Rest",
    "PeakG", "MeanG", "RepsEst", "Samples",
]


def decode(blob: bytes, size: int, base: int, little: bool):
    if base & 0x1F == 0x07:  # string
        return blob[:size].split(b"\x00")[0].decode("utf-8", "replace")
    n, ch, _ = BT.get(base & 0x1F, (1, "B", False))
    if n != 1 and size % n == 0:
        vals = []
        for i in range(0, size, n):
            vals.append(struct.unpack(("<" if little else ">") + ch, blob[i:i + n])[0])
        return vals if len(vals) > 1 else vals[0]
    if n == size:
        return struct.unpack(("<" if little else ">") + ch, blob[:n])[0]
    return blob.hex()


def parse(path: str):
    data = open(path, "rb").read()
    if data[8:12] != b".FIT":
        raise SystemExit(f"{path}: not a FIT file")
    hdr = data[0]
    dsize = struct.unpack("<I", data[4:8])[0]
    pos = hdr
    end = hdr + dsize

    defs: dict[int, dict] = {}
    devfields: dict[tuple[int, int], dict] = {}   # (dev_data_index, field_num) -> desc
    counts: dict[str, int] = {}
    records = {"n": 0, "with_hr": 0, "hr_min": None, "hr_max": None}
    laps: list[dict] = []
    sessions: list[dict] = []

    while pos < end:
        rh = data[pos]
        pos += 1
        if rh & 0x80:  # compressed timestamp header
            lmt = rh & 0x0F
            if lmt not in defs:
                break
            d = defs[lmt]
            size = sum(f[1] for f in d["fields"]) + sum(f[1] for f in d["dev"])
            pos += size
            counts[GMSG.get(d["gmsg"], str(d["gmsg"]))] = counts.get(
                GMSG.get(d["gmsg"], str(d["gmsg"])), 0) + 1
            continue
        is_def = bool(rh & 0x40)
        has_dev = bool(rh & 0x20)
        lmt = rh & 0x0F
        if is_def:
            arch = data[pos + 1]
            little = arch == 0
            gmsg = struct.unpack(("<" if little else ">") + "H", data[pos + 2:pos + 4])[0]
            nfields = data[pos + 4]
            p = pos + 5
            fields = []
            for _ in range(nfields):
                fnum, fsize, btype = data[p], data[p + 1], data[p + 2]
                fields.append((fnum, fsize, btype))
                p += 3
            dev = []
            if has_dev:
                ndev = data[p]
                p += 1
                for _ in range(ndev):
                    dev.append((data[p], data[p + 1], data[p + 2]))
                    p += 3
            defs[lmt] = {"gmsg": gmsg, "fields": fields, "dev": dev, "little": little}
            pos = p
            continue
        if lmt not in defs:
            break
        d = defs[lmt]
        name = GMSG.get(d["gmsg"], f"gmsg{d['gmsg']}")
        counts[name] = counts.get(name, 0) + 1
        vals = {}
        for fnum, fsize, btype in d["fields"]:
            vals[fnum] = decode(data[pos:pos + fsize], fsize, btype, d["little"])
            pos += fsize
        devvals = {}
        for fnum, fsize, idx in d["dev"]:
            desc = devfields.get((idx, fnum))
            key = desc["name"] if desc else f"dev{idx}.{fnum}"
            devvals[key] = decode(data[pos:pos + fsize], fsize, desc["base"] if desc else 0x0D,
                                 d["little"])
            pos += fsize

        if name == "field_description":
            devfields[(vals.get(0, 0), vals.get(1, 0))] = {
                "name": vals.get(3, "?"), "base": vals.get(2, 0),
                "units": vals.get(8, ""), "native": (vals.get(14), vals.get(15))}
        elif name == "record":
            records["n"] += 1
            hr = vals.get(3)
            if isinstance(hr, int) and 0 < hr < 250:
                records["with_hr"] += 1
                records["hr_min"] = hr if records["hr_min"] is None else min(records["hr_min"], hr)
                records["hr_max"] = hr if records["hr_max"] is None else max(records["hr_max"], hr)
        elif name == "lap":
            laps.append({"fields": vals, "dev": devvals})
        elif name == "session":
            sessions.append({"fields": vals, "dev": devvals})

    print(f"### {path}  ({len(data)} bytes, data section {dsize})")
    print("  messages:", ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    r = records
    pct = (100.0 * r["with_hr"] / r["n"]) if r["n"] else 0.0
    print(f"  RECORDs: {r['n']}, with native heart_rate: {r['with_hr']} ({pct:.1f}%)"
          + (f", HR {r['hr_min']}-{r['hr_max']} bpm" if r["with_hr"] else ""))
    print(f"  native HR present: {'yes' if r['with_hr'] > 0 else 'no'}"
          " (Garmin Connect time-in-zone needs this, NOT the HeartRate dev field)")
    print(f"  developer fields defined: {len(devfields)}")
    for (idx, fnum), desc in sorted(devfields.items(), key=lambda kv: str(kv[1]['name'])):
        print(f"     dev{idx}.{fnum}  {desc['name']!r} units={desc['units']!r} "
              f"native={desc['native']}")
    print(f"  LAPs: {len(laps)}   SESSIONs: {len(sessions)}")
    for i, lap in enumerate(laps):
        print(f"     lap {i}: timer={lap['fields'].get(8)} elapsed={lap['fields'].get(7)} "
              f"start={lap['fields'].get(2)}")
        if lap["dev"]:
            # Stable order regardless of the FIT field-definition order in the file.
            ordered = [(k, lap["dev"][k]) for k in LAP_DEV_ORDER if k in lap["dev"]]
            extra = [(k, v) for k, v in lap["dev"].items() if k not in LAP_DEV_ORDER]
            parts = ", ".join(f"{k}={v}" for k, v in ordered + extra)
            print(f"        lap {i} dev: {parts}")
    for s in sessions:
        f = s["fields"]
        print("     session:", {k: f.get(k) for k in (2, 5, 6, 7, 8, 9, 16, 17, 18, 20, 21, 22)
                                if k in f})
        if s["dev"]:
            print("        dev:", s["dev"])
    print()
    return {"counts": counts, "records": records, "devfields": devfields,
            "laps": laps, "sessions": sessions}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--expect-laps", type=int, default=None,
                     help="Fail unless the LAST file has exactly this many LAP messages.")
    ap.add_argument("--expect-dev-fields", type=int, default=None,
                     help="Fail unless the LAST file defines exactly this many developer fields.")
    args = ap.parse_args()

    result = None
    for p in args.files:
        result = parse(p)

    if args.expect_laps is None and args.expect_dev_fields is None:
        return 0

    ok = True
    if args.expect_laps is not None and len(result["laps"]) != args.expect_laps:
        print(f"FAIL: expected {args.expect_laps} laps, found {len(result['laps'])} "
              f"in {args.files[-1]}", file=sys.stderr)
        ok = False
    if args.expect_dev_fields is not None and len(result["devfields"]) != args.expect_dev_fields:
        print(f"FAIL: expected {args.expect_dev_fields} developer fields, found "
              f"{len(result['devfields'])} in {args.files[-1]}", file=sys.stderr)
        ok = False
    if not ok:
        return 1
    print(f"OK: {args.files[-1]} matches --expect-laps/--expect-dev-fields")
    return 0


if __name__ == "__main__":
    sys.exit(main())
