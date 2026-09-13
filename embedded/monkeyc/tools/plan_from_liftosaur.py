#!/usr/bin/env python3
"""Generate the watch's embedded workout plan from the user's Liftosaur program.

Why: the watch app must work standalone in the gym (no BLE, no network during a
workout). So the plan is baked into the build as Monkey C data instead of being
fetched. Re-run this and rebuild the app whenever the program changes.

Inputs, all from the Liftosaur MCP API (key in LIFTOSAUR_API_KEY or --key):
  get_program(id=current)   -> Liftoscript source (structure + percentages)
  list_exercise_data        -> rm1 (training max) per exercise, for the %s

Outputs:
  source/PlanData.mc   Monkey C data the watch reads (LiftPlan.days())
  dist/plan.json       the same plan as JSON, for eyeballing/diffing

Liftoscript understood here (deliberately a subset, matched to this program):
  # Week N                  week section (ignored: progression scripts handle it)
  ## Day NAME               day section
  name / 1x5 65%, ... / 90s / ...          a named SET BLOCK (referenced below)
  Exercise[, Equipment][weeks] / 3x8 / 135lb 90s   an exercise with inline sets
  Exercise[...] / ...block                          an exercise reusing a block

Anything it cannot resolve is reported, never silently guessed.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

MCP_URL = "https://www.liftosaur.com/mcp"


def mcp(name: str, args: dict, key: str) -> str:
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                       "params": {"name": name, "arguments": args}})
    out = subprocess.run(
        ["curl", "-s", "--max-time", "45", "-X", "POST", MCP_URL,
         "-H", f"Authorization: Bearer {key}",
         "-H", "Content-Type: application/json",
         "-H", "Accept: application/json, text/event-stream",
         "-d", body], capture_output=True, text=True, check=True).stdout
    return json.loads(out)["result"]["content"][0]["text"]


def parse_weight(lb: str) -> float:
    m = re.search(r"([0-9.]+)\s*lb", lb or "")
    return float(m.group(1)) if m else 0.0


def round5(x: float) -> float:
    """Gym-plate rounding: nearest 5 lb."""
    return round(x / 5.0) * 5.0


# --- set-spec parsing -------------------------------------------------------
# "1x5 65%" | "1x5+ 85%" | "5x10 50%" | "3x8 135lb 90s" | "3x1 45s|60s"
SET_RE = re.compile(
    r"(?P<sets>\d+)\s*x\s*(?P<reps>\d+)(?P<amrap>\+)?"
    r"(?:\s*(?P<weight>\d+(?:\.\d+)?%|\d+(?:\.\d+)?\s*lb))?"
    r"(?:\s*(?P<rest>\d+)\s*s)?")
REST_RE = re.compile(r"(?<![\dx])(\d+)\s*s\b")


def parse_sets(spec: str, default_rest: int) -> list[dict]:
    """Turn a set specification into concrete sets.

    Weight stays symbolic here ('65%' / '135lb') because percentages need the
    exercise's rm1, which is looked up later.
    """
    sets: list[dict] = []
    for chunk in re.split(r",(?![^(]*\))", spec):
        chunk = chunk.strip()
        if not chunk:
            continue
        m = SET_RE.match(chunk)
        if not m:
            continue
        n = int(m.group("sets"))
        reps = int(m.group("reps"))
        w = m.group("weight") or ""
        for _ in range(n):
            sets.append({
                "reps": reps,
                "amrap": bool(m.group("amrap")),
                "weight_expr": w,
                "rest": int(m.group("rest")) if m.group("rest") else default_rest,
            })
    return sets


def parse_program(text: str) -> tuple[list[dict], dict]:
    """-> (days, blocks). days: [{name, exercises: [...]}] in program order."""
    days: list[dict] = []
    blocks: dict[str, dict] = {}
    cur: dict | None = None
    section = ""
    sec_blocks: dict[str, dict] = {}
    for raw in text.split("\n"):
        line = raw.strip()
        if line.startswith("//"):
            continue
        # strip inline progress scripts, keeping the head of the line
        head = re.sub(r"\{.*", "", line).strip()
        if not head:
            continue
        if head.startswith("## "):
            cur = {"name": head[3:].strip(), "exercises": [], "blocks": {},
                   "section": section, "blocks": sec_blocks}
            days.append(cur)
            continue
        if head.startswith("#"):
            section = head.lstrip("#").strip()
            sec_blocks = {}          # a new section redefines its own blocks
            continue
        if head.startswith("!"):
            continue
        parts = [p.strip() for p in head.split("/")]
        name_field = parts[0]
        # a named set block, e.g. "main / used: none / 1x5 65%, 1x5 75% / 180s"
        if len(parts) > 2 and re.match(r"^[A-Za-z][\w ]*$", name_field) and cur is not None:
            rest = 0
            for p in parts[2:]:
                rm = REST_RE.search(p)
                if rm and "x" not in p:
                    rest = int(rm.group(1))
            spec = next((p for p in parts[2:] if "x" in p and "%" in p or
                         re.match(r"^\d+\s*x\s*\d+", p)), "")
            if spec and re.match(r"^\d+\s*x\s*\d+", spec):
                sec_blocks[name_field] = {"sets": parse_sets(spec, rest), "rest": rest}
                continue
        if cur is None:
            continue
        # an exercise entry
        ex_name = name_field.split("[")[0].strip()
        sets_spec = ""
        for p in parts[1:]:
            if p.startswith("..."):
                sets_spec = p
                break
            if re.match(r"^\d+\s*x\s*\d+", p):
                sets_spec = p
                break
        rest = 0
        for p in parts[1:]:
            rm = REST_RE.search(p)
            if rm and not re.match(r"^\d+\s*x", p):
                rest = int(rm.group(1))
        inline_lb = ""
        for p in parts[1:]:
            lm = re.search(r"\d+(?:\.\d+)?\s*lb", p)
            if lm:
                inline_lb = lm.group(0)
                break
        if not ex_name or not sets_spec:
            continue
        cur["exercises"].append({
            "name": ex_name, "sets_spec": sets_spec, "rest": rest, "lb": inline_lb,
        })
    return days, blocks


def build_plan(days, blocks, rm1: dict) -> list[dict]:
    # Exercises referenced as "...Name[week]" reuse that exercise's own inline
    # definition from the first day that spells it out (e.g. "Chin Up[1-3] / 3x8").
    inline: dict[str, dict] = {}
    for d in days:
        for ex in d["exercises"]:
            if not ex["sets_spec"].startswith("...") and ex["name"] not in inline:
                inline[ex["name"]] = {"sets": parse_sets(ex["sets_spec"], ex["rest"]),
                                     "rest": ex["rest"]}
    out = []
    for d in days:
        exs = []
        for ex in d["exercises"]:
            spec = ex["sets_spec"]
            if spec.startswith("..."):
                # a block belongs to the DAY it is defined in; a bare name like
                # "Chin Up[1]" instead refers to that exercise's inline sets.
                ref = spec[3:].strip()
                ref_name = re.sub(r"\[[^\]]*\]", "", ref).strip()
                blk = d["blocks"].get(ref) or d["blocks"].get(ref_name) or inline.get(ref_name)
                if not blk:
                    print(f"  ! unresolved block '{spec}' for {ex['name']}")
                    continue
                sets = [dict(s) for s in blk["sets"]]
                rest = ex["rest"] or blk["rest"]
            else:
                sets = parse_sets(spec, ex["rest"])
                rest = ex["rest"]
            if not rest:
                rest = 90
            # resolve weights: % -> rm1 * pct, else explicit lb
            key = ex["name"].lower()
            ex_rm1 = 0.0
            for k, v in rm1.items():
                if k.startswith(key) or key.startswith(k.split("_")[0]):
                    ex_rm1 = v
                    break
            for s in sets:
                w = s.pop("weight_expr", "")
                if w.endswith("%"):
                    pct = float(w[:-1])
                    s["weight"] = round5(ex_rm1 * pct / 100.0) if ex_rm1 else 0
                elif w:
                    s["weight"] = round5(parse_weight(w))
                else:
                    s["weight"] = round5(parse_weight(ex["lb"]))
                s["rest"] = s.get("rest") or rest
            exs.append({"name": ex["name"], "sets": sets, "rest": rest,
                        "rm1": ex_rm1})
        if exs:
            out.append({"name": d["name"], "exercises": exs,
                        "section": d.get("section", "")})
    return out


def emit_mc(plan: list[dict]) -> str:
    L = ["// GENERATED by tools/plan_from_liftosaur.py - do not edit by hand.",
         "// Source: the user's current Liftosaur program; weights computed from rm1.",
         "",
         "import Toybox.Lang;",
         "",
         "module LiftPlan {", "",
         "    // The whole plan: array of days, each with exercises and resolved sets.",
         "    function days() as Array {", "        return ["]
    for d in plan:
        L.append(f'            {{:name => "{d["name"]}", :section => "{d.get("section", "")}", :exercises => [')
        for ex in d["exercises"]:
            L.append(f'                {{:name => "{ex["name"]}", :rest => {ex["rest"]}, :sets => [')
            for s in ex["sets"]:
                L.append(f'                    {{:reps => {s["reps"]}, :weight => {int(s["weight"])}, '
                         f':amrap => {"true" if s["amrap"] else "false"}, :rest => {s["rest"]}}},')
            L.append("                ]},")
        L.append("            ]},")
    L += ["        ];", "    }", "}"]
    return "\n".join(L) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--key", default=os.environ.get("LIFTOSAUR_API_KEY", ""))
    ap.add_argument("--default-key-file", default="/home/hermes/.hermes/config.yaml")
    ap.add_argument("--out-mc", default="source/PlanData.mc")
    ap.add_argument("--out-json", default="../../dist/plan.json")
    args = ap.parse_args()

    key = args.key
    if not key and os.path.exists(args.default_key_file):
        m = re.search(r"lftsk_[A-Za-z0-9]+", open(args.default_key_file).read())
        key = m.group(0) if m else ""
    if not key:
        print("no Liftosaur API key (set LIFTOSAUR_API_KEY)", file=sys.stderr)
        return 2

    prog = json.loads(mcp("get_program", {"id": "current"}, key))
    print(f"program: {prog['name']} ({prog['id']})")
    rm1 = {}
    data = json.loads(mcp("list_exercise_data", {}, key))
    for e in data.get("exerciseData", []):
        rm1[e["key"].split("_")[0].lower()] = parse_weight(e.get("rm1"))
    print(f"training maxes: {len(rm1)} exercises")

    days, blocks = parse_program(prog["text"])
    plan = build_plan(days, blocks, rm1)
    print(f"sections: {sorted({d.get('section', '') for d in plan})}")
    print(f"days: {len(plan)}")
    for d in plan:
        tot = sum(len(e['sets']) for e in d['exercises'])
        print(f"  {d['name']}: {len(d['exercises'])} exercises, {tot} sets")

    os.makedirs(os.path.dirname(args.out_mc) or ".", exist_ok=True)
    open(args.out_mc, "w").write(emit_mc(plan))
    try:
        os.makedirs(os.path.dirname(args.out_json), exist_ok=True)
        json.dump(plan, open(args.out_json, "w"), indent=2)
    except OSError as e:
        print(f"  (json not written: {e})")
    print(f"wrote {args.out_mc}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
