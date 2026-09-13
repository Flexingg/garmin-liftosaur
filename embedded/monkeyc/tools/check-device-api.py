#!/usr/bin/env python3
"""Catch calls to Toybox symbols the target DEVICE does not actually expose.

Why this exists: the SDK's api.debug.xml is the union of every device's API, so
`monkeyc` happily compiles a call to a function that a given watch does not have.
The failure only shows up on hardware, at runtime, as:

    Error: Symbol Not Found Error
    Details: "Could not find symbol 'setConnectionStrategy'"

...which cost a full hardware cycle to find. This checks the source against the
target device's own API file instead.

Usage:
    check-device-api.py --device venu2s --source-dir source [--strict-module NAME]

Exit code 0 = clean, 1 = a call in a strict module is missing on this device,
2 = could not locate the device API file.
"""
from __future__ import annotations

import argparse
import os
import re
import sys

# Modules we scan for. Kept explicit so we don't try to model the whole language.
MODULES = [
    "BluetoothLowEnergy", "Communications", "Sensor", "Activity",
    "ActivityRecording", "ActivityMonitor", "System", "WatchUi", "Time",
    "Graphics", "Timer", "Math", "Attention", "Fit", "Lang", "Application",
    "Position", "UserProfile", "Ant", "Storage", "PersistedContent",
]

CALL_RE = re.compile(
    r"\b(" + "|".join(MODULES) + r")\.([A-Za-z_][A-Za-z0-9_]*)\s*\(")

# Constant / enum references: Module.ALL_CAPS not followed by "(". These bypass
# the call check above, which is exactly how `BluetoothLowEnergy.STATUS_BLE_QUEUE_FULL`
# got through - that symbol belongs to Toybox.Communications, but it exists in the
# device file, so only the *qualified* module check catches it. Restricted to
# ALL_CAPS so type names (Status, Device, ScanResult) are not swept in.
REF_RE = re.compile(
    r"\b(" + "|".join(MODULES) + r")\.([A-Z_][A-Z0-9_]*)\b(?!\s*\()")

SYMBOL_RE = re.compile(r'symbol="([A-Za-z_][A-Za-z0-9_]*)"')

API_ROOTS = [
    os.path.expanduser("~/.Garmin/ConnectIQ/Devices"),
    "/home/hermes/.Garmin/ConnectIQ/Devices",
]


def find_api_file(device: str) -> str | None:
    for root in API_ROOTS:
        d = os.path.join(root, device)
        if not os.path.isdir(d):
            continue
        # Prefer <device>.api.debug.xml, else any *api.debug.xml in the dir.
        direct = os.path.join(d, f"{device}.api.debug.xml")
        if os.path.isfile(direct):
            return direct
        for f in sorted(os.listdir(d)):
            if f.endswith("api.debug.xml"):
                return os.path.join(d, f)
    return None


def device_symbols(api_file: str) -> set[str]:
    """Every symbol id in the device's API file (names are what the runtime
    resolves, and Monkey C's linker errors on name, so this is the right key)."""
    with open(api_file, "r", encoding="utf-8", errors="replace") as fh:
        return set(SYMBOL_RE.findall(fh.read()))


def scan_sources(source_dir: str) -> dict[tuple[str, str], list[str]]:
    hits: dict[tuple[str, str], list[str]] = {}
    for root, _dirs, files in os.walk(source_dir):
        for name in sorted(files):
            if not name.endswith(".mc"):
                continue
            path = os.path.join(root, name)
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                for lineno, line in enumerate(fh, 1):
                    stripped = line.strip()
                    if stripped.startswith("//"):
                        continue
                    for m in CALL_RE.finditer(line):
                        hits.setdefault((m.group(1), m.group(2)), []).append(
                            f"{os.path.relpath(path, source_dir)}:{lineno}")
                    for m in REF_RE.finditer(line):
                        hits.setdefault((m.group(1), m.group(2)), []).append(
                            f"{os.path.relpath(path, source_dir)}:{lineno}")
    return hits


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", required=True)
    ap.add_argument("--source-dir", required=True)
    ap.add_argument("--api-file", default=None)
    ap.add_argument(
        "--strict-module", action="append", default=None,
        help="Module whose missing symbols should FAIL (repeatable). "
             "Others are reported as warnings only.")
    args = ap.parse_args()

    api_file = args.api_file or find_api_file(args.device)
    if not api_file or not os.path.isfile(api_file):
        print(f"check-device-api: no API file for device '{args.device}' "
              f"(looked in {API_ROOTS})", file=sys.stderr)
        return 2

    known = device_symbols(api_file)
    hits = scan_sources(args.source_dir)
    if not hits:
        print("check-device-api: no module calls found")
        return 0

    # The device file lists the module's own symbols; a member missing from the
    # whole file is a strong signal the firmware cannot resolve it.
    missing = {k: v for k, v in hits.items() if k[1] not in known}
    strict = set(args.strict_module or [])

    if not missing:
        print(f"check-device-api: all {len(hits)} module calls exist on "
              f"'{args.device}'")
        return 0

    failed = False
    for (mod, member), sites in sorted(missing.items()):
        is_strict = mod in strict
        if is_strict:
            failed = True
        label = "ERROR" if is_strict else "warn "
        print(f"{label}: {mod}.{member} not found in the '{args.device}' API "
              f"file ({len(sites)} call site(s)): {', '.join(sites[:3])}")
    if failed:
        print("\ncheck-device-api: refusing to hand you a build that will throw "
              "'Symbol Not Found' on the device.", file=sys.stderr)
        return 1
    print("check-device-api: only non-strict warnings above")
    return 0


if __name__ == "__main__":
    sys.exit(main())
