#!/usr/bin/env python3
"""End-to-end proof for the Garmin-Liftosaur watch transport, over the real tunnel.

Everything here goes through the PUBLIC cloudflared URL the watch is configured
with, i.e. the same path a watch request takes: watch -> phone (GCM) -> https ->
tunnel -> FastAPI on :8008 -> Liftosaur.

It exercises both paths the owner reported broken:
  A. live sync while logging   (POST /api/v1/watch/workout/live, per set)
  B. the finished workout       (same endpoint with finished=1 -> history record)

Both are cleaned up afterwards (discard deletes the live record and the active
workout; the finished test record is deleted at the end), and the script verifies
the cleanup by reading the state back. Nothing is left in the owner's account,
and no program day is advanced: the REST "finish" (which would move the program
on) is NOT called - see the report's honest caveats.

Usage: python3 e2e_watch_sync.py [--keep]
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "https://them-pda-classifieds-experts.trycloudflare.com"
LIFT = "https://www.liftosaur.com/api/v1"
CONFIG = "/home/hermes/.hermes/config.yaml"
PROGRAM = "5/3/1 BBB - Squat/Bench/Deadlift/OHP"
KEEP = "--keep" in sys.argv

ok_count = 0
fail_count = 0


def check(label, cond, detail=""):
    global ok_count, fail_count
    if cond:
        ok_count += 1
        print(f"  PASS  {label} {detail}")
    else:
        fail_count += 1
        print(f"  FAIL  {label} {detail}")


def http(method, url, data=None, headers=None, timeout=60):
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, method=method,
                                 headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode()
            try:
                return r.status, json.loads(raw)
            except ValueError:
                return r.status, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, raw


def lift_key():
    k = os.environ.get("LIFTOSAUR_API_KEY", "")
    if k:
        return k
    with open(CONFIG) as fh:
        return re.search(r"lftsk_[A-Za-z0-9]+", fh.read()).group(0)


def lift(method, path, data=None):
    return http(method, LIFT + path, data, {
        "Authorization": f"Bearer {lift_key()}",
        "Content-Type": "application/json",
        "X-Liftosaur-Device-Id": "garmin-venu2s-e2e",
        "X-Liftosaur-Client": "garmin-watch",
    })


def payload(sets, started_at):
    head = f"Day 1|Week 1|{PROGRAM}|1200|{started_at}"
    body = ";".join(f"{name}|{w}|{r}|0" for name, w, r in sets)
    return f"{head};{body}"


def live_state():
    st, body = lift("GET", "/workout/current")
    if st != 200:
        return None
    return (body or {}).get("data", {}).get("workout")


def show_state(label):
    w = live_state()
    print(f"--- {label}: active workout = ", end="")
    if not w:
        print("null")
        return None
    done = [(e.get("name"), len([s for s in e.get("sets", []) if s.get("completed")]))
            for e in w.get("entries", [])]
    print(f"startTime={w.get('startTime')} dayName={w.get('dayName')!r} "
          f"{[f'{n}:{c}' for n, c in done if c]}")
    return w


def main():
    started = int(time.time())
    print(f"=== target: {BASE}\n")

    print("[pre] is anything already in progress? (the phone's workout is not ours)")
    existing = live_state()
    if existing:
        print(f"  ABORT: a workout is already in progress: "
              f"startTime={existing.get('startTime')} dayName={existing.get('dayName')!r}.")
        print("  Finish or discard it first - this proof must not adopt a session it")
        print("  did not start, and the finish/discard identity rules would (correctly)")
        print("  refuse to touch it.")
        return 2
    print("  nothing in progress - clean start")

    print("\n[0] endpoint health (the watch's own probe path)")
    st, body = http("GET", BASE + "/api/v1/watch/health")
    check("GET /api/v1/watch/health", st == 200, f"-> {st} {body}")
    check("health names this service",
          isinstance(body, dict) and body.get("service") == "garmin-liftosaur")

    print("\n[0b] URL shapes: the app's own (no trailing slash) vs a misconfigured one")
    st, _ = http("GET", BASE + "/api/v1/watch/plan?program=gjedbyiv")
    check("app shape /watch/plan?program=<id> is 200", st == 200, f"-> {st}")
    st, _ = http("GET", BASE + "/api/v1/watch/plan?program=gjedbyiv/")
    check("a trailing slash in the program id no longer 500s", st == 200, f"-> {st}")
    st, _ = http("GET", BASE + "/api/v1/watch/programs/")
    # Through Cloudflare this has answered BOTH 307 (from one edge) and 200 (from
    # another) for the same URL minutes apart, which is precisely why the app must
    # never build a trailing-slash path. Recorded here as an observation, not an
    # assumption: any 3xx is a failure for makeWebRequest, which cannot follow it.
    check("a trailing-slash PATH answers 200 or a 3xx (never 500)",
          st in (200, 301, 302, 307, 308), f"-> observed {st}")

    print("\n[1] LIVE SYNC: set 1 creates the record + the Liftosaur workout")
    p1 = payload([("Squat", 220, 5)], started)
    st, body = http("POST", BASE + "/api/v1/watch/workout/live?" + urllib.parse.urlencode(
        {"payload": p1, "record": ""}))
    check("POST /watch/workout/live (set 1)", st == 200, f"-> {st}")
    rid = (body or {}).get("id", "") if isinstance(body, dict) else ""
    print(f"       id={rid!r} rest_synced={(body or {}).get('rest_synced')!r} "
          f"rest_error={(body or {}).get('rest_error')!r}")
    check("the record was created", bool(rid))
    check("live sync reached Liftosaur's ACTIVE workout",
          (body or {}).get("rest_synced") is True,
          f"rest_error={(body or {}).get('rest_error')!r}")
    w = show_state("after set 1")
    check("Liftosaur's active workout exists (storage.progress[0])", bool(w))
    if w:
        # The session identity: the workout Liftosaur now holds must be started at
        # the watch's own stamp, because that value becomes the history record's
        # id at finish - a mismatch is what made finishes 404 before.
        check("the workout's startTime is the watch session's stamp",
              w.get("startTime") == started * 1000,
              f"-> startTime={w.get('startTime')} expected={started * 1000}")
        squat = next((e for e in w["entries"] if e.get("name") == "Squat"), None)
        got = [s for s in (squat or {}).get("sets", []) if s.get("completed")]
        check("set 1 is visible with the watch's weight",
              len(got) == 1 and got[0]["completed"]["weight"] == "220lb",
              f"-> {[s['completed']['weight'] for s in got]}")

    print("\n[2] LIVE SYNC: set 2 updates the SAME record")
    p2 = payload([("Squat", 220, 5), ("Squat", 250, 5)], started)
    st, body = http("POST", BASE + "/api/v1/watch/workout/live?" + urllib.parse.urlencode(
        {"payload": p2, "record": rid}))
    check("POST /watch/workout/live (set 2)", st == 200, f"-> {st}")
    check("it updated, not created",
          isinstance(body, dict) and body.get("updated") is True, f"-> {body}")
    w = show_state("after set 2")
    if w:
        squat = next((e for e in w["entries"] if e.get("name") == "Squat"), None)
        got = [s for s in (squat or {}).get("sets", []) if s.get("completed")]
        check("both sets are in Liftosaur's active workout", len(got) == 2,
              f"-> {[s['completed']['weight'] for s in got]}")

    print("\n[3] CLEANUP: discard the live workout (nothing left behind)")
    st, body = http("POST", BASE + "/api/v1/watch/workout/discard?" +
                    urllib.parse.urlencode({"record": rid}))
    check("POST /watch/workout/discard", st == 200, f"-> {st} {body}")
    w = show_state("after discard")
    check("the active workout is gone again", w is None)
    st, hist = lift("GET", "/history")
    ids = [r["id"] for r in (hist or {}).get("data", {}).get("records", [])]
    check("the discarded record is not in the history", rid not in ids)

    print("\n[4] FINISHED WORKOUT: the end-of-workout save")
    print("    (nothing is in progress here - step 3 discarded it - so the REST")
    print("     'finish' leg reports that honestly instead of 404ing, and the")
    print("     history record the watch owns is written and read back.)")
    st, body = http("POST", BASE + "/api/v1/watch/workout/live?" + urllib.parse.urlencode(
        {"payload": payload([("Squat", 285, 5), ("Bench Dip", 35, 8)], started + 600),
         "record": "", "finished": 1}))
    check("POST /watch/workout/live?finished=1", st == 200, f"-> {st}")
    fid = (body or {}).get("id", "") if isinstance(body, dict) else ""
    print(f"       id={fid!r} rest_synced={(body or {}).get('rest_synced')!r} "
          f"rest_error={(body or {}).get('rest_error')!r}")
    check("a finished record was created", bool(fid))
    check("the REST finish leg says why it did nothing (no workout in progress)",
          (body or {}).get("rest_synced") is False and
          "no workout in progress" in ((body or {}).get("rest_error") or ""),
          f"-> {(body or {}).get('rest_error')!r}")

    st, hist = lift("GET", "/history")
    rec = next((r for r in (hist or {}).get("data", {}).get("records", [])
                if str(r["id"]) == str(fid)), None)
    check("the record is readable from the Liftosaur API", rec is not None)
    if rec:
        print("       READ BACK FROM LIFTOSAUR:")
        for line in rec["text"].rstrip().splitlines():
            print("         " + line)
        check("it carries the watch's sets", "285lb" in rec["text"] and "35lb" in rec["text"])
        check("it is marked finished (no 'in progress' note)",
              "in progress" not in rec["text"])

    print("\n[5] CLEANUP: delete the test record")
    if KEEP:
        print("       --keep: leaving the record in place")
    else:
        st, body = lift("DELETE", f"/history/{fid}")
        check("DELETE /history/<id>", st == 200, f"-> {st} {body}")
        st, hist = lift("GET", "/history")
        ids = [str(r["id"]) for r in (hist or {}).get("data", {}).get("records", [])]
        check("the test record is gone", str(fid) not in ids)

    print(f"\n=== {ok_count} passed, {fail_count} failed")
    return 1 if fail_count else 0


if __name__ == "__main__":
    sys.exit(main())
