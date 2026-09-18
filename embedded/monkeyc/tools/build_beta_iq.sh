#!/usr/bin/env bash
# Build the .iq package for a PRIVATE BETA upload to the Connect IQ store.
#
# Why this exists:
#   Garmin Connect only renders our FIT developer fields for an app that was
#   installed FROM THE STORE - a sideloaded .prg never shows them, because
#   Garmin Connect resolves the field metadata server-side (see docs/05). The
#   supported way to test that without publishing is a BETA app, and Garmin's
#   Beta Apps doc requires "an alternate app id in your manifest using a UUID
#   creator". So: swap in a beta id, package, restore the manifest.
#
#   The production id must be restored afterwards, because the sideloaded .prg
#   identifies the installed app by that id - changing it would orphan the copy
#   on the watch (and its saved plan / workout state).
#
# Usage:
#   ./tools/build_beta_iq.sh                # generate a fresh beta id (printed)
#   ./tools/build_beta_iq.sh <uuid>         # reuse a beta id you already uploaded
#
# Output: bin/Liftosaur-beta.iq and bin/Liftosaur-beta.iq.sha256
set -euo pipefail
cd "$(dirname "$0")/.."

MANIFEST="manifest.xml"
OUT="bin/Liftosaur-beta.iq"

# ---------------------------------------------------------------- SDK lookup
CANDIDATE_ROOTS=(
  "$HOME/.Garmin/ConnectIQ/Sdks"
  "/home/$USER/.Garmin/ConnectIQ/Sdks"
  "/home/hermes/.Garmin/ConnectIQ/Sdks"
)
SDK_HOME=""
for root in "${CANDIDATE_ROOTS[@]}"; do
  if [ -d "$root" ]; then
    hit=$(ls -d "$root"/connectiq-sdk-lin-* 2>/dev/null | sort -V | tail -1 || true)
    if [ -n "$hit" ]; then SDK_HOME="$hit"; break; fi
  fi
done
if [ -z "$SDK_HOME" ]; then
  echo "ERROR: Connect IQ SDK not found (looked in ${CANDIDATE_ROOTS[*]})" >&2
  exit 1
fi
export CONNECTIQ_HOME="$SDK_HOME"
echo "SDK: $SDK_HOME"

[ -f developer_key.der ] || { echo "ERROR: missing developer_key.der" >&2; exit 1; }

# ------------------------------------------------------------ app id handling
PROD_ID=$(grep -o 'iq:application id="[^"]*"' "$MANIFEST" | head -1 | cut -d'"' -f2)
if [ -z "$PROD_ID" ]; then echo "ERROR: no iq:application id in $MANIFEST" >&2; exit 1; fi

BETA_ID="${1:-}"
if [ -z "$BETA_ID" ]; then
  BETA_ID=$(python3 -c 'import uuid; print(str(uuid.uuid4()).upper())')
  echo "NOTE: generated a NEW beta app id - write it down, every future update of"
  echo "      the same beta app must reuse it:"
fi
echo "production app id: $PROD_ID"
echo "beta app id:       $BETA_ID"

# --------------------------------------------------------------- package it
BACKUP="$(mktemp /tmp/manifest.prod.XXXXXX.xml)"
cp "$MANIFEST" "$BACKUP"

# Restore the manifest no matter how we leave this script - a stray beta id in
# the tree would silently change the identity of the sideloaded app.
restore() {
  cp "$BACKUP" "$MANIFEST"
  rm -f "$BACKUP"
  echo "manifest restored to production id $PROD_ID"
}
trap restore EXIT

sed -i "s/$PROD_ID/$BETA_ID/" "$MANIFEST"
grep -q "$BETA_ID" "$MANIFEST" || { echo "ERROR: id swap did not apply" >&2; exit 1; }

mkdir -p bin
"$SDK_HOME/bin/monkeyc" -e -o "$OUT" -f monkey.jungle -d venu2s -y developer_key.der
[ -f "$OUT" ] || { echo "ERROR: $OUT was not produced" >&2; exit 1; }

( cd bin && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )
echo
echo "Built $OUT ($(stat -c%s "$OUT") bytes)"
echo "Upload it at https://apps.garmin.com/en-US/developer/upload and TICK the"
echo "\"Beta App\" checkbox. Beta apps install from the web store page (not the"
echo "Connect IQ mobile app) and are visible only to your account."
