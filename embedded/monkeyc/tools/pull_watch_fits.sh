#!/usr/bin/env bash
# Copy the newest activity FIT files off the Venu 2S over MTP (gio/GVFS).
#
# Usage:
#   tools/pull_watch_fits.sh [--count N] [--out DIR]
#
# Requires the watch mounted as MTP storage (gio mount -l | grep -i mtp) and
# GARMIN/Activity to be readable. The MTP URI's "Internal Storage" segment has
# a literal SPACE in it - gio requires that space raw, NOT %20 (a %20 there is
# double-encoded and fails with "File not found"), so this script always
# quotes the URI rather than building a URL-encoded one.
set -euo pipefail

COUNT=5
OUT="./fit-out"

while [ $# -gt 0 ]; do
    case "$1" in
        --count) COUNT="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

MOUNT_LIST=$(gio mount -l)
if ! echo "$MOUNT_LIST" | grep -qi mtp; then
    echo "No MTP device mounted. Plug in the watch with a data-capable cable," >&2
    echo "set USB Mode to MTP on the watch, then run: gio mount -l | grep -i mtp" >&2
    exit 1
fi

# A "Mount(N): ... -> mtp://091e_4e78_.../" line gives the device URI; other
# MTP-matching lines (e.g. "Type: GProxyVolumeMonitorMTP") do not have "->".
DEVICE_URI=$(echo "$MOUNT_LIST" | sed -n 's/.*-> \(mtp:[^ ]*\).*/\1/p' | head -n 1)
if [ -z "$DEVICE_URI" ]; then
    echo "Could not parse the MTP device URI from:" >&2
    echo "$MOUNT_LIST" >&2
    exit 1
fi
DEVICE_URI="${DEVICE_URI%/}"

ACTIVITY_URI="${DEVICE_URI}/Internal Storage/GARMIN/Activity"
echo "Listing: $ACTIVITY_URI"
# MTP listing caps at ~200 entries; newest-last, so tail -N after a plain sort
# (filenames are "YYYY-MM-DD-HH-MM-SS.fit", which sorts chronologically).
FILES=$(gio list "$ACTIVITY_URI" | grep '\.fit$' | sort | tail -n "$COUNT")
if [ -z "$FILES" ]; then
    echo "No .fit files found under $ACTIVITY_URI" >&2
    exit 1
fi

mkdir -p "$OUT"
while IFS= read -r f; do
    echo "Copying $f ..."
    gio copy "$ACTIVITY_URI/$f" "$OUT/"
done <<< "$FILES"

echo "Done. Files in $OUT:"
ls -la "$OUT"
