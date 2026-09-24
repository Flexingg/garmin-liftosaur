"""Python mirror of the watch's endpoint rules (`module LiftEndpoint` in
embedded/monkeyc/source/Endpoint.mc).

Why this exists: Monkey C only runs on the device (or the simulator), so the
URL normalisation / join / failover rules are proven here instead, by
backend/python/tests/test_endpoint.py. The functions below are a faithful,
line-by-line translation of Endpoint.mc, in the same order.

LOCKSTEP RULE: keep this file in lockstep with Endpoint.mc by hand - there is
no shared source between Python and Monkey C on this project (the same rule as
verify_watch_payload.py's `urlencode_mirror`). If one changes, change the
other in the same commit. `--mc <path>` checks the constants have not drifted:

    python3 embedded/monkeyc/tools/endpoint_mirror.py --mc embedded/monkeyc/source/Endpoint.mc
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from typing import Optional

DEFAULT_MC = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "source", "Endpoint.mc")

DISCOVERY_URLS = [
    "https://raw.githubusercontent.com/Flexingg/garmin-liftosaur/main/endpoint.json",
    "https://cdn.jsdelivr.net/gh/Flexingg/garmin-liftosaur@main/endpoint.json",
]

HEALTH_PATH = "/api/v1/watch/health"


def isEdgeChar(v: int) -> bool:
    """Space (0x20), tab (0x09) or "/" (0x2F)."""
    return v == 0x20 or v == 0x09 or v == 0x2F


def stripEdges(s: str) -> str:
    """Drop leading/trailing spaces, tabs and "/"."""
    start = 0
    end = len(s)
    while start < end and isEdgeChar(ord(s[start])):
        start += 1
    while end > start and isEdgeChar(ord(s[end - 1])):
        end -= 1
    return s[start:end]


def hasPrefixNoCase(s: str, prefix: str) -> bool:
    """True when s begins with prefix, compared case-insensitively."""
    if len(s) < len(prefix):
        return False
    return s[0:len(prefix)].lower() == prefix.lower()


def normalizeBaseUrl(raw: Optional[str]) -> str:
    """A usable base URL, or "" when there is none (https only, except the
    loopback hosts; the https scheme is lower-cased, the rest kept as given)."""
    if raw is None:
        return ""
    s = stripEdges(raw)
    if s == "":
        return ""
    rest = ""
    if hasPrefixNoCase(s, "https://"):
        rest = s[8:]
        s = "https://" + rest
    elif hasPrefixNoCase(s, "http://"):
        rest = s[7:]
        if not hasPrefixNoCase(rest, "127.0.0.1") and not hasPrefixNoCase(rest, "localhost"):
            return ""
    else:
        return ""
    if " " in rest:
        return ""
    return s


def joinUrl(base: str, path: str) -> str:
    """base + "/" + path with exactly one "/" between them; "" without a base."""
    if base == "":
        return ""
    b = base
    while len(b) > 0 and b[-1:] == "/":
        b = b[:-1]
    p = path
    while len(p) > 0 and p[0:1] == "/":
        p = p[1:]
    if p == "":
        return b
    return b + "/" + p


def candidates(learned: Optional[str], configured: Optional[str],
               baked: Optional[str]) -> list[str]:
    """Normalised base URLs in try order (learned, configured, baked),
    empties dropped, duplicates removed."""
    out: list[str] = []
    for r in (learned, configured, baked):
        n = normalizeBaseUrl(r)
        if n == "":
            continue
        if n not in out:
            out.append(n)
    return out


def shouldFollow(code: int) -> bool:
    """A redirect makeWebRequest refuses to follow."""
    return 300 <= code <= 399


def isRetryable(code: int) -> bool:
    """Anything that is not a 2xx."""
    return not (200 <= code <= 299)


def nextIndex(current: int, count: int) -> int:
    """The next candidate index, or -1 when the candidates are exhausted."""
    if current + 1 < count:
        return current + 1
    return -1


def describeCode(code: int) -> str:
    """Human text for a response code, short enough for the watch."""
    if 200 <= code <= 299:
        return "ok"
    if 300 <= code <= 399:
        return f"{code} redirect"
    if 400 <= code <= 499:
        return f"{code} rejected"
    if 500 <= code <= 599:
        return f"{code} server error"
    if code == -300:
        return "network timeout (phone)"
    if code == -1001:
        return "https required"
    if code == -104:
        return "phone offline"
    if code == -101:
        return "no connection"
    if code == -2:
        return "network error"
    if code < 0:
        return f"network error {code}"
    if code == 0:
        return "not tried"
    return str(code)


def parseDiscovery(data) -> str:
    """The base URL named by a discovery document, or "" when it names none."""
    if not isinstance(data, dict):
        return ""
    v = data.get("backend")
    if not isinstance(v, str):
        return ""
    return normalizeBaseUrl(v)


# --------------------------------------------------------------- drift check

def check_mc(path: str) -> list[str]:
    """Compare this mirror's constants with Endpoint.mc's. Returns the
    mismatches (empty when in lockstep)."""
    with open(path, encoding="utf-8") as fh:
        src = fh.read()
    problems: list[str] = []

    m = re.search(r"const\s+DISCOVERY_URLS\s*=\s*\[(.*?)\];", src, re.S)
    mc_urls = re.findall(r'"([^"]*)"', m.group(1)) if m else []
    if mc_urls != DISCOVERY_URLS:
        problems.append(f"DISCOVERY_URLS: mc={mc_urls!r} mirror={DISCOVERY_URLS!r}")

    m = re.search(r'const\s+HEALTH_PATH\s*=\s*"([^"]*)"\s*;', src)
    mc_health = m.group(1) if m else None
    if mc_health != HEALTH_PATH:
        problems.append(f"HEALTH_PATH: mc={mc_health!r} mirror={HEALTH_PATH!r}")

    # Spot check describeCode's literals.
    for code in (-300, -1001, -104):
        m = re.search(r"code\s*==\s*" + re.escape(str(code)) +
                      r'\)\s*\{\s*return\s+"([^"]*)"\s*;', src)
        mc_text = m.group(1) if m else None
        if mc_text != describeCode(code):
            problems.append(f"describeCode({code}): mc={mc_text!r} "
                            f"mirror={describeCode(code)!r}")
    return problems


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--mc", default=DEFAULT_MC,
                    help="path to Endpoint.mc (default: %(default)s)")
    args = ap.parse_args(argv)
    problems = check_mc(args.mc)
    if problems:
        for p in problems:
            print("MISMATCH " + p)
        return 1
    print("endpoint_mirror: in lockstep with " + os.path.normpath(args.mc))
    return 0


if __name__ == "__main__":
    sys.exit(main())
